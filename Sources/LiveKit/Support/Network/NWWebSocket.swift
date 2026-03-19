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

/// WebSocket implementation backed by NWConnection + NWProtocolWebSocket.
///
/// Used instead of URLSession-based WebSocket when custom CA certificates are
/// provided, giving full control over TLS verification via
/// `sec_protocol_options_set_verify_block`.
@available(iOS 13.0, macOS 10.15, tvOS 13.0, *)
final class NWWebSocket: @unchecked Sendable, Loggable {
    typealias MessageStream = AsyncThrowingStream<URLSessionWebSocketTask.Message, Error>

    private let _state = StateSync(State())

    private struct State {
        var streamContinuation: MessageStream.Continuation?
        var connectContinuation: CheckedContinuation<Void, Error>?
    }

    private var connection: NWConnection?
    private let connectionQueue = DispatchQueue(label: "lk.nwwebsocket", qos: .userInitiated)

    let stream: MessageStream

    init(url: URL,
         token: String,
         connectOptions: ConnectOptions?,
         sendAfterOpen: Data?) async throws
    {
        let host = url.host ?? "localhost"
        let useTLS = url.scheme == "wss"
        let customCACertificates = connectOptions?.customCACertificates ?? []
        let insecureSkipTLSVerify = connectOptions?.insecureSkipTLSVerify ?? false

        // Build NWProtocolWebSocket options
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true

        var headers: [(String, String)] = []
        if !token.isEmpty {
            headers.append(("Authorization", "Bearer \(token)"))
        }
        if let ua = connectOptions?.userAgent, !ua.isEmpty {
            headers.append(("User-Agent", ua))
        }
        wsOptions.setAdditionalHeaders(headers)

        // Build NWParameters with TLS
        let parameters: NWParameters
        if useTLS {
            parameters = NWParameters(tls: NWWebSocket.createTLSOptions(
                host: host,
                customCACertificates: customCACertificates,
                insecureSkipTLSVerify: insecureSkipTLSVerify
            ))
        } else {
            parameters = NWParameters.tcp
        }

        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let nwConnection = NWConnection(to: .url(url), using: parameters)
        connection = nwConnection

        // Setup stream
        stream = MessageStream { [_state] continuation in
            _state.mutate { $0.streamContinuation = continuation }
        }

        // Setup state handler
        nwConnection.stateUpdateHandler = { [weak self] newState in
            self?.handleStateChange(newState)
        }

        // Start connection
        nwConnection.start(queue: connectionQueue)

        // Wait for connection to be ready
        let timeout = connectOptions?.socketConnectTimeoutInterval ?? .defaultSocketConnect
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        self._state.mutate { $0.connectContinuation = continuation }
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw LiveKitError(.timedOut)
                }
                do {
                    try await group.next()
                    group.cancelAll()
                } catch {
                    group.cancelAll()
                    throw error
                }
            }
        } onCancel: { [weak self] in
            self?.close()
        }

        // Send pending payload after open
        if let data = sendAfterOpen {
            try await send(data: data)
        }
    }

    deinit {
        close()
    }

    // MARK: - Send

    func send(data: Data) async throws {
        guard let connection else {
            throw LiveKitError(.invalidState, message: "NWWebSocket connection is nil")
        }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(
            identifier: "ws-send",
            metadata: [metadata]
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    // MARK: - Close

    func close() {
        connection?.cancel()
        connection = nil

        _state.mutate { state in
            state.connectContinuation?.resume(throwing: LiveKitError(.cancelled))
            state.connectContinuation = nil
            state.streamContinuation?.finish(throwing: LiveKitError(.cancelled))
            state.streamContinuation = nil
        }
    }

    // MARK: - Private

    private func handleStateChange(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            log("NWWebSocket connection ready")
            _state.mutate { state in
                state.connectContinuation?.resume()
                state.connectContinuation = nil
            }
            receiveNextMessage()

        case let .waiting(error):
            log("NWWebSocket waiting: \(error.localizedDescription)", .warning)
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

        case let .failed(error):
            log("NWWebSocket failed: \(error.localizedDescription)", .error)
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

        case .cancelled:
            log("NWWebSocket cancelled")
            _state.mutate { state in
                state.streamContinuation?.finish()
                state.streamContinuation = nil
                state.connectContinuation = nil
            }

        default:
            break
        }
    }

    private func receiveNextMessage() {
        guard let connection else { return }

        connection.receiveMessage { [weak self] content, context, isComplete, error in
            guard let self else { return }

            if let error {
                log("NWWebSocket receive error: \(error.localizedDescription)", .error)
                _state.mutate { state in
                    state.streamContinuation?.finish(throwing: LiveKitError(.network, internalError: error))
                    state.streamContinuation = nil
                }
                return
            }

            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            {
                switch metadata.opcode {
                case .close:
                    log("NWWebSocket received close frame")
                    _state.mutate { state in
                        state.streamContinuation?.finish()
                        state.streamContinuation = nil
                    }
                    return
                case .binary:
                    if let data = content {
                        _state.streamContinuation?.yield(.data(data))
                    }
                case .text:
                    if let data = content, let text = String(data: data, encoding: .utf8) {
                        _state.streamContinuation?.yield(.string(text))
                    }
                case .pong, .ping:
                    break
                case .cont:
                    break
                @unknown default:
                    break
                }
            } else if let data = content {
                _state.streamContinuation?.yield(.data(data))
            }

            self.receiveNextMessage()
        }
    }

    // MARK: - TLS Configuration

    private static func createTLSOptions(
        host: String,
        customCACertificates: [Data],
        insecureSkipTLSVerify: Bool = false
    ) -> NWProtocolTLS.Options {
        let tlsOptions = NWProtocolTLS.Options()
        let securityOptions = tlsOptions.securityProtocolOptions

        let verifyBlock: sec_protocol_verify_t = { _, trust, completionHandler in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()

            TLSHelper.evaluate(
                trust: secTrust,
                customCACertificates: customCACertificates,
                insecureSkipTLSVerify: insecureSkipTLSVerify
            ) { result, _ in
                completionHandler(result)
            }
        }

        sec_protocol_options_set_verify_block(
            securityOptions,
            verifyBlock,
            .global(qos: .userInitiated)
        )
        sec_protocol_options_set_tls_server_name(securityOptions, host)

        return tlsOptions
    }

}
