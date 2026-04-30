/*
 * Copyright 2026 LiveKit
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

#if os(iOS)
import Foundation
import TTSignal

extension TTSignalConnector: @unchecked Sendable {}
extension TTSignalConnection: @unchecked Sendable {}
extension TTSignalStream: @unchecked Sendable {}

/// Experimental QUIC signaling transport using the embedded ttsignal stack (``TTSignalConnector`` / ``TTSignalConnection``).
/// Exposes a WebSocket-shaped ``AsyncSequence`` of messages for ``SignalClient``.
actor QUICSignalTransport: SignalTransport {
    typealias Element = URLSessionWebSocketTask.Message

    private let bridge: QuicSignalBridge

    private init(bridge: QuicSignalBridge) {
        self.bridge = bridge
    }

    // MARK: - Factory

    static func maybeCreate(url: URL,
                            token: String,
                            connectOptions: ConnectOptions?,
                            sendAfterOpen: Data?) async throws -> QUICSignalTransport?
    {
        QuicSignalLog.configure()

        guard let connector = Self.sharedConnector() else {
            return nil
        }

        guard let connCfg = Self.perConnectionConfig(url: url, connectOptions: connectOptions) else {
            return nil
        }

        let bridge = QuicSignalBridge()
        guard let connection = connector.createConnection(config: connCfg, handler: bridge) else {
            return nil
        }
        bridge.setConnection(connection)

        let propsJson = Self.buildPropsJson(token: token, connectOptions: connectOptions)
        let httpsURLString = Self.httpsURLString(from: url)

        let configuredTimeout = connectOptions?.socketConnectTimeoutInterval ?? .defaultQUICSocketConnect
        let quicTimeoutSec = Swift.min(configuredTimeout, .defaultQUICSocketConnect)
        let timeoutMs = Int32(quicTimeoutSec * 1000)

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        bridge.setConnectContinuation(continuation)
                        let code = connection.connect(url: httpsURLString, propsJson: propsJson, timeoutMs: timeoutMs)
                        if code != 0 {
                            continuation.resume(throwing: LiveKitError(.network,
                                                                        message: "ttsignal connect returned \(code)"))
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(quicTimeoutSec * 1_000_000_000))
                    Self.log("QUIC connect timed out after \(quicTimeoutSec)s, will fall back", .warning)
                    throw LiveKitError(.timedOut, message: "QUIC connect timed out after \(quicTimeoutSec)s")
                }
                do {
                    try await group.next()
                    group.cancelAll()
                } catch {
                    Self.log("QUIC connect aborting, tearing down ttsignal connection", .warning)
                    bridge.closeConnection()
                    bridge.finish()
                    group.cancelAll()
                    throw error
                }
            }
        } catch {
            Self.log("QUIC connect failed: \(error), falling back to WebSocket", .warning)
            return nil
        }

        Self.log("QUIC connect succeeded")

        let transport = QUICSignalTransport(bridge: bridge)

        if let data = sendAfterOpen {
            try? await transport.send(data: data)
        }

        return transport
    }

    // MARK: - Shared connector (aligned with Android ``RTCModule`` / ``Connector``)

    private static let connectorLock = NSLock()
    private nonisolated(unsafe) static var _sharedConnector: TTSignalConnector?

    private static func sharedConnector() -> TTSignalConnector? {
        connectorLock.lock()
        defer { connectorLock.unlock() }
        if let existing = _sharedConnector {
            return existing
        }
        var base = TTSignalConfig()
        base.taskThreads = 1
        base.timerThreads = 1
        base.idleTimeOut = 20000
        base.alpn = "ttsignal"
        base.hostname = "localhost"
        base.port = 443
        base.maxConnections = 1000
        base.congestCtrl = .bbr2
        base.pingOn = true
        base.numOfSenders = 1
        base.logLevel = QuicSignalLog.ttSignalLogLevel(from: LiveKitSDK.quicLogLevel)
        guard let connector = TTSignalConnector(config: base) else {
            return nil
        }
        _sharedConnector = connector
        return connector
    }

    private static func perConnectionConfig(url: URL, connectOptions: ConnectOptions?) -> TTSignalConfig? {
        guard let host = url.host, !host.isEmpty else { return nil }
        let port = Int32(url.port ?? 443)

        var cfg = TTSignalConfig()
        cfg.idleTimeOut = 14000
        cfg.pingInterval = 7000
        cfg.hostname = host
        cfg.port = port
        cfg.maxConnections = 1
        cfg.congestCtrl = .bbr2
        cfg.pingOn = true
        cfg.alpn = "ttsignal"
        cfg.logLevel = QuicSignalLog.ttSignalLogLevel(from: LiveKitSDK.quicLogLevel)
        cfg.deviceType = Int32(connectOptions?.quicDeviceType ?? 0)
        cfg.cidTag = connectOptions?.quicCidTag ?? ""
        cfg.serverHost = Self.serverHost(url: url, connectOptions: connectOptions)
        cfg.caCertPem = connectOptions?.caCertPem ?? ""
        return cfg
    }

    static func serverHost(url: URL, connectOptions: ConnectOptions?) -> String {
        let configuredHost = connectOptions?.serverHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return configuredHost.isEmpty ? (url.host ?? "") : configuredHost
    }

    private static func httpsURLString(from url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
                .replacingOccurrences(of: "wss://", with: "https://", options: .caseInsensitive)
                .replacingOccurrences(of: "ws://", with: "http://", options: .caseInsensitive)
        }
        let scheme = components.scheme?.lowercased() ?? ""
        if scheme == "wss" {
            components.scheme = "https"
        } else if scheme == "ws" {
            components.scheme = "http"
        }
        return components.url?.absoluteString ?? url.absoluteString
    }

    private static func buildPropsJson(token: String, connectOptions: ConnectOptions?) -> String {
        var dict: [String: String] = [:]
        if !token.isEmpty {
            dict["Authorization"] = "Bearer \(token)"
        }
        if let ua = connectOptions?.userAgent, !ua.isEmpty {
            dict["User-Agent"] = ua
        }
        guard !dict.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let json = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return json
    }

    // MARK: - SignalTransport

    nonisolated func send(data: Data) async throws {
        try bridge.send(data: data)
    }

    nonisolated func close() {
        bridge.closeConnection()
        bridge.finish()
    }

    // MARK: - AsyncSequence

    struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate let bridge: QuicSignalBridge

        func next() async throws -> URLSessionWebSocketTask.Message? {
            try await withTaskCancellationHandler {
                try await bridge.nextMessage()
            } onCancel: {
                bridge.closeConnection()
                bridge.finish()
            }
        }
    }

    nonisolated func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(bridge: bridge)
    }
}

// MARK: - Bridge

/// Bridges ttsignal callbacks into continuation-driven async messaging (thread-safe).
private final class QuicSignalBridge: TTSignalHandler, Loggable, @unchecked Sendable {
    private let _state = StateSync(State())
    private struct State {
        var connection: TTSignalConnection?
        var activeStream: TTSignalStream?
        var connectContinuation: CheckedContinuation<Void, Error>?
        var connectCompleted = false
        var messageContinuation: CheckedContinuation<URLSessionWebSocketTask.Message?, Error>?
        var buffer: [URLSessionWebSocketTask.Message] = []
        var failure: LiveKitError?
        var finished = false
    }

    func setConnection(_ connection: TTSignalConnection) {
        _state.mutate { $0.connection = connection }
    }

    func setConnectContinuation(_ continuation: CheckedContinuation<Void, Error>) {
        _state.mutate { state in
            state.connectContinuation = continuation
        }
    }

    func finish() {
        _state.mutate { state in
            state.finished = true
            state.messageContinuation?.resume(returning: nil)
            state.messageContinuation = nil
            if !state.connectCompleted, let cc = state.connectContinuation {
                cc.resume(throwing: LiveKitError(.cancelled))
                state.connectContinuation = nil
            }
        }
    }

    func nextMessage() async throws -> URLSessionWebSocketTask.Message? {
        let immediate: Result<URLSessionWebSocketTask.Message?, LiveKitError>? = _state.mutate { state in
            if let error = state.failure {
                state.failure = nil
                return .failure(error)
            }
            if !state.buffer.isEmpty {
                return .success(state.buffer.removeFirst())
            }
            if state.finished { return .success(nil) }
            return nil
        }

        if let immediate {
            return try immediate.get()
        }

        return try await withCheckedThrowingContinuation { continuation in
            _state.mutate { state in
                if let error = state.failure {
                    state.failure = nil
                    continuation.resume(throwing: error)
                } else if !state.buffer.isEmpty {
                    continuation.resume(returning: state.buffer.removeFirst())
                } else if state.finished {
                    continuation.resume(returning: nil)
                } else {
                    state.messageContinuation = continuation
                }
            }
        }
    }

    func send(data: Data) throws {
        let stream: TTSignalStream? = _state.mutate { $0.activeStream }
        guard let stream else {
            throw LiveKitError(.invalidState, message: "QUIC signaling stream is not available")
        }
        if stream.sendData(data) != 0 {
            throw LiveKitError(.network, message: "ttsignal sendData failed")
        }
    }

    func closeConnection() {
        let conn: TTSignalConnection? = _state.mutate {
            let c = $0.connection
            $0.connection = nil
            $0.activeStream = nil
            return c
        }
        conn?.close()
    }

    // MARK: - TTSignalHandler

    func onConnectResult(_: TTSignalConnection, error: Int32, message: String?) {
        guard error != 0 else { return }
        let msg = message ?? "ttsignal connection failed"
        let lk = LiveKitError(.network, message: msg)
        _state.mutate { state in
            if state.connectCompleted { return }
            if let cc = state.connectContinuation {
                cc.resume(throwing: lk)
                state.connectContinuation = nil
                return
            }
            state.failure = lk
        }
    }

    func onStreamCreated(_: TTSignalConnection, stream: TTSignalStream) {
        _state.mutate { state in
            state.activeStream = stream
            state.connectCompleted = true
            state.connectContinuation?.resume()
            state.connectContinuation = nil
        }
    }

    func onStreamClosed(_: TTSignalConnection, stream: TTSignalStream) {
        _state.mutate { state in
            if state.activeStream?.id == stream.id {
                state.activeStream = nil
            }
        }
    }

    func onRecvCmd(_: TTSignalConnection,
                   timestamp _: Int64,
                   transId _: Int32,
                   stream _: TTSignalStream,
                   data _: Data) {}

    func onRecvData(_: TTSignalConnection,
                    timestamp _: Int64,
                    transId _: Int32,
                    stream _: TTSignalStream,
                    data: Data)
    {
        _state.mutate { state in
            let message = URLSessionWebSocketTask.Message.data(data)
            if let continuation = state.messageContinuation {
                state.messageContinuation = nil
                continuation.resume(returning: message)
            } else {
                state.buffer.append(message)
            }
        }
    }

    func onRestart(_: TTSignalConnection, result _: Int32, address _: String?) {}

    func onClosed(_: TTSignalConnection, reason: String?) {
        let msg = reason ?? "Connection closed"
        _state.mutate { state in
            guard !state.finished else { return }
            state.connectContinuation?.resume(throwing: LiveKitError(.network, message: msg))
            state.connectContinuation = nil
            state.connectCompleted = true
            state.activeStream = nil
            state.connection = nil
            if let mc = state.messageContinuation {
                state.messageContinuation = nil
                state.finished = true
                mc.resume(throwing: LiveKitError(.network, message: msg))
            } else {
                state.finished = true
                state.failure = LiveKitError(.network, message: msg)
            }
        }
    }

    func onException(_: TTSignalConnection, errMsg: String) {
        let lk = LiveKitError(.network, message: errMsg)
        _state.mutate { state in
            guard !state.finished else { return }
            if let cc = state.connectContinuation {
                cc.resume(throwing: lk)
                state.connectContinuation = nil
            } else if let mc = state.messageContinuation {
                state.messageContinuation = nil
                state.finished = true
                mc.resume(throwing: lk)
            } else {
                state.finished = true
                state.failure = lk
            }
        }
    }
}

#else

import Foundation

/// QUIC signaling is only available on iOS where the ttsignal binary is linked.
actor QUICSignalTransport: SignalTransport {
    typealias Element = URLSessionWebSocketTask.Message

    static func maybeCreate(url: URL,
                            token: String,
                            connectOptions: ConnectOptions?,
                            sendAfterOpen: Data?) async throws -> QUICSignalTransport?
    {
        nil
    }

    nonisolated func send(data _: Data) async throws {}

    nonisolated func close() {}

    struct AsyncIterator: AsyncIteratorProtocol {
        func next() async throws -> URLSessionWebSocketTask.Message? { nil }
    }

    nonisolated func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator()
    }
}

#endif
