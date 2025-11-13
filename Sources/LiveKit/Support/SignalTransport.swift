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

// Reuse the same stream and message types used by WebSocket for minimal integration changes
public typealias SignalMessageStream = AsyncThrowingStream<URLSessionWebSocketTask.Message, Error>

/// Base class for signaling transports. Subclasses provide concrete implementations
/// such as WebSocket or QUIC while exposing a common AsyncSequence of messages.
class SignalTransport: NSObject, @unchecked Sendable, Loggable, AsyncSequence {
    typealias AsyncIterator = SignalMessageStream.Iterator
    typealias Element = URLSessionWebSocketTask.Message

    // Subclasses must provide a stream and implement send/close
    // internal so subclasses in the same module can assign the stream
    var _stream: SignalMessageStream!

    // MARK: - AsyncSequence

    func makeAsyncIterator() -> AsyncIterator {
        _stream.makeAsyncIterator()
    }

    // MARK: - Transport API

    func send(data _: Data) async throws {
        fatalError("send(data:) must be overridden by subclass")
    }

    func close() {
        // Optional override
    }
}

/// Factory for creating transports based on ConnectOptions.TransportKind.
enum SignalTransportFactory {
    static func create(kind: TransportKind,
                       url: URL,
                       token: String,
                       options: ConnectOptions?,
                       sendAfterOpen: Data?) async throws -> SignalTransport
    {
        switch kind {
        case .websocket:
            return try await WebSocketSignalTransport(url: url, token: token, connectOptions: options, sendAfterOpen: sendAfterOpen)
        case .quic:
            // Try QUIC if available on this OS version, otherwise gracefully fall back to WebSocket
            if #available(iOS 15.0, macOS 12.0, tvOS 15.0, *) {
                if let quic = try await QUICSignalTransport.maybeCreate(url: url, token: token, connectOptions: options, sendAfterOpen: sendAfterOpen) {
                    return quic
                }
            }
            return try await WebSocketSignalTransport(url: url, token: token, connectOptions: options, sendAfterOpen: sendAfterOpen)
        }
    }
}
