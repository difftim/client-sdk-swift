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

/// Protocol for signaling transports. Concrete implementations (WebSocket, QUIC)
/// provide an `AsyncSequence` of messages along with send/close capabilities.
protocol SignalTransport: AsyncSequence, Sendable, Loggable
    where Element == URLSessionWebSocketTask.Message
{
    func send(data: Data) async throws
    func close()
}

/// Factory for creating transports based on ``TransportKind``.
enum SignalTransportFactory: Loggable {
    static func create(kind: TransportKind,
                       url: URL,
                       token: String,
                       options: ConnectOptions?,
                       sendAfterOpen: Data?) async throws -> any SignalTransport
    {
        if kind == .quic {
            log("use QUIC transport")
            if let transport = try await QUICSignalTransport.maybeCreate(
                url: url, token: token, connectOptions: options, sendAfterOpen: sendAfterOpen
            ) {
                return transport
            }
            log("fall back to WebSocket transport")
        }

        log("use WebSocket transport")
        let webSocketURL = rewriteURLIfQuicFallbackNeeded(originalURL: url, options: options)
        return try await WebSocketSignalTransport(
            url: webSocketURL, token: token, connectOptions: options, sendAfterOpen: sendAfterOpen
        )
    }

    /// When QUIC used custom CA + IP-direct URL, WebSocket TLS needs a hostname that matches the certificate.
    /// Aligns with Android ``QuicWithFallbackTransport.rewriteIpUrlForWebSocket``.
    private static func rewriteURLIfQuicFallbackNeeded(originalURL: URL, options: ConnectOptions?) -> URL {
        guard let pem = options?.caCertPem, !pem.isEmpty,
              let serverHost = options?.serverHost?.trimmingCharacters(in: .whitespacesAndNewlines), !serverHost.isEmpty,
              let host = originalURL.host,
              isIpLiteral(host),
              host.caseInsensitiveCompare(serverHost) != .orderedSame
        else {
            return originalURL
        }
        guard var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false) else {
            return originalURL
        }
        components.host = serverHost
        return components.url ?? originalURL
    }

    private static func isIpLiteral(_ host: String) -> Bool {
        if host.hasPrefix("[") && host.hasSuffix("]") { return true }
        if host.contains(":") { return true }
        let ipv4 = #"^(\d{1,3})(\.\d{1,3}){3}$"#
        return host.range(of: ipv4, options: .regularExpression) != nil
    }
}
