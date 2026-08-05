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

/// Health of the local media **send** (uplink) path.
///
/// Distinct from ``ConnectionState`` when the server uses `subscriberPrimary`:
/// the room may report ``ConnectionState/connected`` once the subscriber
/// transport is up, while local audio/video is still negotiating or failed on
/// the publisher transport.
///
/// ## Example
/// ```swift
/// func room(_ room: Room, didUpdateMediaSendConnectionState state: MediaSendConnectionState, from _: MediaSendConnectionState) {
///     let shouldWarn = room.connectionState == .connected
///         && state != .idle
///         && state != .connected
///     // show "Media send issue" when shouldWarn
/// }
/// ```
@objc
public enum MediaSendConnectionState: Int, Sendable {
    /// No local media is currently being sent.
    case idle

    /// Local media is being published and the publisher transport is negotiating.
    case connecting

    /// The publisher transport is connected; local media can be sent.
    case connected

    /// The publisher transport is temporarily unhealthy and the SDK is recovering.
    case recovering

    /// The publisher transport failed and local media cannot be sent.
    case failed
}

extension MediaSendConnectionState: Identifiable {
    public var id: Int {
        rawValue
    }
}

extension MediaSendConnectionState {
    /// `true` when the uplink is degraded while the room may still receive remote media.
    public var isAbnormal: Bool {
        switch self {
        case .recovering, .failed:
            true
        default:
            false
        }
    }

    /// `true` when the uplink is not yet ready or is unhealthy.
    public var isDegraded: Bool {
        switch self {
        case .connecting, .recovering, .failed:
            true
        default:
            false
        }
    }
}
