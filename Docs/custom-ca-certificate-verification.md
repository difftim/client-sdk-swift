# LiveKit iOS SDK 自定义根证书验证方案

## 背景

LiveKit SDK 的 WebSocket 和 QUIC 两种信令连接模式需要支持 **IP 直连**，服务端使用自签证书，客户端需要预埋服务端根证书进行验证。

---

## 一、可行性分析

### 1.1 需求拆解

| 需求 | 说明 |
|------|------|
| IP 直连 | URL 形如 `wss://10.0.0.1:7880/rtc`，不经过 DNS 解析 |
| 自签证书 | 服务端使用自建 CA 签发的证书，不在系统信任库中 |
| 预埋根证书 | 客户端 App 内嵌 CA 根证书 DER 文件，用于验证服务端证书链 |
| 两模式覆盖 | WebSocket 和 QUIC 信令传输模式都必须支持 |

### 1.2 服务端证书要求（前置条件）

IP 直连场景下，服务端自签证书的 **SAN (Subject Alternative Name) 必须包含 IP 地址**，否则无论客户端怎么配置都会验证失败：

```
X509v3 Subject Alternative Name:
    IP Address: 10.0.0.1
```

生成示例（OpenSSL）：

```bash
# 生成根 CA
openssl req -x509 -newkey rsa:2048 -keyout ca.key -out ca.crt \
  -days 3650 -nodes -subj "/CN=My Root CA"

# 生成服务端证书（含 IP SAN）
openssl req -newkey rsa:2048 -keyout server.key -out server.csr \
  -nodes -subj "/CN=LiveKit Server"
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 365 -extfile <(echo "subjectAltName=IP:10.0.0.1")

# 导出根 CA 为 DER 格式（供客户端预埋）
openssl x509 -in ca.crt -outform DER -out ca.der
```

### 1.3 当前代码现状

#### WebSocket 路径

```
ConnectOptions
  → SignalTransportFactory.create(kind: .websocket)
    → WebSocketSignalTransport.init(url:token:connectOptions:sendAfterOpen:)
      → WebSocket.init(url:token:connectOptions:sendAfterOpen:)
        → URLSession(configuration:delegate:delegateQueue:)
          → urlSession.webSocketTask(with:)
            → TLS 握手：完全由系统 URLSession/ATS 默认处理
```

`WebSocket` 类当前只实现了 `URLSessionWebSocketDelegate`，**没有**实现 `URLSessionDelegate` 的核心认证挑战方法 `urlSession(_:didReceive challenge:completionHandler:)`，因此无法介入 TLS 证书验证。

#### QUIC 路径

```
ConnectOptions
  → SignalTransportFactory.create(kind: .quic)
    → QUICSignalTransport.maybeCreate(url:token:connectOptions:sendAfterOpen:)
      → QUICClient.connect(url:args:)
        → createQUICParametersWithCustomVerification(quicOptions:host:)
          → sec_protocol_options_set_verify_block
            → SecTrustEvaluateAsyncWithError（仅系统信任库）
```

QUIC 已有自定义 verify block，但当前仅使用系统信任库评估。

#### HTTP 验证路径

```
SignalClient.connect()  // 连接失败时
  → HTTP.requestValidation(from:token:)
    → URLSession（delegate 为 nil，无法自定义证书验证）
```

`HTTP.swift` 中的 `URLSession` delegate 为 nil，自签证书场景下 validate 请求也会失败。

### 1.4 可行性结论

**完全可行**。三条路径都有明确的 Apple API 支持自定义根证书验证：

| 路径 | Apple API 入口 | 核心验证 API |
|------|---------------|-------------|
| WebSocket | `URLSessionDelegate.urlSession(_:didReceive challenge:completionHandler:)` | `SecTrustSetAnchorCertificates` + `SecTrustEvaluateAsyncWithError` |
| QUIC | 已有的 `sec_protocol_verify_t` block | 同上 |
| HTTP validate | `URLSessionDelegate.urlSession(_:didReceive challenge:completionHandler:)` | 同上 |

三条路径最终都汇聚到同一组 Security.framework API，验证逻辑可统一。

### 1.5 IP 直连兼容性验证

#### URL 解析

`Utils.buildUrl` 中 `URLComponents` 可以正确处理 IP 地址：

```
输入:  wss://10.0.0.1:7880
解析:  scheme="wss", host="10.0.0.1", port=7880
输出:  wss://10.0.0.1:7880/rtc?protocol=12&sdk=swift&...
```

`URL.isValidForConnect` 通过 `host != nil` 检查——IP 地址会被正确识别为 host，**无需改动**。

#### TLS SNI 处理

| 模式 | SNI 来源 | IP 直连时行为 |
|------|---------|-------------|
| WebSocket | `URLSession` 自动从 URL host 提取 | 自动使用 IP 地址作为 SNI |
| QUIC | `sec_protocol_options_set_tls_server_name(securityOptions, host)` | `host` 来自 URL 解析即为 IP |

两条路径都无需额外改动 SNI 逻辑，前提是服务端证书 SAN 中包含该 IP。

#### ATS (App Transport Security)

`wss://` 走 TLS，不需要 ATS 豁免。如果需要 `ws://`（不推荐），需在 Info.plist 中添加 `NSAllowsArbitraryLoads`。

---

## 二、架构设计

### 2.1 数据流全景

```
┌────────────────────────────────────────────────────────────────────┐
│  用户层                                                             │
│  ConnectOptions(customCACertificates: [Data])                       │
└──────────────────────────┬─────────────────────────────────────────┘
                           │
              ┌────────────▼────────────┐
              │  SignalTransportFactory  │
              └────┬───────────────┬────┘
                   │               │
        ┌──────────▼──────┐  ┌────▼──────────────────┐
        │  WebSocket 路径  │  │      QUIC 路径         │
        │                 │  │                        │
        │  WebSocket      │  │  QUICSignalTransport   │
        │  ↓              │  │  ↓                     │
        │  URLSession     │  │  QUICClient.connect()  │
        │  ↓              │  │  ↓                     │
        │  didReceive     │  │  sec_protocol_verify_t │
        │  challenge:     │  │  ↓                     │
        │  ↓              │  │  SecTrust              │
        └────────┬────────┘  └──────────┬─────────────┘
                 │                      │
        ┌────────▼──────────────────────▼─────────────┐
        │         共享验证逻辑 (TLSHelper)               │
        │                                              │
        │  SecTrustSetAnchorCertificates(trust, certs) │
        │  SecTrustSetAnchorCertificatesOnly(trust, false)│
        │  SecTrustEvaluateAsyncWithError(trust, ...)   │
        └──────────────────────────────────────────────┘
```

### 2.2 需要改动的文件清单

| 文件 | 操作 | 改动内容 |
|------|------|---------|
| `ConnectOptions.swift` | 修改 | 新增 `customCACertificates: [Data]` 属性 |
| `ConnectOptions+Copy.swift` | 修改 | 同步新字段 |
| `TLSHelper.swift` | **新建** | 统一的 SecTrust 验证逻辑 |
| `WebSocket.swift` | 修改 | 接收证书参数 + 实现 `didReceive challenge:` |
| `QUICClient.swift` | 修改 | 接收证书参数 + 修改 verify block |
| `QUICSignalTransport.swift` | 修改 | 透传证书到 QUICClient |
| `HTTP.swift` | 修改 | 支持自定义根证书验证 |
| `SignalClient.swift` | 修改 | 透传证书到 HTTP.requestValidation |

---

## 三、详细实现方案

### 3.1 ConnectOptions — 用户配置入口

**文件**: `Sources/LiveKit/Types/Options/ConnectOptions.swift`

新增属性：

```swift
/// DER-encoded root CA certificates for custom TLS verification.
///
/// When non-empty, these certificates are added to the trust evaluation
/// for both WebSocket and QUIC signaling connections. This is required when
/// connecting to servers using self-signed certificates (e.g. IP-direct
/// connections with a private CA).
///
/// Both system trust store and custom certificates are trusted simultaneously.
/// Pass the DER-encoded Data of each root CA certificate.
public let customCACertificates: [Data]
```

所有 `init` 方法新增参数（默认空数组），`isEqual` 和 `hash` 同步更新。

### 3.2 TLSHelper — 统一验证逻辑

**文件**: `Sources/LiveKit/Support/Network/TLSHelper.swift`（新建）

```swift
import Foundation
import Security

/// Shared TLS trust evaluation logic for both WebSocket and QUIC connections.
enum TLSHelper: Loggable {

    /// Evaluates a SecTrust with optional custom CA certificates.
    ///
    /// When `customCACertificates` is empty, uses the system trust store only.
    /// When non-empty, injects the certificates as additional trust anchors while
    /// keeping system CAs trusted (SecTrustSetAnchorCertificatesOnly = false).
    ///
    /// - Parameters:
    ///   - trust: The SecTrust object from the TLS handshake.
    ///   - customCACertificates: DER-encoded root CA certificates.
    ///   - queue: Dispatch queue for async evaluation callback.
    ///   - completion: Called with (success, error).
    static func evaluate(
        trust: SecTrust,
        customCACertificates: [Data],
        queue: DispatchQueue = .global(qos: .userInitiated),
        completion: @escaping (_ success: Bool, _ error: Error?) -> Void
    ) {
        if !customCACertificates.isEmpty {
            let secCerts: [SecCertificate] = customCACertificates.compactMap {
                SecCertificateCreateWithData(nil, $0 as CFData)
            }

            if secCerts.isEmpty {
                log("All provided CA certificates failed DER parsing", .error)
            } else {
                // Inject custom root CAs into trust evaluation
                SecTrustSetAnchorCertificates(trust, secCerts as CFArray)
                // false = trust BOTH custom CAs AND system CAs
                SecTrustSetAnchorCertificatesOnly(trust, false)
            }
        }

        SecTrustEvaluateAsyncWithError(trust, queue) { _, result, error in
            completion(result, error)
        }
    }
}
```

**核心 API 说明**：

| API | 作用 |
|-----|------|
| `SecCertificateCreateWithData(_:_:)` | 将 DER Data 转为 SecCertificate 对象 |
| `SecTrustSetAnchorCertificates(_:_:)` | 设置自定义信任锚点（根 CA） |
| `SecTrustSetAnchorCertificatesOnly(_:_:)` | `false` = 同时信任自定义 + 系统 CA；`true` = 只信任自定义 CA |
| `SecTrustEvaluateAsyncWithError(_:_:_:)` | 异步执行完整证书链验证 |

### 3.3 WebSocket 路径改造

**文件**: `Sources/LiveKit/Support/Network/WebSocket.swift`

#### 改动 A：保存证书参数 + 添加 URLSessionDelegate 协议

```swift
// 类声明添加 URLSessionDelegate
final class WebSocket: NSObject, @unchecked Sendable, Loggable,
                       AsyncSequence, URLSessionDelegate, URLSessionWebSocketDelegate {

    // 新增：保存自定义 CA 证书
    private let customCACertificates: [Data]

    init(url: URL, token: String, connectOptions: ConnectOptions?,
         sendAfterOpen: Data?) async throws {
        self.customCACertificates = connectOptions?.customCACertificates ?? []
        // ... 其余不变
    }
```

#### 改动 B：实现认证挑战方法

```swift
// MARK: - URLSessionDelegate

func urlSession(
    _: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
          let serverTrust = challenge.protectionSpace.serverTrust
    else {
        completionHandler(.performDefaultHandling, nil)
        return
    }

    // No custom certs → system default handling (backward compatible)
    guard !customCACertificates.isEmpty else {
        completionHandler(.performDefaultHandling, nil)
        return
    }

    TLSHelper.evaluate(
        trust: serverTrust,
        customCACertificates: customCACertificates
    ) { success, error in
        if success {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            self.log("WebSocket TLS verification failed: \(error?.localizedDescription ?? "unknown")", .error)
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
```

**关键设计点**：
- `customCACertificates` 为空时返回 `.performDefaultHandling`，**完全保持原有行为**
- 只有在有自定义 CA 时才走自定义验证路径
- `URLCredential(trust:)` 表示接受此信任链
- `WebSocketSignalTransport` 已透传 `ConnectOptions`，无需改动

### 3.4 QUIC 路径改造

**文件**: `Sources/LiveKit/Support/Network/QUICClient.swift`

#### 改动 A：connect 方法接收证书参数

```swift
func connect(url: String, args: [String: Any],
             customCACertificates: [Data] = []) -> Int32 {
    // ... URL 解析逻辑不变 ...

    let parameters = createQUICParametersWithCustomVerification(
        quicOptions: quicOptions,
        host: host,
        customCACertificates: customCACertificates
    )
    // ... 其余不变
}
```

#### 改动 B：修改 verify block 使用 TLSHelper

```swift
private func createQUICParametersWithCustomVerification(
    quicOptions: NWProtocolQUIC.Options,
    host: String,
    customCACertificates: [Data]
) -> NWParameters {
    let securityOptions = quicOptions.securityProtocolOptions

    let customVerifyBlock: sec_protocol_verify_t = {
        [weak self] metadata, trust, completionHandler in
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()

        TLSHelper.evaluate(
            trust: secTrust,
            customCACertificates: customCACertificates
        ) { result, error in
            if !result {
                self?.log(
                    "QUIC TLS verification failed for \"\(host)\": "
                    + "\(error?.localizedDescription ?? "unknown")",
                    .error
                )
            }
            completionHandler(result)
        }
    }

    sec_protocol_options_set_verify_block(
        securityOptions, customVerifyBlock, .global(qos: .userInitiated)
    )
    sec_protocol_options_set_tls_server_name(securityOptions, host)

    return NWParameters(quic: quicOptions)
}
```

**文件**: `Sources/LiveKit/Support/Network/QUICSignalTransport.swift`

透传证书到 `QUICClient.connect()`：

```swift
// 在 maybeCreate 方法中
let ret = transport.client.connect(
    url: url.absoluteString,
    args: args,
    customCACertificates: connectOptions?.customCACertificates ?? []
)
```

### 3.5 HTTP 验证路径改造

**文件**: `Sources/LiveKit/Support/Network/HTTP.swift`

当连接失败时 `SignalClient` 会发起 HTTP validate 请求。自签证书场景下，该请求也会因证书不受信任而失败，需要同步支持。

```swift
class HTTP: NSObject, URLSessionDelegate {
    private static let operationQueue = OperationQueue()

    private let customCACertificates: [Data]

    private init(customCACertificates: [Data]) {
        self.customCACertificates = customCACertificates
        super.init()
    }

    private lazy var session: URLSession = .init(
        configuration: .default,
        delegate: customCACertificates.isEmpty ? nil : self,
        delegateQueue: Self.operationQueue
    )

    static func requestValidation(
        from url: URL, token: String,
        customCACertificates: [Data] = []
    ) async throws {
        let http = HTTP(customCACertificates: customCACertificates)
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: .defaultHTTPConnect
        )
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await http.session.data(for: request)
        // ... 后续 HTTP 状态码校验逻辑不变
    }

    // MARK: - URLSessionDelegate

    func urlSession(
        _: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust,
              !customCACertificates.isEmpty
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        TLSHelper.evaluate(
            trust: serverTrust,
            customCACertificates: customCACertificates
        ) { success, _ in
            if success {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }
}
```

**文件**: `Sources/LiveKit/Core/SignalClient.swift`

透传证书到 HTTP 验证调用：

```swift
try await HTTP.requestValidation(
    from: validateUrl,
    token: token,
    customCACertificates: connectOptions?.customCACertificates ?? []
)
```

---

## 四、用户 API 使用方式

```swift
// 1. 加载预埋的根证书 DER 文件
guard let certURL = Bundle.main.url(forResource: "my-root-ca", withExtension: "der"),
      let certData = try? Data(contentsOf: certURL)
else { fatalError("Missing root CA certificate") }

// 2. 配置连接选项（WebSocket 模式）
let wsOptions = ConnectOptions(
    transportKind: .websocket,
    customCACertificates: [certData]
)

// 3. 配置连接选项（QUIC 模式）
let quicOptions = ConnectOptions(
    transportKind: .quic,
    customCACertificates: [certData]
)

// 4. IP 直连
let room = Room()
try await room.connect(
    url: "wss://10.0.0.1:7880",
    token: token,
    connectOptions: wsOptions   // 或 quicOptions
)
```

不传 `customCACertificates`（默认空数组）时，所有行为与现有版本**完全一致**。

---

## 五、方案对比总结

### 5.1 两种模式对比

| 维度 | WebSocket | QUIC |
|------|-----------|------|
| 底层框架 | URLSession | Network.framework |
| TLS 拦截点 | `URLSessionDelegate.didReceive challenge:` | `sec_protocol_verify_t` block |
| 注入自定义 CA | `SecTrustSetAnchorCertificates` | 同左 |
| SNI 来源 | URL host（自动） | `sec_protocol_options_set_tls_server_name` |
| IP 直连兼容 | 原生支持 | 原生支持 |
| 验证逻辑 | 共享 TLSHelper | 同左 |
| 改动量 | 1 文件 | 2 文件 |

### 5.2 改动文件总览

| 文件 | 操作 | 改动量 |
|------|------|--------|
| `ConnectOptions.swift` | 修改 | 新增属性 + 3 个 init 同步 + isEqual/hash |
| `ConnectOptions+Copy.swift` | 修改 | 同步新字段 |
| `TLSHelper.swift` | 新建 | ~40 行 |
| `WebSocket.swift` | 修改 | +1 属性, +1 delegate 方法 (~25 行) |
| `QUICClient.swift` | 修改 | connect 签名变更 + verify block 改用 TLSHelper |
| `QUICSignalTransport.swift` | 修改 | 透传 1 个参数 (~1 行) |
| `HTTP.swift` | 修改 | 改为实例方法 + 添加 delegate (~30 行) |
| `SignalClient.swift` | 修改 | 透传 1 个参数 (~1 行) |

### 5.3 向后兼容性

| 场景 | 行为 |
|------|------|
| 不传 `customCACertificates`（默认） | 空数组 → 所有路径走 `.performDefaultHandling` / 系统信任库，**行为完全不变** |
| 传入自定义 CA 证书 | 注入自定义 CA + 系统 CA 同时受信，自签证书可通过验证 |
| DER 解析失败 | `compactMap` 过滤无效证书，输出 error 日志，继续使用系统信任库 |
| 全部 DER 无效 | 等同于空数组，使用系统信任库（可能导致验证失败） |

### 5.4 安全性保证

- 自定义 CA 证书仅添加为信任锚点，**不会绕过完整的证书链验证**（证书有效期、签名、SAN 匹配等仍由系统检查）
- `SecTrustSetAnchorCertificatesOnly(trust, false)` 确保系统 CA 仍然受信，不影响正常域名连接
- 所有验证失败都会输出 error 级别日志，便于排查
