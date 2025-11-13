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

/// Experimental QUIC signaling transport.
/// Wraps QUICClient and exposes a WebSocket-like AsyncSequence of messages.
@available(iOS 15.0, macOS 12.0, tvOS 15.0, *)
final class QUICSignalTransport: SignalTransport, WTMessageDelegate, @unchecked Sendable {
    private let client = QUICClient()

    private let _state = StateSync(State())
    private struct State {
        var streamContinuation: SignalMessageStream.Continuation?
        var connectContinuation: CheckedContinuation<Void, Error>?
    }

    override private init() {
        super.init()
        _stream = SignalMessageStream { continuation in
            _state.mutate { state in
                state.streamContinuation = continuation
            }
        }
    }

    // MARK: - Factory

    static func maybeCreate(url: URL,
                            token: String,
                            connectOptions: ConnectOptions?,
                            sendAfterOpen: Data?) async throws -> QUICSignalTransport?
    {
        // Ensure API is available at runtime (iOS 16+, macOS 13+ for Network QUIC)
        #if canImport(Network)
        let transport = QUICSignalTransport()
        transport.client.setDelegate(delegate: transport)

        // Prepare args for connect command
        var args: [String: Any] = [:]
        if !token.isEmpty {
            args["Authorization"] = "Bearer \(token)"
        }
        if let ua = connectOptions?.userAgent, !ua.isEmpty {
            args["User-Agent"] = ua
        }

        // Kick off connection
        let ret = transport.client.connect(url: url.absoluteString, args: args)
        guard ret == 0 else { return nil }

        // Wait for ready or failure
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        transport._state.mutate { state in
                            state.connectContinuation = continuation
                        }
                    }
                }
                // Add a timeout guard based on socketConnectTimeoutInterval
                let timeout = UInt64((connectOptions?.socketConnectTimeoutInterval ?? .defaultSocketConnect) * 1_000_000_000)
                group.addTask {
                    try await Task.sleep(nanoseconds: timeout)
                    throw LiveKitError(.timedOut)
                }
                // Return as soon as one completes
                do {
                    try await group.next()
                    group.cancelAll()
                } catch {
                    group.cancelAll()
                    throw error
                }
            }
        } catch {
            // Close on failure
            transport.close()
            return nil
        }

        // Send pending first payload if provided
        if let data = sendAfterOpen {
            try? await transport.send(data: data)
        }

        return transport
        #else
        return nil
        #endif
    }

    // MARK: - SignalTransport

    override func send(data: Data) async throws {
        let ret = client.sendData(data: data)
        if ret != 0 {
            throw LiveKitError(.network, message: "QUIC send failed with code \(ret)")
        }
    }

    override func close() {
        client.close()
        _state.mutate { state in
            state.streamContinuation?.finish()
            state.streamContinuation = nil
            state.connectContinuation = nil
        }
    }

    // MARK: - WTMessageDelegate

    func quicClient(_: QUICClient, didReceiveData data: Data) {
        guard let continuation = _state.streamContinuation else {
            return
        }

        continuation.yield(.data(data))
    }

    func quicClientDidConnect(_: QUICClient, args _: [String: Any]) {
        _state.mutate { state in
            state.connectContinuation?.resume()
            state.connectContinuation = nil
        }
    }

    func quicClientDidSend(_: QUICClient, size _: Int) {
        // no-op
    }

    func quicClient(_: QUICClient, didFailWithError error: NWError) {
        // Map NWError to LiveKitError and signal failure if connecting; else finish stream with error
        let lkError = LiveKitError(.network, message: error.localizedDescription, internalError: error)
        _state.mutate { state in
            if let cc = state.connectContinuation {
                cc.resume(throwing: lkError)
                state.connectContinuation = nil
            } else {
                state.streamContinuation?.finish(throwing: lkError)
                state.streamContinuation = nil
            }
        }
    }

    func quicClientDidDisconnect(_: QUICClient) {
        _state.mutate { state in
            state.streamContinuation?.finish()
            state.streamContinuation = nil
            state.connectContinuation = nil
        }
    }
}
