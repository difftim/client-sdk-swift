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
@testable import LiveKit
import Testing

/// A participant that reconnects is handed a fresh sid by the server. Connection quality is
/// measured per session, so the reading carried over from the previous sid has to be dropped:
/// the server only reports quality for participants we hold a track subscription to, so a peer
/// that reconnects without publishing would otherwise keep its stale value indefinitely.
struct ParticipantSessionQualityTests {
    private static let identity = "remote-user"

    private static func info(sid: String) -> Livekit_ParticipantInfo {
        Livekit_ParticipantInfo.with {
            $0.identity = identity
            $0.sid = sid
            $0.state = .active
        }
    }

    private static func makeParticipant(sid: String) -> RemoteParticipant {
        RemoteParticipant(info: info(sid: sid), room: Room(), connectionState: .connected)
    }

    @Test("A new sid drops the quality carried over from the previous session")
    func newSidDropsPreviousQuality() {
        let participant = Self.makeParticipant(sid: "PA_first")
        participant._state.mutate { $0.connectionQuality = .lost }
        #expect(participant.connectionQuality == .lost)

        _ = participant.set(info: Self.info(sid: "PA_second"), connectionState: .connected)

        #expect(participant.connectionQuality == .unknown)
    }

    @Test("Refreshing info under the same sid leaves the current quality alone")
    func sameSidKeepsQuality() {
        let participant = Self.makeParticipant(sid: "PA_first")
        participant._state.mutate { $0.connectionQuality = .poor }

        _ = participant.set(info: Self.info(sid: "PA_first"), connectionState: .connected)

        #expect(participant.connectionQuality == .poor)
    }

    @Test("Creating a participant does not clobber the quality it starts out with")
    func creationLeavesQualityUnknown() {
        let participant = Self.makeParticipant(sid: "PA_first")

        #expect(participant.connectionQuality == .unknown)
        #expect(participant.sid == Participant.Sid(from: "PA_first"))
    }
}
