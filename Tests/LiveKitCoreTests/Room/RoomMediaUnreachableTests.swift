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

@testable import LiveKit
import Testing

struct RoomMediaUnreachableTests {
    @Test func mediaUnreachableHasStableRawValue() {
        #expect(LiveKitErrorType.mediaUnreachable.rawValue == 2002)
    }

    @Test func transportTimeoutBecomesMediaUnreachable() {
        let error = Room.mediaUnreachableError(from: LiveKitError(.timedOut), transport: "publisher", elapsed: 15)
        let lkError = error as? LiveKitError
        #expect(lkError?.type == .mediaUnreachable)
        #expect(lkError?.message == "publisher transport not connected after 15000ms")
    }

    @Test func transportFailedBecomesMediaUnreachable() {
        let failed = LiveKitError(.network, message: "Transport subscriber state changed to failed")
        let error = Room.mediaUnreachableError(from: failed, transport: "primary", elapsed: 1.2)
        #expect((error as? LiveKitError)?.type == .mediaUnreachable)
    }

    @Test func cancellationIsPreserved() {
        let lk = Room.mediaUnreachableError(from: LiveKitError(.cancelled), transport: "primary", elapsed: 0)
        #expect((lk as? LiveKitError)?.type == .cancelled)
        let task = Room.mediaUnreachableError(from: CancellationError(), transport: "primary", elapsed: 0)
        #expect(task is CancellationError)
    }

    @Test func transportConnectTimeoutsDefaultTo15Seconds() {
        #expect(ConnectOptions().primaryTransportConnectTimeout == 15)
        #expect(ConnectOptions().publisherTransportConnectTimeout == 15)
    }

    @Test func connectResetsQuicUnhealthyMarker() async {
        let room = Room()
        await room.signalClient.markQuicUnhealthyIfFallback(requestedKind: .quic, actualKind: .websocket)
        #expect(await room.signalClient.isQuicMarkedUnhealthy)

        try? await room.connect(url: "not a url", token: "")

        #expect(await room.signalClient.isQuicMarkedUnhealthy == false)
    }
}
