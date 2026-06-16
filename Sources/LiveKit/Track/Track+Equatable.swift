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

// MARK: - Equatable for NSObject

// ⚠️ Equality/hash are by `mediaTrack.trackId`, NOT object identity. On a FULL RECONNECT the SFU
// reuses the same `trackId`, so a brand-new `Track` object (with a fresh, live `RtpReceiver`) is
// considered `==` / `isEqual` to the previous, now-dead one. Any code that decides "did the track
// change?" near reconnect MUST compare object identity (`===` / `!==`), not `==`, otherwise it will
// keep the stale track — e.g. a publication that never swaps in the live track (garbled audio), or
// a renderer that never rebinds (frozen video). See `TrackPublication.set(track:)`,
// `RemoteTrackPublication.set(track:)` and `VideoView` which all intentionally use `!==`.
// Likewise, avoid using `Track` as a `Set` element or dictionary key across reconnect; key by
// `Track.Sid` instead. (This trackId-based equality is upstream behaviour, exposed once the remote
// roster/publications are preserved across full reconnect via `preserveRemoteParticipants`.)

public extension Track {
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return mediaTrack.trackId == other.mediaTrack.trackId
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(mediaTrack.trackId)
        return hasher.finalize()
    }
}
