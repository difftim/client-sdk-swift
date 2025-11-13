/*
 * Copyright 2025 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation
import Network

// MARK: - 常量和错误定义

/// WTMessage 头部固定大小
let WTMessageHeaderSize = 17

/// 消息类型常量 (与 Go iota 保持一致)
enum WTMessageType: UInt8 {
    case none = 0
    case cmd
    case binary
    case text
    case ping
    case pong
}

enum WTMessageError: Error {
    case decodeToNilMessage
    case unexpectedHeaderEOF
    case bufferTooSmall(actualLength: Int, expectedSize: Int)
}

// MARK: - WTMessage 结构体定义

/**
 * WTMessage 代表一个单一的 RPC 消息包。
 * 它使用内部缓冲区 (Raw) 来实现零拷贝编解码。
 * * 注意：在 Swift 实现中，我们倾向于使用 Data 来管理缓冲区，
 * 结构体语义保证了赋值时的深拷贝，简化了 Go 语言中的“使用约束”。
 */
struct WTMessage {
    // 头部字段
    var type: WTMessageType = .none
    var length: UInt32 = 0 // 消息体长度 len(Data)
    var timestamp: UInt64 = 0
    var transId: UInt32 = 0

    // 消息体数据
    var data: Data = .init()

    // 内部原始缓冲区（包含头部和消息体）
    var raw: Data = .init()

    // MARK: - 初始化

    /// 初始化 WTMessage 并预分配 Raw 缓冲区。
    init(messageType: WTMessageType, transId: UInt32) {
        let defaultRawCapacity = 1500
        self.transId = transId
        type = messageType

        // 预分配 Raw，包含 HeaderSize
        raw = Data(count: WTMessageHeaderSize)
        raw.reserveCapacity(defaultRawCapacity)

        // 首次写入 Header，设置当前时间戳
        writeHeader()
    }

    // 默认初始化器，用于解码
    init() {}

    // MARK: - 头部和数据写入 (对应 Go 的 WriteHeader/WriteData)

    /// 写入头部到 Raw 缓冲区。
    mutating func writeHeader() {
        // 确保 Raw 至少有 HeaderSize 长度
        if raw.count < WTMessageHeaderSize {
            raw.count = WTMessageHeaderSize
        }

        // 使用 withUnsafeMutableBytes 进行高效写入
        raw.withUnsafeMutableBytes { buffer in
            let header = buffer.baseAddress!

            // 0: Type (1 byte)
            header.storeBytes(of: type.rawValue, toByteOffset: 0, as: UInt8.self)

            // 1-4: Length (4 bytes, BigEndian)
            var bigLength = length.bigEndian
            header.advanced(by: 1).copyMemory(from: &bigLength, byteCount: 4)

            // 5-12: Timestamp (8 bytes, BigEndian) - 使用当前时间
            var now = UInt64(Date().timeIntervalSince1970 * 1000).bigEndian
            header.advanced(by: 5).copyMemory(from: &now, byteCount: 8)
            timestamp = now.bigEndian // 更新结构体字段

            // 13-16: TransId (4 bytes, BigEndian)
            var bigTransId = transId.bigEndian
            header.advanced(by: 13).copyMemory(from: &bigTransId, byteCount: 4)
        }
    }

    /// 写入数据到 Raw 缓冲区并更新头部信息。
    mutating func writeData(_ data: Data) {
        self.data = data
        length = UInt32(data.count)

        // 1. 重新写入头部（主要更新 Type 和 Length）
        writeHeader()

        // 2. 移除旧数据，追加新数据
        // 保持 Raw 中只有 HeaderSize 的内容
        raw.count = WTMessageHeaderSize
        raw.append(data)

        // 注意：Go 实现中 length 字段为 len(Raw) - HeaderSize，这里已设置。
    }

    // MARK: - 编码与解码

    /// 将消息内容编码到 Raw 缓冲区 (对应 Go 的 Encode)。
    mutating func encode(with data: Data) {
        // 1. 清空 Raw (Go: m.Raw = m.Raw[:0])
        raw.removeAll(keepingCapacity: true)

        // 2. 写入头部和数据
        writeData(data)

        // Go 实现中最后会设置 m.Length = 0，这里保持 length 为实际数据长度更符合 Swift 结构体语义。
    }

    /// 从原始 Data 解码消息 (对应 Go 的 Decode 核心逻辑)。
    mutating func decode(from buf: Data) throws {
        // 1. 检查头部长度
        guard buf.count >= WTMessageHeaderSize else {
            throw WTMessageError.unexpectedHeaderEOF
        }

        // 2. 使用 withUnsafeBytes 高效读取头部
        try buf.withUnsafeBytes { buffer in
            let header = buffer.baseAddress!

            // 0: Type (1 byte)
            type = WTMessageType(rawValue: header.load(fromByteOffset: 0, as: UInt8.self)) ?? .none

            // 1-4: Length (4 bytes, BigEndian) - 偏移量 1，需要 loadUnaligned
            length = header.loadUnaligned(fromByteOffset: 1, as: UInt32.self).bigEndian

            // 5-12: Timestamp (8 bytes, BigEndian) - 偏移量 5，需要 loadUnaligned
            timestamp = header.loadUnaligned(fromByteOffset: 5, as: UInt64.self).bigEndian

            // 13-16: TransId (4 bytes, BigEndian) - 偏移量 13，需要 loadUnaligned
            transId = header.loadUnaligned(fromByteOffset: 13, as: UInt32.self).bigEndian

            let fullSize = Int(length) + WTMessageHeaderSize

            // 3. 检查完整消息长度
            guard buf.count >= fullSize else {
                throw WTMessageError.bufferTooSmall(actualLength: buf.count, expectedSize: fullSize)
            }

            // 4. 保存原始缓冲区和消息体数据
//            self.raw = buf // 保存原始数据
//            self.data = buf.subdata(in: WTMessageHeaderSize..<fullSize) // 提取消息体
            data = Data(bytes: header + WTMessageHeaderSize, count: Int(length))
        }
    }

    // MARK: - 实用方法

    /// 重置消息 (对应 Go 的 Reset)。
    mutating func reset() {
        raw.removeAll(keepingCapacity: true)
        type = .none
        length = 0
        timestamp = 0
        transId = 0
        data.removeAll(keepingCapacity: true)
    }

    /// 克隆消息到目标 (对应 Go 的 CloneTo)。
    func clone(to other: inout WTMessage) throws {
        other.raw = raw // 结构体 Data 赋值是深拷贝
        try other.decode(from: other.raw)
    }
}

// MARK: - 二进制协议转换（顶层函数）

extension WTMessage {
    /// 顶层解码函数 (对应 Go 的 Decode)。
    /// 从 Data 解码，并返回剩余的 Data。
    static func decode(data: Data, to message: inout WTMessage) throws -> Data {
        try message.decode(from: data)

        let fullSize = Int(message.length) + WTMessageHeaderSize

        // 返回剩余的 Data
        return data.dropFirst(fullSize)
    }
}

// MARK: - WTMessageDelegate 协议定义

/// QUICClient 用于处理收到的 WTMessage 数据和连接状态变化的委托协议
@available(iOS 15.0, macOS 12.0, tvOS 15.0, *)
protocol WTMessageDelegate: AnyObject {
    // MARK: - 数据回调

    /**
     * 当从 QUIC 连接收到完整的 WTMessage 并成功解码时调用。
     * - Parameter client: 触发此回调的 QUICClient 实例。
     * - Parameter message: 成功解码的 WTMessage 结构体。
     */
    func quicClient(
        _ client: QUICClient,
        didReceiveData data: Data
    )

    // MARK: - 连接状态和事件回调

    /**
     * 当 QUIC 连接成功建立并处于 .ready 状态时调用。
     * - Parameter client: 触发此回调的 QUICClient 实例。
     */
    func quicClientDidConnect(_ client: QUICClient, args: [String: Any])

    /**
     * 当 QUIC 发送数据完成时调用。
     * - Parameter client: 触发此回调的 QUICClient 实例。
     */
    func quicClientDidSend(_ client: QUICClient, size: Int)

    /**
     * 当 QUIC 连接因错误而失败时调用。
     * - Parameter client: 触发此回调的 QUICClient 实例。
     * - Parameter error: 导致连接失败的 NWError。
     */
    func quicClient(_ client: QUICClient, didFailWithError error: NWError)

    /**
     * 当 QUIC 连接被取消或优雅关闭时调用。
     * - Parameter client: 触发此回调的 QUICClient 实例。
     */
    func quicClientDidDisconnect(_ client: QUICClient)
}

// MARK: - QUICClient 类定义

@available(iOS 15.0, macOS 12.0, tvOS 15.0, *)
class QUICClient: NSObject, Loggable, @unchecked Sendable {
    enum ClientStateType: UInt8 {
        case INIT = 0
        case CONNECTING
        case CONNECTED
        case CLOSED
    }

    private let KEEP_ALIVE_INTERVAL: TimeInterval = 10
    // Dedicated queue for NWConnection callbacks and QUIC processing (avoid main queue)
    private let connectionQueue = DispatchQueue(label: "io.livekit.quic.connection", qos: .userInitiated)
    private var stream: NWConnection?
    private var nextTransId: UInt32 = 1
    var delegate: WTMessageDelegate?
    private var state: ClientStateType = .INIT
    private var props: [String: Any]?
    private var buffer: Data = .init()
    private var pingTimer: DispatchSourceTimer?

    override init() {
        super.init()
    }

    func setDelegate(delegate: WTMessageDelegate) {
        self.delegate = delegate
    }

    func connect(url: String, args: [String: Any]) -> Int32 {
        // 解析URL
        guard let u = URLComponents(string: url) else {
            return -1
        }

        let scheme = u.scheme ?? ""
        let host = u.host ?? ""
        let port = UInt16(u.port ?? 443)
        let path = u.path.isEmpty ? "/" : u.path
        let query = u.query ?? ""

//        log("解析后的URL组件: scheme=\(scheme), host=\(host), port=\(port), path=\(path)")

        var props = [String: Any]()

        props["scheme"] = scheme
        props["host"] = host
        props["port"] = port
        props["path"] = path
        props["query"] = query
        for (key, value) in args {
            props[key] = value
        }
        self.props = props
        // 1. 定义 QUIC 协议和 ALPN
        let quicOptions = NWProtocolQUIC.Options(alpn: ["ttsignal"])
        quicOptions.idleTimeout = 30000
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, *) {
            quicOptions.maxDatagramFrameSize = 1600
        }
        quicOptions.direction = .bidirectional

        let parameters = createQUICParametersWithCustomVerification(quicOptions: quicOptions) // 假设这个函数返回 NWParameters

        // 2. 使用属性存储，确保强引用
        let nwport = NWEndpoint.Port(rawValue: port)!
        let stream = NWConnection(to: .hostPort(host: NWEndpoint.Host(host), port: nwport), using: parameters)
        self.stream = stream

        // 4. 设置 Group 状态更新（在自定义队列上回调）
        stream.stateUpdateHandler = { [weak self] newState in
            self?.handleStateChange(newState)
        }

        // 5. 启动 Group（使用自定义队列，避免在主队列上运行）
        stream.start(queue: connectionQueue)
        state = .CONNECTING
        return 0
    }

    func sendData(data: Data) -> Int32 {
        if state != .CONNECTED {
            return -1
        }
        guard let stream else {
            return -2
        }
        var message = WTMessage(messageType: .binary, transId: 0)
        message.encode(with: data)
        let context = NWConnection.ContentContext(identifier: "send", isFinal: false)
        stream.send(content: message.raw,
                    contentContext: context,
                    isComplete: false, // 控制流通常保持打开状态
                    completion: .contentProcessed { [weak self] error in
                        guard let self else { return }
                        if let error {
                            delegate?.quicClient(self, didFailWithError: error)
                        } else {
                            delegate?.quicClientDidSend(self, size: data.count)
                        }
                    })
        return 0
    }

    func sendCmd(name: String, transId: UInt32, args: [String: Any]) -> Int32 {
        if state != .CONNECTED, name != "connect", nextTransId != 1 {
            return -1
        }
        guard let stream else {
            return -2
        }

        var cmd: [String: Any] = [:]
        cmd["name"] = name
        cmd["transId"] = transId
        cmd["props"] = args
        if let cmdPkg = try? JSONSerialization.data(withJSONObject: cmd, options: []) {
            var message = WTMessage(messageType: .cmd, transId: transId)
            message.encode(with: cmdPkg)
            let context = NWConnection.ContentContext(identifier: "send", isFinal: false)
            stream.send(content: message.raw,
                        contentContext: context,
                        isComplete: false, // 控制流通常保持打开状态
                        completion: .contentProcessed { [weak self] error in
                            guard let self else { return }
                            if let error {
                                delegate?.quicClient(self, didFailWithError: error)
                            } else {
                                delegate?.quicClientDidSend(self, size: cmdPkg.count)
                            }
                        })
            return 0
        }
        return -1
    }

    func close() {
        if let stream {
            stream.cancel()
            self.stream = nil
        }
        // stop timer
        stopPingTimer()
    }

    private func sendPing() {
        if state != .CONNECTED {
            return
        }
        guard let stream else {
            return
        }
        var message = WTMessage(messageType: .ping, transId: nextTransId)
        nextTransId += 1
        message.encode(with: Data())
        let context = NWConnection.ContentContext(identifier: "send", isFinal: false)
        stream.send(content: message.raw,
                    contentContext: context,
                    isComplete: false, // 控制流通常保持打开状态
                    completion: .contentProcessed { [weak self] error in
                        guard let self else { return }
                        if let error {
                            delegate?.quicClient(self, didFailWithError: error)
                        }
                    })
    }

    private func sendPong(transId: UInt32) {
        if state != .CONNECTED {
            return
        }
        guard let stream else {
            return
        }
        var message = WTMessage(messageType: .pong, transId: transId)
        message.encode(with: Data())
        let context = NWConnection.ContentContext(identifier: "send", isFinal: false)
        stream.send(content: message.raw,
                    contentContext: context,
                    isComplete: false, // 控制流通常保持打开状态
                    completion: .contentProcessed { [weak self] error in
                        guard let self else { return }
                        if let error {
                            delegate?.quicClient(self, didFailWithError: error)
                        }
                    })
    }

    private func onRecvMessage(_ message: inout WTMessage) {
        switch message.type {
        case .cmd:
            // 处理cmd
            if let cmdObj = try? JSONSerialization.jsonObject(with: message.data, options: []) {
                if let cmd = cmdObj as? [String: Any] {
                    let cmdName = cmd["name"] as? String
                    let transId = cmd["transId"] as? UInt32
                    let cmdArgs = cmd["props"] as? [String: Any] ?? [:]
                    switch cmdName {
                    case "_result":
                        if transId == 1 {
                            state = .CONNECTED
                            delegate?.quicClientDidConnect(self, args: cmdArgs)
                            startPingTimer()
                        }
                    default:
                        break
                    }
                }
            }
        case .ping:
            // 响应ping
            sendPong(transId: message.transId)
        case .pong:
            // 收到pong
            break
        case .binary:
            delegate?.quicClient(self, didReceiveData: message.data)
        default:
            // 处理其他消息
            break
        }
    }

    // 开始ping定时器（使用 DispatchSourceTimer，运行在 connectionQueue 上）
    private func startPingTimer() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: connectionQueue)
        timer.schedule(deadline: .now() + KEEP_ALIVE_INTERVAL, repeating: KEEP_ALIVE_INTERVAL)
        timer.setEventHandler { [weak self] in
            self?.sendPing()
        }
        pingTimer = timer
        timer.resume()
    }

    // 停止ping定时器
    private func stopPingTimer() {
        pingTimer?.cancel()
        pingTimer = nil
    }

    private func handleStateChange(_ newState: NWConnection.State) {
        switch newState {
        case .setup:
            log("Raw QUIC Client连接正在设置中...")

        case let .waiting(error):
            // 捕获 waiting 状态下的错误
            log("Raw QUIC Client连接正在等待网络路径，遇到错误: \(error.localizedDescription)")

        case .preparing:
            log("Raw QUIC Client连接正在准备中...")

        case .ready:
            log("Raw QUIC Client隧道已建立，可以接收入站流和创建出站流。")

            guard let stream else {
                log("Raw QUIC Client invalid connection")
                return
            }
            // 将props转换为JSON对象并编码成字符串
            if let props {
                let ret = sendCmd(name: "connect", transId: nextTransId, args: props)
                if ret != 0 {
                    close()
                    break
                }
                nextTransId += 1
            }
            receiveDataOnStream(stream: stream)

        case let .failed(error):
            // ✨ 关键步骤：使用 case let 捕获 .failed 关联的 NWError
            log("Raw QUIC Client连接失败！错误类型: \(error)")

            // 进一步判断具体的错误类型
            if error == .posix(.ECONNREFUSED) {
                log("Raw QUIC Client具体的失败原因：连接被拒绝 (Connection Refused)。")
            } else if error == .dns(DNSServiceErrorType(kDNSServiceErr_NoSuchRecord)) {
                log("Raw QUIC Client具体的失败原因：DNS 查询失败，无此记录。")
            }
            state = .CLOSED
            delegate?.quicClient(self, didFailWithError: error)
            stopPingTimer()

        case .cancelled:
            log("连接已被取消。")
            state = .CLOSED
            delegate?.quicClientDidDisconnect(self)
            stopPingTimer()

        // 如果没有覆盖所有情况，需要 default
        @unknown default:
            log("Raw QUIC Client遇到未知连接状态。")
        }
    }

    // 接收数据的函数
    private func receiveDataOnStream(stream: NWConnection) {
        stream.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if isComplete {
                log("Raw QUIC Client数据传输管道关闭。")
                return
            }
            if let error {
                log("Raw QUIC Client接收错误: \(error)")
                return
            }
            guard let data, !data.isEmpty else { return }

            // 1. 缓存数据到buffer中
            buffer.append(data)

            // 2. 循环解码数据
            var message = WTMessage()
            decodeLoop: while true {
                do {
                    let undecoded = try WTMessage.decode(data: buffer, to: &message)
                    onRecvMessage(&message)
                    buffer = undecoded
                    if buffer.isEmpty { break decodeLoop }
                } catch let err as WTMessageError {
                    switch err {
                    case .unexpectedHeaderEOF, .bufferTooSmall:
                        break decodeLoop // 等待更多数据
                    case .decodeToNilMessage:
                        self.handleDecodingFatalError(error: err)
                        break decodeLoop
                    }
                } catch {
                    handleDecodingFatalError(error: error)
                    break decodeLoop
                }
            }

            // 继续监听后续数据
            receiveDataOnStream(stream: stream)
        }
    }

    private func handleDecodingFatalError(error: Error) {
        log("Raw QUIC Client Fatal decoding error: \(error.localizedDescription)")
        close()
    }

    private func createQUICParametersWithCustomVerification(quicOptions: NWProtocolQUIC.Options) -> NWParameters {
        // 1. 获取底层的安全协议选项 (sec_protocol_options_t)
        let securityOptions: sec_protocol_options_t = quicOptions.securityProtocolOptions

        // 2. 定义自定义验证闭包 (sec_protocol_verify_t)
        // 这个闭包会在证书链验证期间被系统调用
        let customVerifyBlock: sec_protocol_verify_t = { _, _, completionHandler in
//            log("证书验证成功: 允许连接")
            completionHandler(true) // 允许连接
        }

        // 3. 将自定义验证闭包注入到安全选项中
        // 注意：验证闭包必须在一个安全的 DispatchQueue 上执行
        sec_protocol_options_set_verify_block(
            securityOptions,
            customVerifyBlock,
            DispatchQueue.global(qos: .userInitiated)
        )

        sec_protocol_options_set_tls_server_name(securityOptions, "localhost")

        // 4. 创建包含配置的 NWParameters
        let parameters = NWParameters(quic: quicOptions)

        return parameters
    }
}
