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

/// TT signaling messages cross the public API as serialized bytes so the
/// xcframework does not expose SwiftProtobuf types.
struct TTCallBytesTests {
    @Test func ttCallRequestDataRoundTrips() throws {
        let request = Livekit_TTCallRequest.with {
            $0.token = "t"
            $0.startCall.clientCallID = "c"
        }
        let options = try ConnectOptions(ttCallRequestData: request.serializedData())

        #expect(options.ttCallRequest?.token == "t")
        #expect(options.ttCallRequest?.startCall.clientCallID == "c")
    }

    @Test func invalidTTCallRequestDataDecodesToNil() {
        let options = ConnectOptions(ttCallRequestData: Data([0xFF, 0xFF]))

        #expect(options.ttCallRequestData == Data([0xFF, 0xFF]))
        #expect(options.ttCallRequest == nil)
    }

    @Test func liveKitErrorExposesResponseBytes() throws {
        let response = Livekit_TTCallResponse.with { $0.base.status = 22001 }
        let error = LiveKitError(.startCall, message: "m", response: response)

        let data = try #require(error.responseData)
        #expect(try Livekit_TTCallResponse(serializedBytes: data).base.status == 22001)
        #expect(LiveKitError(.startCall).responseData == nil)
    }

    @Test func roomExposesTTCallResponseBytes() throws {
        let room = Room()
        #expect(room.ttCallRespData == nil)

        room.ttCallResp = Livekit_TTCallResponse.with { $0.body.token = "x" }

        let data = try #require(room.ttCallRespData)
        #expect(try Livekit_TTCallResponse(serializedBytes: data).body.token == "x")
    }
}
