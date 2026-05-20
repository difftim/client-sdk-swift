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

public extension DispatchQueue {
    // The queue which SDK uses to invoke WebRTC methods
    static let liveKitWebRTC = DispatchQueue(label: "LiveKitSDK.webRTC", qos: .default)

    // Serializes synchronous BlockingCalls into LKRTCVideoTrack.addRenderer:/removeRenderer:.
    //
    // Kept separate from `liveKitWebRTC` because addRenderer/removeRenderer issue a
    // BlockingCall to the WebRTC worker thread (potentially long, and during reconnect can
    // stall while `ChannelSend::~ChannelSend()` waits on its encoder task queue). The
    // existing `liveKitWebRTC` queue is used for microsecond-scale ObjC object construction
    // (peer connection / transceiver / configuration / ice server / media constraints) that
    // is heavily exercised on the reconnect rebuild path; sharing one serial queue would let
    // a stalled renderer call head-of-line block those construction callsites and reintroduce
    // cooperative-pool starvation through the back door.
    static let liveKitWebRTCVideoRenderer = DispatchQueue(label: "LiveKitSDK.webRTC.videoRenderer", qos: .default)
}
