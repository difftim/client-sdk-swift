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

actor WebSocket: Loggable, AsyncSequence {
    typealias Element = URLSessionWebSocketTask.Message

    private let delegate: Delegate
    private let urlSession: URLSession
    private let task: URLSessionWebSocketTask

    private static func makeSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 604_800
        config.shouldUseExtendedBackgroundIdleMode = true
        config.networkServiceType = .callSignaling
        #if os(iOS) || os(visionOS)
        // MPTCP handover would help on Wi-Fi <-> cellular transitions, but the LiveKit
        // signaling server we deploy against does not currently support Multipath TCP,
        // so enabling it causes the WebSocket handshake to fail. Re-enable once the
        // server-side support lands.
        // https://developer.apple.com/documentation/foundation/urlsessionconfiguration/improving_network_reliability_using_multipath_tcp
        // config.multipathServiceType = .handover
        #endif
        return config
    }

    init(url: URL, token: String, connectOptions: ConnectOptions?, sendAfterOpen: Data?) async throws {
        var request = URLRequest(url: url,
                                 cachePolicy: .useProtocolCachePolicy,
                                 timeoutInterval: connectOptions?.socketConnectTimeoutInterval ?? .defaultSocketConnect)
        if !token.isEmpty {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let userAgent = connectOptions?.userAgent, !userAgent.isEmpty {
            request.addValue(userAgent, forHTTPHeaderField: "User-Agent")
        }

        #if targetEnvironment(simulator)
        if #available(iOS 26.0, *) {
            nw_tls_create_options()
        }
        #endif

        delegate = try Delegate(caCertPem: connectOptions?.caCertPem)
        delegate.setSendAfterOpen(sendAfterOpen)
        urlSession = URLSession(configuration: Self.makeSessionConfiguration(),
                                delegate: delegate, delegateQueue: nil)
        task = urlSession.webSocketTask(with: request)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.setConnectContinuation(continuation)
                task.resume()
            }
        } onCancel: {
            self.close()
        }
    }

    deinit {
        close()
    }

    nonisolated func close() {
        task.cancel(with: .normalClosure, reason: nil)
        urlSession.finishTasksAndInvalidate()
        delegate.cancelConnection()
    }

    // MARK: - AsyncSequence

    struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate let task: URLSessionWebSocketTask
        fileprivate let delegate: Delegate

        func next() async throws -> URLSessionWebSocketTask.Message? {
            guard task.closeCode == .invalid else { return nil }
            let receiveContinuation = ReceiveContinuation()

            return try await withTaskCancellationHandler {
                do {
                    // Use the callback API instead of the async overlay to avoid
                    // a TSan-visible data race inside Foundation's continuation bridge.
                    return try await withCheckedThrowingContinuation { continuation in
                        receiveContinuation.set(continuation)
                        delegate.setReceiveContinuation(receiveContinuation)
                        task.receive { result in
                            delegate.clearReceiveContinuation(receiveContinuation)
                            receiveContinuation.resume(with: result)
                        }
                    }
                } catch {
                    // On clean shutdown, task.receive() throws URLError(.cancelled)
                    // rather than CancellationError. Return nil (end-of-sequence)
                    // instead of propagating, so `subscribe` doesn't call onFailure.
                    if task.closeCode != .invalid || Task.isCancelled { return nil }
                    throw LiveKitError.from(error: error) ?? error
                }
            } onCancel: {
                delegate.cancelReceiveContinuation(receiveContinuation)
                task.cancel(with: .normalClosure, reason: nil)
            }
        }
    }

    nonisolated func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(task: task, delegate: delegate)
    }

    // MARK: - Send

    nonisolated func send(data: Data) async throws {
        try await task.send(.data(data))
    }

    // MARK: - Delegate

    fileprivate final class ReceiveContinuation: Sendable {
        private struct State {
            var continuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
            var isCancelled = false
        }

        private let _state = StateSync(State())

        func set(_ continuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>) {
            let shouldCancel = _state.mutate { state -> Bool in
                guard !state.isCancelled else { return true }
                state.continuation = continuation
                return false
            }

            if shouldCancel {
                continuation.resume(throwing: CancellationError())
            }
        }

        func resume(with result: Result<URLSessionWebSocketTask.Message, Error>) {
            _state.mutate {
                let continuation = $0.continuation
                $0.continuation = nil
                return continuation
            }?.resume(with: result)
        }

        func cancel() {
            resume(throwing: CancellationError())
        }

        func resume(throwing error: Error) {
            _state.mutate {
                $0.isCancelled = true
                let continuation = $0.continuation
                $0.continuation = nil
                return continuation
            }?.resume(throwing: error)
        }
    }

    fileprivate final class Delegate: NSObject, Loggable, URLSessionWebSocketDelegate, URLSessionTaskDelegate {
        private let _continuation = StateSync<CheckedContinuation<Void, Error>?>(nil)
        private let _receiveContinuation = StateSync<ReceiveContinuation?>(nil)
        private let _sendAfterOpen = StateSync<Data?>(nil)
        private let _pendingCompletionError = StateSync<Error?>(nil)
        /// Custom CA anchors for WebSocket TLS when `ConnectOptions.caCertPem` is set; empty means default system trust.
        private let anchorCertificates: [SecCertificate]

        init(caCertPem: String?) throws {
            guard let pem = caCertPem?.trimmingCharacters(in: .whitespacesAndNewlines), !pem.isEmpty else {
                anchorCertificates = []
                super.init()
                return
            }

            guard let certs = CertificateTrustEvaluator.certificates(fromPEM: pem), !certs.isEmpty else {
                anchorCertificates = []
                super.init()
                log("Failed to parse caCertPem for WebSocket.", .warning)
                throw LiveKitError(.validation, message: "Invalid caCertPem")
            }

            anchorCertificates = certs
            super.init()
            log("WebSocket TLS: loaded \(certs.count) custom CA anchor(s) from caCertPem; server trust will use anchor-only evaluation", .debug)
        }

        func setConnectContinuation(_ continuation: CheckedContinuation<Void, Error>) {
            _continuation.mutate { $0 = continuation }
        }

        func setSendAfterOpen(_ data: Data?) {
            _sendAfterOpen.mutate { $0 = data }
        }

        func setReceiveContinuation(_ continuation: ReceiveContinuation) {
            _receiveContinuation.mutate { $0 = continuation }
        }

        func clearReceiveContinuation(_ continuation: ReceiveContinuation) {
            _receiveContinuation.mutate {
                guard $0 === continuation else { return }
                $0 = nil
            }
        }

        func cancelReceiveContinuation(_ continuation: ReceiveContinuation) {
            clearReceiveContinuation(continuation)
            continuation.cancel()
        }

        func cancelConnection() {
            _continuation.mutate {
                $0?.resume(throwing: LiveKitError(.cancelled))
                $0 = nil
            }
        }

        func urlSession(_: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol _: String?) {
            if let data = _sendAfterOpen.mutate({ let v = $0; $0 = nil; return v }) {
                webSocketTask.send(.data(data)) { _ in }
            }

            _continuation.mutate {
                $0?.resume()
                $0 = nil
            }
        }

        func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
            log("didCompleteWithError: \(String(describing: error))", error != nil ? .error : .debug)

            let lkError = _pendingCompletionError.mutate {
                let pending = $0
                $0 = nil
                return pending
            }.flatMap { LiveKitError.from(error: $0) } ?? LiveKitError.from(error: error) ?? LiveKitError(.unknown)
            _continuation.mutate {
                if error != nil {
                    $0?.resume(throwing: lkError)
                } else {
                    $0?.resume()
                }
                $0 = nil
            }

            guard error != nil else { return }

            _receiveContinuation.mutate {
                let continuation = $0
                $0 = nil
                return continuation
            }?.resume(throwing: lkError)
        }

        func urlSession(_: URLSession,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
        {
            handleAuthenticationChallenge(challenge, completionHandler: completionHandler)
        }

        func urlSession(_: URLSession,
                        task _: URLSessionTask,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
        {
            handleAuthenticationChallenge(challenge, completionHandler: completionHandler)
        }

        private func handleAuthenticationChallenge(_ challenge: URLAuthenticationChallenge,
                                                   completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
        {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let serverTrust = challenge.protectionSpace.serverTrust
            else {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            guard !anchorCertificates.isEmpty else {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            let host = challenge.protectionSpace.host
            log("WebSocket TLS: serverTrust challenge for host \(host), evaluating with custom anchors only", .debug)
            if CertificateTrustEvaluator.evaluateServerTrust(serverTrust, host: host, anchorCertificates: anchorCertificates) {
                log("WebSocket TLS: custom anchor trust evaluation succeeded for host \(host)", .debug)
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                log("WebSocket TLS trust evaluation failed for host \(host)", .warning)
                _pendingCompletionError.mutate {
                    $0 = LiveKitError(.validation, message: "WebSocket TLS trust evaluation failed for host \(host)")
                }
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }
}
