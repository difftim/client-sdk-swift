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

@objcMembers
public final class VideoPublishOptions: NSObject, TrackPublishOptions, Sendable {
    public let name: String?

    /// preferred encoding parameters
    public let encoding: VideoEncoding?

    /// encoding parameters for for screen share
    public let screenShareEncoding: VideoEncoding?

    /// true to enable simulcasting, publishes three tracks at different sizes
    public let simulcast: Bool

    public let simulcastLayers: [VideoParameters]

    public let screenShareSimulcastLayers: [VideoParameters]

    public let preferredCodec: VideoCodec?

    public let preferredBackupCodec: VideoCodec?

    /// Scalability mode for SVC codecs (VP9, AV1). Defaults to ``ScalabilityMode/L3T3_KEY``.
    ///
    /// For SVC codecs, simulcast is disabled and a single encoding with the specified
    /// scalability mode is used instead. Screen share tracks always use ``ScalabilityMode/L1T3``
    /// regardless of this setting.
    ///
    /// ```swift
    /// let options = VideoPublishOptions(
    ///     preferredCodec: .vp9,
    ///     scalabilityMode: .L3T3_KEY
    /// )
    /// try await localParticipant.publish(videoTrack: track, options: options)
    /// ```
    ///
    /// - Note: Only applies when using an SVC codec (VP9 or AV1). Ignored for non-SVC codecs.
    public let scalabilityMode: ScalabilityMode

    public let degradationPreference: DegradationPreference

    public let streamName: String?

    public init(name: String? = nil,
                encoding: VideoEncoding? = nil,
                screenShareEncoding: VideoEncoding? = nil,
                simulcast: Bool = true,
                simulcastLayers: [VideoParameters] = [],
                screenShareSimulcastLayers: [VideoParameters] = [],
                preferredCodec: VideoCodec? = nil,
                preferredBackupCodec: VideoCodec? = nil,
                scalabilityMode: ScalabilityMode = .L3T3_KEY,
                degradationPreference: DegradationPreference = .auto,
                streamName: String? = nil)
    {
        self.name = name
        self.encoding = encoding
        self.screenShareEncoding = screenShareEncoding
        self.simulcast = simulcast
        self.simulcastLayers = simulcastLayers
        self.screenShareSimulcastLayers = screenShareSimulcastLayers
        self.preferredCodec = preferredCodec
        self.preferredBackupCodec = preferredBackupCodec
        self.scalabilityMode = scalabilityMode
        self.degradationPreference = degradationPreference
        self.streamName = streamName
    }

    // MARK: - Equal

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return name == other.name &&
            encoding == other.encoding &&
            screenShareEncoding == other.screenShareEncoding &&
            simulcast == other.simulcast &&
            simulcastLayers == other.simulcastLayers &&
            screenShareSimulcastLayers == other.screenShareSimulcastLayers &&
            preferredCodec == other.preferredCodec &&
            preferredBackupCodec == other.preferredBackupCodec &&
            scalabilityMode == other.scalabilityMode &&
            degradationPreference == other.degradationPreference &&
            streamName == other.streamName
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(name)
        hasher.combine(encoding)
        hasher.combine(screenShareEncoding)
        hasher.combine(simulcast)
        hasher.combine(simulcastLayers)
        hasher.combine(screenShareSimulcastLayers)
        hasher.combine(preferredCodec)
        hasher.combine(preferredBackupCodec)
        hasher.combine(scalabilityMode)
        hasher.combine(degradationPreference)
        hasher.combine(streamName)
        return hasher.finalize()
    }
}
