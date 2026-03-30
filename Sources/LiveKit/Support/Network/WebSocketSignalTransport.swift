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

actor WebSocketSignalTransport: SignalTransport {
    private let socket: WebSocket

    init(url: URL, token: String, connectOptions: ConnectOptions?, sendAfterOpen: Data?) async throws {
        socket = try await WebSocket(url: url, token: token, connectOptions: connectOptions, sendAfterOpen: sendAfterOpen)
    }

    nonisolated func makeAsyncIterator() -> WebSocket.AsyncIterator {
        socket.makeAsyncIterator()
    }

    nonisolated func send(data: Data) async throws {
        try await socket.send(data: data)
    }

    nonisolated func close() {
        socket.close()
    }
}
