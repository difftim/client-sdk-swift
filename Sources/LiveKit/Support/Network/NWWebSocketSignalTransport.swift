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

/// WebSocket signaling transport backed by Network.framework (NWConnection).
///
/// Used when custom CA certificates are provided, giving full TLS verification
/// control via `sec_protocol_options_set_verify_block`. Falls back to the
/// URLSession-based `WebSocketSignalTransport` when no custom certs are needed.
@available(iOS 13.0, macOS 10.15, tvOS 13.0, *)
final class NWWebSocketSignalTransport: SignalTransport, @unchecked Sendable {
    private let socket: NWWebSocket

    init(url: URL, token: String, connectOptions: ConnectOptions?, sendAfterOpen: Data?) async throws {
        socket = try await NWWebSocket(url: url, token: token, connectOptions: connectOptions, sendAfterOpen: sendAfterOpen)
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
