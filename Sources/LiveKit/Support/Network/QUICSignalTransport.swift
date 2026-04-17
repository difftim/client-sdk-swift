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

import Foundation
import Network

/// Experimental QUIC signaling transport.
/// Wraps QUICClient and exposes a WebSocket-like AsyncSequence of messages.
@available(iOS 15.0, macOS 12.0, tvOS 15.0, *)
actor QUICSignalTransport: SignalTransport {
    typealias Element = URLSessionWebSocketTask.Message

    private let client: QUICClient
    private let delegate: Delegate

    private init() {
        let delegate = Delegate()
        self.delegate = delegate
        client = QUICClient()
        client.setDelegate(delegate: delegate)
    }

    // MARK: - Factory

    static func maybeCreate(url: URL,
                            token: String,
                            connectOptions: ConnectOptions?,
                            sendAfterOpen: Data?) async throws -> QUICSignalTransport?
    {
        #if canImport(Network)
        let transport = QUICSignalTransport()

        var args: [String: Any] = [:]
        if !token.isEmpty {
            args["Authorization"] = "Bearer \(token)"
        }
        if let ua = connectOptions?.userAgent, !ua.isEmpty {
            args["User-Agent"] = ua
        }

        let ret = transport.client.connect(url: url.absoluteString, args: args)
        guard ret == 0 else { return nil }

        // QUIC uses its own (shorter) connect timeout so we can fall back to
        // WebSocket quickly when UDP/QUIC is blocked. We also must ensure the
        // underlying NWConnection is torn down when the timeout or the parent
        // task cancels us, otherwise `withCheckedThrowingContinuation` below
        // never resumes and we end up waiting for NWConnection's own idle
        // timeout (~30s+).
        let configuredTimeout = connectOptions?.socketConnectTimeoutInterval ?? .defaultQUICSocketConnect
        let quicTimeout = Swift.min(configuredTimeout, .defaultQUICSocketConnect)
        transport.log("QUIC connect starting, timeout: \(quicTimeout)s")

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withTaskCancellationHandler {
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                            transport.delegate.setConnectContinuation(continuation)
                        }
                    } onCancel: {
                        transport.log("QUIC connect task cancelled, tearing down NWConnection")
                        transport.close()
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(quicTimeout * 1_000_000_000))
                    transport.log("QUIC connect timed out after \(quicTimeout)s, will fall back", .warning)
                    throw LiveKitError(.timedOut, message: "QUIC connect timed out after \(quicTimeout)s")
                }
                do {
                    try await group.next()
                    group.cancelAll()
                } catch {
                    group.cancelAll()
                    throw error
                }
            }
        } catch {
            transport.log("QUIC connect failed: \(error), falling back to WebSocket", .warning)
            transport.close()
            return nil
        }

        transport.log("QUIC connect succeeded")

        if let data = sendAfterOpen {
            try? await transport.send(data: data)
        }

        return transport
        #else
        return nil
        #endif
    }

    // MARK: - SignalTransport

    nonisolated func send(data: Data) async throws {
        try await client.send(data: data)
    }

    nonisolated func close() {
        client.close()
        delegate.finish()
    }

    // MARK: - AsyncSequence

    struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate let client: QUICClient
        fileprivate let delegate: Delegate

        func next() async throws -> URLSessionWebSocketTask.Message? {
            try await withTaskCancellationHandler {
                try await delegate.nextMessage()
            } onCancel: {
                client.close()
                delegate.finish()
            }
        }
    }

    nonisolated func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(client: client, delegate: delegate)
    }

    // MARK: - Delegate

    /// Bridges QUICClient's callback-based delegate into a continuation-driven
    /// async iterator, keeping all mutable state behind `StateSync`.
    fileprivate final class Delegate: WTMessageDelegate, Sendable {
        private let _state = StateSync(State())
        private struct State {
            var connectContinuation: CheckedContinuation<Void, Error>?
            var messageContinuation: CheckedContinuation<URLSessionWebSocketTask.Message?, Error>?
            var buffer: [URLSessionWebSocketTask.Message] = []
            var failure: LiveKitError?
            var finished = false
        }

        func setConnectContinuation(_ continuation: CheckedContinuation<Void, Error>) {
            _state.mutate { $0.connectContinuation = continuation }
        }

        func finish() {
            _state.mutate { state in
                state.finished = true
                state.messageContinuation?.resume(returning: nil)
                state.messageContinuation = nil
                state.connectContinuation?.resume(throwing: LiveKitError(.cancelled))
                state.connectContinuation = nil
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

        // MARK: - WTMessageDelegate

        func quicClient(_: QUICClient, didReceiveData data: Data) {
            _state.mutate { state in
                if let continuation = state.messageContinuation {
                    state.messageContinuation = nil
                    continuation.resume(returning: .data(data))
                } else {
                    state.buffer.append(.data(data))
                }
            }
        }

        func quicClientDidConnect(_: QUICClient, args _: [String: Any]) {
            _state.mutate { state in
                state.connectContinuation?.resume()
                state.connectContinuation = nil
            }
        }

        func quicClientDidSend(_: QUICClient, size _: Int) {}

        func quicClient(_: QUICClient, didFailWithError error: NWError) {
            let lkError = LiveKitError(.network, message: error.localizedDescription, internalError: error)
            _state.mutate { state in
                if let cc = state.connectContinuation {
                    cc.resume(throwing: lkError)
                    state.connectContinuation = nil
                } else if let mc = state.messageContinuation {
                    state.messageContinuation = nil
                    state.finished = true
                    mc.resume(throwing: lkError)
                } else {
                    state.finished = true
                    state.failure = lkError
                }
            }
        }

        func quicClientDidDisconnect(_: QUICClient) {
            finish()
        }
    }
}
