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
            if #available(iOS 15.0, macOS 12.0, tvOS 15.0, *) {
                log("use QUIC transport")
                if let transport = try await QUICSignalTransport.maybeCreate(
                    url: url, token: token, connectOptions: options, sendAfterOpen: sendAfterOpen
                ) {
                    return transport
                }
            } else {
                log("fall back to WebSocket transport: QUIC not available on this OS version")
            }
        }

        log("use WebSocket transport")
        return try await WebSocketSignalTransport(
            url: url, token: token, connectOptions: options, sendAfterOpen: sendAfterOpen
        )
    }
}
