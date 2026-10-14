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
@testable import LiveKit
import Testing

@Suite struct QUICSignalBridgeTests {
    private func data(_ message: URLSessionWebSocketTask.Message?) -> Data? {
        guard case let .data(d) = message else { return nil }
        return d
    }

    @Test func bufferedMessagesAreDeliveredBeforeFailure() async throws {
        let bridge = QuicSignalBridge()
        bridge.seedForTesting(
            buffer: [.data(Data([1])), .data(Data([2]))],
            failure: LiveKitError(.network, message: "closed"),
        )

        #expect(try data(await bridge.nextMessage()) == Data([1]))
        #expect(try data(await bridge.nextMessage()) == Data([2]))

        await #expect(throws: LiveKitError.self) {
            _ = try await bridge.nextMessage()
        }

        // Failure is consumed once; the finished bridge then ends the sequence.
        #expect(try await bridge.nextMessage() == nil)
    }

    @Test func failureIsSurfacedWhenBufferIsEmpty() async throws {
        let bridge = QuicSignalBridge()
        bridge.seedForTesting(buffer: [], failure: LiveKitError(.network, message: "closed"))

        await #expect(throws: LiveKitError.self) {
            _ = try await bridge.nextMessage()
        }
    }

    @Test func clientCloseEndsSequenceAfterBufferedMessages() async throws {
        let bridge = QuicSignalBridge()
        bridge.seedForTesting(buffer: [.data(Data([1]))], failure: nil)
        bridge.closeConnection()
        bridge.finish()

        #expect(try data(await bridge.nextMessage()) == Data([1]))
        #expect(try await bridge.nextMessage() == nil)
    }
}
#endif
