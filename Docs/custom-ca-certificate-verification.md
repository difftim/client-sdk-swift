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

### 1.3 URLSession 方案的局限性

初始方案通过 `URLSessionDelegate.didReceive challenge:` 注入自定义 CA 证书。评估后发现 URLSession 存在以下平台级限制：

| 限制 | 说明 |
|------|------|
| **ATS 强制执行** | URLSession 受 App Transport Security 约束，系统会在 delegate 被调用之前执行 ATS 策略检查 |
| **验证时序在系统之后** | `didReceive challenge:` 是系统构建 SecTrust 并形成初步评估意见**之后**才回调，不能替换验证策略 |
| **CT/OCSP 检查不可控** | 部分 iOS 版本在 URLSession 层面强制执行 Certificate Transparency 和 OCSP 检查 |
| **TLS 参数不可调** | 无法通过 URLSession API 指定最低/最高 TLS 版本、cipher suite 偏好 |

### 1.4 最终方案：Network.framework (NWConnection + NWProtocolWebSocket)

`Network.framework` 通过 `sec_protocol_options_set_verify_block` 提供 **完全的 TLS 验证控制权**：

- verify block 是**唯一的**验证入口，系统不会预先干预
- 不受 ATS 约束
- 可配置 TLS 版本、cipher suite
- 与 QUIC 路径使用完全相同的验证机制
- `NWProtocolWebSocket` 提供原生 WebSocket 支持（iOS 13+）

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
| NWWebSocket | `sec_protocol_options_set_tls_server_name(securityOptions, host)` | `host` 来自 URL 解析即为 IP |
| QUIC | `sec_protocol_options_set_tls_server_name(securityOptions, host)` | 同上 |

两条路径使用完全一致的 SNI 设置方式。

---

## 二、架构设计

### 2.1 数据流全景

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  用户层                                                                       │
│  ConnectOptions(customCACertificates: [Data])                                 │
└────────────────────────────┬─────────────────────────────────────────────────┘
                             │
                ┌────────────▼────────────┐
                │  SignalTransportFactory  │
                └──┬──────────┬───────────┘
                   │          │
    ┌──────────────▼──┐  ┌───▼─────────────────────┐
    │ WebSocket 路径    │  │      QUIC 路径            │
    │                  │  │                          │
    │  有自定义证书?     │  │  QUICSignalTransport     │
    │  ├─ 是 ───────┐  │  │  ↓                       │
    │  │ NWWebSocket │  │  │  QUICClient.connect()   │
    │  │ (Network.fw)│  │  │  ↓                       │
    │  │ sec_proto.. │  │  │  sec_protocol_verify_t  │
    │  ├─ 否 ───────┐  │  └──────────┬───────────────┘
    │  │ WebSocket   │  │             │
    │  │ (URLSession)│  │             │
    │  │ 系统默认处理  │  │             │
    └──┴────────┬───┘  │             │
               │                     │
    ┌──────────▼─────────────────────▼──────────────────────┐
    │          共享验证逻辑 (TLSHelper)                        │
    │                                                        │
    │  SecTrustSetAnchorCertificates(trust, certs)           │
    │  SecTrustSetAnchorCertificatesOnly(trust, false)       │
    │  SecTrustEvaluateAsyncWithError(trust, ...)            │
    └────────────────────────────────────────────────────────┘
```

### 2.2 WebSocket 双路径自动切换

`SignalTransportFactory` 根据是否提供 `customCACertificates` 自动选择 WebSocket 实现：

| 条件 | 选择的 Transport | 底层实现 | TLS 控制 |
|------|-----------------|---------|----------|
| `customCACertificates` 为空 | `WebSocketSignalTransport` | URLSession + URLSessionWebSocketTask | 系统默认 |
| `customCACertificates` 非空 | `NWWebSocketSignalTransport` | NWConnection + NWProtocolWebSocket | `sec_protocol_verify_t` 完全自控 |

```swift
// SignalTransportFactory.create() 中的自动切换逻辑
if transport == nil {
    let hasCustomCerts = !(options?.customCACertificates ?? []).isEmpty
    if hasCustomCerts {
        transport = try await NWWebSocketSignalTransport(...)
    } else {
        transport = try await WebSocketSignalTransport(...)
    }
}
```

### 2.3 改动文件清单

| 文件 | 操作 | 改动内容 |
|------|------|---------|
| `ConnectOptions.swift` | 修改 | 新增 `customCACertificates: [Data]` 属性 |
| `ConnectOptions+Copy.swift` | 修改 | 同步新字段 |
| `TLSHelper.swift` | **新建** | 统一的 SecTrust 验证逻辑 |
| `NWWebSocket.swift` | **新建** | 基于 NWConnection + NWProtocolWebSocket 的 WebSocket 实现 |
| `NWWebSocketSignalTransport.swift` | **新建** | NWWebSocket 的 SignalTransport 适配层 |
| `SignalTransport.swift` | 修改 | Factory 根据自定义证书自动切换 WebSocket 实现 |
| `WebSocket.swift` | 修改 | 保留 URLSessionDelegate 作为后备方案 |
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

enum TLSHelper: Loggable {
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
                SecTrustSetAnchorCertificates(trust, secCerts as CFArray)
                // Trust both custom CAs and system CAs
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

### 3.3 NWWebSocket — 基于 Network.framework 的 WebSocket

**文件**: `Sources/LiveKit/Support/Network/NWWebSocket.swift`（新建）

当提供 `customCACertificates` 时，WebSocket 连接使用 `NWConnection` + `NWProtocolWebSocket` 替代 URLSession，获得完全的 TLS 控制权。

#### 核心架构

```swift
@available(iOS 13.0, macOS 10.15, tvOS 13.0, *)
final class NWWebSocket: @unchecked Sendable, Loggable {
    private var connection: NWConnection?
    private let connectionQueue = DispatchQueue(label: "lk.nwwebsocket", qos: .userInitiated)

    let stream: AsyncThrowingStream<URLSessionWebSocketTask.Message, Error>
    // ...
}
```

#### TLS 配置 — sec_protocol_verify_t

```swift
private static func createTLSOptions(
    host: String,
    customCACertificates: [Data]
) -> NWProtocolTLS.Options {
    let tlsOptions = NWProtocolTLS.Options()
    let securityOptions = tlsOptions.securityProtocolOptions

    let verifyBlock: sec_protocol_verify_t = { _, trust, completionHandler in
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()

        TLSHelper.evaluate(
            trust: secTrust,
            customCACertificates: customCACertificates
        ) { result, _ in
            completionHandler(result)
        }
    }

    sec_protocol_options_set_verify_block(
        securityOptions, verifyBlock, .global(qos: .userInitiated)
    )
    sec_protocol_options_set_tls_server_name(securityOptions, host)

    return tlsOptions
}
```

#### 连接建立

```swift
// NWProtocolWebSocket 配置
let wsOptions = NWProtocolWebSocket.Options()
wsOptions.autoReplyPing = true
wsOptions.setAdditionalHeaders([
    ("Authorization", "Bearer \(token)"),
    ("User-Agent", userAgent)
])

// NWParameters 配置 TLS + WebSocket
let parameters = NWParameters(tls: createTLSOptions(host: host, customCACertificates: certs))
parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

// 使用 .url() endpoint 保留完整路径 (wss://host:port/rtc?...)
let connection = NWConnection(to: .url(url), using: parameters)
connection.start(queue: connectionQueue)
```

#### 消息收发

```swift
// 发送 — 通过 NWProtocolWebSocket.Metadata 指定 opcode
func send(data: Data) async throws {
    let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
    let context = NWConnection.ContentContext(identifier: "ws-send", metadata: [metadata])
    try await withCheckedThrowingContinuation { continuation in
        connection.send(content: data, contentContext: context, isComplete: true,
                        completion: .contentProcessed { error in ... })
    }
}

// 接收 — 递归调用 receiveMessage，解析 WebSocket metadata
private func receiveNextMessage() {
    connection.receiveMessage { content, context, isComplete, error in
        if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
            as? NWProtocolWebSocket.Metadata
        {
            switch metadata.opcode {
            case .binary: continuation.yield(.data(data))
            case .text:   continuation.yield(.string(text))
            case .close:  continuation.finish()
            // ...
            }
        }
        self.receiveNextMessage()
    }
}
```

### 3.4 NWWebSocketSignalTransport — 适配层

**文件**: `Sources/LiveKit/Support/Network/NWWebSocketSignalTransport.swift`（新建）

```swift
@available(iOS 13.0, macOS 10.15, tvOS 13.0, *)
final class NWWebSocketSignalTransport: SignalTransport, @unchecked Sendable {
    private let socket: NWWebSocket

    init(url: URL, token: String, connectOptions: ConnectOptions?,
         sendAfterOpen: Data?) async throws {
        socket = try await NWWebSocket(url: url, token: token,
                                        connectOptions: connectOptions,
                                        sendAfterOpen: sendAfterOpen)
        super.init()
        _stream = AsyncThrowingStream { continuation in
            Task.detached { [weak self] in
                guard let self else { return }
                do {
                    for try await message in socket.stream {
                        continuation.yield(message)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: LiveKitError.from(error: error))
                }
            }
        }
    }

    override func send(data: Data) async throws {
        try await socket.send(data: data)
    }

    override func close() {
        socket.close()
    }
}
```

### 3.5 SignalTransportFactory — 自动切换逻辑

**文件**: `Sources/LiveKit/Support/SignalTransport.swift`

```swift
enum SignalTransportFactory: Loggable {
    static func create(kind: TransportKind, url: URL, token: String,
                       options: ConnectOptions?, sendAfterOpen: Data?) async throws -> SignalTransport
    {
        var transport: SignalTransport?

        if kind == .quic {
            if #available(iOS 15.0, macOS 12.0, tvOS 15.0, *) {
                transport = try await QUICSignalTransport.maybeCreate(...)
            }
        }

        if transport == nil {
            let hasCustomCerts = !(options?.customCACertificates ?? []).isEmpty
            if hasCustomCerts {
                // Network.framework: 完全 TLS 自控
                transport = try await NWWebSocketSignalTransport(...)
            } else {
                // URLSession: 系统默认行为
                transport = try await WebSocketSignalTransport(...)
            }
        }

        guard let transport else { throw LiveKitError(.network) }
        return transport
    }
}
```

### 3.6 QUIC 路径改造

**文件**: `Sources/LiveKit/Support/Network/QUICClient.swift`

#### connect 方法接收证书参数

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

#### verify block 使用 TLSHelper

```swift
private func createQUICParametersWithCustomVerification(
    quicOptions: NWProtocolQUIC.Options,
    host: String,
    customCACertificates: [Data]
) -> NWParameters {
    let securityOptions = quicOptions.securityProtocolOptions

    let customVerifyBlock: sec_protocol_verify_t = { [weak self] _, trust, completionHandler in
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()

        TLSHelper.evaluate(
            trust: secTrust,
            customCACertificates: customCACertificates
        ) { result, error in
            if !result {
                self?.log("QUIC TLS verification failed for \"\(host)\": "
                    + "\(error?.localizedDescription ?? "unknown")", .error)
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
let ret = transport.client.connect(
    url: url.absoluteString,
    args: args,
    customCACertificates: connectOptions?.customCACertificates ?? []
)
```

### 3.7 HTTP 验证路径改造

**文件**: `Sources/LiveKit/Support/Network/HTTP.swift`

当连接失败时 `SignalClient` 会发起 HTTP validate 请求。自签证书场景下，该请求也会因证书不受信任而失败，需要同步支持。

```swift
final class HTTP: NSObject, @unchecked Sendable, URLSessionDelegate, Loggable {
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
        defer { http.session.finishTasksAndInvalidate() }  // 打破 URLSession → delegate 循环引用

        var request = URLRequest(url: url, ...)
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await http.session.data(for: request)
        // ... HTTP 状态码校验逻辑不变
    }

    func urlSession(_: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust,
              !customCACertificates.isEmpty
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        TLSHelper.evaluate(trust: serverTrust, customCACertificates: customCACertificates) { success, error in
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

### 4.1 基本用法

```swift
// 1. 加载预埋的根证书 DER 文件
guard let certURL = Bundle.main.url(forResource: "my-root-ca", withExtension: "der"),
      let certData = try? Data(contentsOf: certURL)
else { fatalError("Missing root CA certificate") }

// 2. 配置连接选项（WebSocket 模式 — 自动使用 NWWebSocket）
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

### 4.2 多证书支持

```swift
// 同时预埋多个根 CA（例如主备证书轮换场景）
let cert1 = try Data(contentsOf: Bundle.main.url(forResource: "ca-primary", withExtension: "der")!)
let cert2 = try Data(contentsOf: Bundle.main.url(forResource: "ca-backup", withExtension: "der")!)

let options = ConnectOptions(
    customCACertificates: [cert1, cert2]
)
```

### 4.3 跳过证书验证（仅限开发/测试环境）

```swift
// WARNING: 仅用于开发/测试环境，生产环境严禁使用！
// 跳过所有 TLS 证书验证，接受任何服务端证书（包括过期、自签、不匹配的证书）
let options = ConnectOptions(
    insecureSkipTLSVerify: true
)

let room = Room()
try await room.connect(
    url: "wss://10.0.0.1:7880",
    token: token,
    connectOptions: options
)
```

当 `insecureSkipTLSVerify = true` 时：
- WebSocket 自动切换到 NWWebSocket（与自定义证书相同路径）
- `TLSHelper.evaluate()` 直接返回 `completion(true, nil)`，不执行任何证书链评估
- 与 `customCACertificates` 可同时设置，但 `insecureSkipTLSVerify` 优先生效
- 每次跳过都会输出 `.warning` 级别日志

### 4.4 不传证书（默认行为）

```swift
// 不传 customCACertificates（默认空数组）且 insecureSkipTLSVerify 为 false 时，
// 所有行为与原有版本完全一致
let options = ConnectOptions(transportKind: .websocket)
// → 使用 URLSession WebSocket，系统默认 TLS 处理
```

---

## 五、方案对比总结

### 5.1 三种传输模式对比

| 维度 | NWWebSocket (有自定义证书) | URLSession WebSocket (无自定义证书) | QUIC |
|------|--------------------------|-----------------------------------|----|
| 底层框架 | Network.framework | URLSession | Network.framework |
| TLS 验证入口 | `sec_protocol_verify_t` (唯一入口) | `didReceive challenge:` (系统后置回调) | `sec_protocol_verify_t` (唯一入口) |
| ATS 约束 | **无** | 有 | **无** |
| TLS 版本可控 | 是 (`sec_protocol_options`) | 否 | 是 |
| CT/OCSP 检查 | **可自控** | 系统强制 | **可自控** |
| 注入自定义 CA | TLSHelper | TLSHelper | TLSHelper |
| SNI 来源 | `sec_protocol_options_set_tls_server_name` | URL host（自动） | `sec_protocol_options_set_tls_server_name` |
| IP 直连兼容 | 原生支持 | 原生支持 | 原生支持 |

### 5.2 改动文件总览

| 文件 | 操作 | 改动量 |
|------|------|--------|
| `ConnectOptions.swift` | 修改 | 新增属性 + 3 个 init 同步 + isEqual/hash |
| `ConnectOptions+Copy.swift` | 修改 | 同步新字段 |
| `TLSHelper.swift` | **新建** | ~50 行 |
| `NWWebSocket.swift` | **新建** | ~300 行 |
| `NWWebSocketSignalTransport.swift` | **新建** | ~55 行 |
| `SignalTransport.swift` | 修改 | Factory 自动切换逻辑 (~8 行) |
| `WebSocket.swift` | 修改 | +1 属性, +1 delegate 方法 (~35 行，URLSession 后备方案) |
| `QUICClient.swift` | 修改 | connect 签名变更 + verify block 改用 TLSHelper |
| `QUICSignalTransport.swift` | 修改 | 透传 1 个参数 (~1 行) |
| `HTTP.swift` | 修改 | 改为实例方法 + 添加 delegate (~40 行) |
| `SignalClient.swift` | 修改 | 透传 1 个参数 (~1 行) |

### 5.3 向后兼容性

| 场景 | 行为 |
|------|------|
| 不传 `customCACertificates`（默认）且 `insecureSkipTLSVerify = false` | 空数组 → WebSocket 走 URLSession（系统默认），QUIC 走系统信任库，**行为完全不变** |
| 传入自定义 CA 证书 | WebSocket 自动切换到 NWWebSocket (Network.framework)，QUIC 注入自定义 CA，同时信任自定义 + 系统 CA |
| `insecureSkipTLSVerify = true` | WebSocket 自动切换到 NWWebSocket，所有路径跳过证书验证直接通过，输出 warning 日志 |
| DER 解析失败 | `compactMap` 过滤无效证书，输出 error 日志，继续使用系统信任库 |
| 全部 DER 无效 | 等同于空数组，使用系统信任库（可能导致验证失败） |

### 5.4 安全性保证

- 自定义 CA 证书仅添加为信任锚点，**不会绕过完整的证书链验证**（证书有效期、签名、SAN 匹配等仍由系统检查）
- `SecTrustSetAnchorCertificatesOnly(trust, false)` 确保系统 CA 仍然受信，不影响正常域名连接
- `insecureSkipTLSVerify` 仅用于开发/测试环境，每次跳过时输出 `.warning` 级别日志便于识别生产环境误用
- 所有验证失败都会输出 error 级别日志，便于排查
- HTTP.requestValidation 使用 `defer { session.finishTasksAndInvalidate() }` 防止 URLSession/delegate 循环引用导致的内存泄漏
