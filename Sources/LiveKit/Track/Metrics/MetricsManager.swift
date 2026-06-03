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
import OrderedCollections

// MARK: - Triggers

extension MetricsManager: RoomDelegate {
    nonisolated func room(_ room: Room, participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        guard let track = publication.track else { return }
        Task { await register(track: track, in: room, localParticipant: participant, isPublisher: true) }
    }

    nonisolated func room(_: Room, participant _: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) {
        guard let track = publication.track else { return }
        Task { await unregister(track: track) }
    }

    nonisolated func room(_ room: Room, participant _: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        guard let track = publication.track else { return }
        Task { await register(track: track, in: room, localParticipant: room.localParticipant, isPublisher: false) } // send from local participant
    }

    nonisolated func room(_: Room, participant _: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        guard let track = publication.track else { return }
        Task { await unregister(track: track) }
    }
}

extension MetricsManager: TrackDelegate {
    // If Track.reportStatistics is disabled, this delegate method will not be called.
    nonisolated func track(_ track: Track, didUpdateStatistics: TrackStatistics, simulcastStatistics _: [VideoCodec: TrackStatistics]) {
        Task(priority: .low) {
            await sendMetrics(track: track, statistics: didUpdateStatistics)
        }
    }
}

// MARK: - Actor

/// An actor that converts track statistics into metrics and sends them to the server as data packets.
actor MetricsManager {
    private struct TrackProperties {
        let identity: LocalParticipant.Identity?
        weak var room: Room?
        let isPublisher: Bool
        var lastSentHash: Int?
    }

    private var trackProperties: [Track.Sid: TrackProperties] = [:]

    init() {}

    func register(room: Room) {
        room.add(delegate: self)
    }

    private func register(track: Track, in room: Room, localParticipant: LocalParticipant, isPublisher: Bool) {
        guard let sid = track.sid else { return }
        trackProperties[sid] = TrackProperties(identity: localParticipant.identity, room: room, isPublisher: isPublisher)
        track.add(delegate: self)
    }

    private func unregister(track: Track) {
        guard let sid = track.sid else { return }
        track.remove(delegate: self)
        trackProperties[sid] = nil
    }

    private func sendMetrics(track: Track, statistics: TrackStatistics) async {
        guard let sid = track.sid, let props = trackProperties[sid] else { return }
        // Drop metrics whenever the Room is not in a steady connected state so
        // that quick reconnect storms (publisher .failed, every dataPacket
        // stacking a 10s `AsyncCompleter.wait`) don't pressure the WebRTC
        // worker thread. Metrics are best-effort by design — losing a sample
        // here is benign and the next sample will carry cumulative counters.
        // See Docs/reconnect-metrics-storm-and-worker-crash-fix.md (Fix-5).
        guard let room = props.room, room.isSteadyConnected else { return }

        let hash = statistics.hashValue
        guard hash != props.lastSentHash else { return }

        var dataPacket = Livekit_DataPacket()
        dataPacket.kind = .reliable
        dataPacket.metrics = Livekit_MetricsBatch(statistics: statistics, identity: props.identity, trackSid: sid, isPublisher: props.isPublisher)
        do {
            try await room.send(dataPacket: dataPacket)
            trackProperties[sid]?.lastSentHash = hash
        } catch {
        }
    }
}

// MARK: - Statistics -> protobufs

extension Livekit_MetricsBatch {
    init(statistics: TrackStatistics, identity: Participant.Identity?, trackSid: Track.Sid?, isPublisher: Bool) {
        var strings = OrderedSet<String>()
        defer { strData = strings.elements }

        addOutboundMetrics(from: statistics.outboundRtpStream, strings: &strings, identity: identity, sid: trackSid?.stringValue)
        addInboundMetrics(from: statistics.inboundRtpStream, strings: &strings, identity: identity)
        addPublisherStreamRttMetrics(
            from: statistics.remoteInboundRtpStream,
            outboundRtpStreams: statistics.outboundRtpStream,
            strings: &strings,
            identity: identity,
            sid: trackSid?.stringValue
        )
        addSubscriberStreamRttMetrics(
            from: statistics.remoteOutboundRtpStream,
            inboundRtpStreams: statistics.inboundRtpStream,
            strings: &strings,
            identity: identity
        )
        addConnectionRttMetrics(from: statistics.iceCandidatePair, strings: &strings, identity: identity, isPublisher: isPublisher)
        if !isPublisher {
            addSubscriberNetworkMetrics(from: statistics.iceCandidatePair, strings: &strings, identity: identity)
        }
    }

    init(candidatePairStatistics: [IceCandidatePairStatistics], identity: Participant.Identity?) {
        var strings = OrderedSet<String>()
        defer { strData = strings.elements }

        addSubscriberNetworkMetrics(from: candidatePairStatistics, strings: &strings, identity: identity)
    }

    mutating func addOutboundMetrics(from statistics: [OutboundRtpStreamStatistics], strings: inout OrderedSet<String>, identity: Participant.Identity?, sid: String?) {
        for stat in statistics {
            if stat.kind == "video" {
                if let durations = stat.qualityLimitationDurations {
                    addMetric(durations.cpu, at: stat.timestamp, label: .clientVideoPublisherQualityLimitationDurationCpu, strings: &strings, identity: identity, sid: sid, rid: stat.rid)
                    addMetric(durations.bandwidth, at: stat.timestamp, label: .clientVideoPublisherQualityLimitationDurationBandwidth, strings: &strings, identity: identity, sid: sid, rid: stat.rid)
                    addMetric(durations.other, at: stat.timestamp, label: .clientVideoPublisherQualityLimitationDurationOther, strings: &strings, identity: identity, sid: sid, rid: stat.rid)
                }

                addMetric(stat.packetsSent, at: stat.timestamp, label: .clientVideoPublisherPacketsSent, strings: &strings, identity: identity, sid: sid, rid: stat.rid)
                addMetric(stat.bytesSent, at: stat.timestamp, label: .clientVideoPublisherBytesSent, strings: &strings, identity: identity, sid: sid, rid: stat.rid)
                addMetric(stat.retransmittedPacketsSent, at: stat.timestamp, label: .clientVideoPublisherRetransmittedPacketsSent, strings: &strings, identity: identity, sid: sid, rid: stat.rid)
                addMetric(stat.retransmittedBytesSent, at: stat.timestamp, label: .clientVideoPublisherRetransmittedBytesSent, strings: &strings, identity: identity, sid: sid, rid: stat.rid)
                addMetric(stat.targetBitrate, at: stat.timestamp, label: .clientVideoPublisherTargetBitrate, strings: &strings, identity: identity, sid: sid, rid: stat.rid)
                addMetric(stat.framesEncoded, at: stat.timestamp, label: .clientVideoPublisherFramesEncoded, strings: &strings, identity: identity, sid: sid, rid: stat.rid)
                addMetric(stat.keyFramesEncoded, at: stat.timestamp, label: .clientVideoPublisherKeyFramesEncoded, strings: &strings, identity: identity, sid: sid, rid: stat.rid)
                addMetric(stat.framesSent, at: stat.timestamp, label: .clientVideoPublisherFramesSent, strings: &strings, identity: identity, sid: sid, rid: stat.rid)
                addMetric(stat.hugeFramesSent, at: stat.timestamp, label: .clientVideoPublisherHugeFramesSent, strings: &strings, identity: identity, sid: sid, rid: stat.rid)
                addMetric(stat.frameWidth, at: stat.timestamp, label: .clientVideoPublisherFrameWidth, strings: &strings, identity: identity, sid: sid, rid: stat.rid)
                addMetric(stat.frameHeight, at: stat.timestamp, label: .clientVideoPublisherFrameHeight, strings: &strings, identity: identity, sid: sid, rid: stat.rid)
                addMetric(stat.framesPerSecond, at: stat.timestamp, label: .clientVideoPublisherFramesPerSecond, strings: &strings, identity: identity, sid: sid, rid: stat.rid)
                addMetric(stat.totalEncodeTime, at: stat.timestamp, label: .clientVideoPublisherTotalEncodeTime, strings: &strings, identity: identity, sid: sid, rid: stat.rid)
                addMetric(stat.totalPacketSendDelay, at: stat.timestamp, label: .clientVideoPublisherTotalPacketSendDelay, strings: &strings, identity: identity, sid: sid, rid: stat.rid)
                addMetric(stat.pliCount, at: stat.timestamp, label: .clientVideoPublisherPliCount, strings: &strings, identity: identity, sid: sid, rid: stat.rid)
                addMetric(stat.firCount, at: stat.timestamp, label: .clientVideoPublisherFirCount, strings: &strings, identity: identity, sid: sid, rid: stat.rid)
                addMetric(stat.nackCount, at: stat.timestamp, label: .clientVideoPublisherNackCount, strings: &strings, identity: identity, sid: sid, rid: stat.rid)
                addMetric(stat.qpSum, at: stat.timestamp, label: .clientVideoPublisherQpSum, strings: &strings, identity: identity, sid: sid, rid: stat.rid)
                addMetric(stat.qualityLimitationResolutionChanges, at: stat.timestamp, label: .clientVideoPublisherQualityLimitationResolutionChanges, strings: &strings, identity: identity, sid: sid, rid: stat.rid)
            } else if stat.kind == "audio" {
                addMetric(stat.packetsSent, at: stat.timestamp, label: .clientAudioPublisherPacketsSent, strings: &strings, identity: identity, sid: sid)
                addMetric(stat.bytesSent, at: stat.timestamp, label: .clientAudioPublisherBytesSent, strings: &strings, identity: identity, sid: sid)
                addMetric(stat.retransmittedPacketsSent, at: stat.timestamp, label: .clientAudioPublisherRetransmittedPacketsSent, strings: &strings, identity: identity, sid: sid)
                addMetric(stat.retransmittedBytesSent, at: stat.timestamp, label: .clientAudioPublisherRetransmittedBytesSent, strings: &strings, identity: identity, sid: sid)
                addMetric(stat.targetBitrate, at: stat.timestamp, label: .clientAudioPublisherTargetBitrate, strings: &strings, identity: identity, sid: sid)
                addMetric(stat.totalPacketSendDelay, at: stat.timestamp, label: .clientAudioPublisherTotalPacketSendDelay, strings: &strings, identity: identity, sid: sid)
            }
        }
    }

    mutating func addInboundMetrics(from statistics: [InboundRtpStreamStatistics], strings: inout OrderedSet<String>, identity: Participant.Identity?) {
        for stat in statistics {
            if stat.kind == "audio" {
                addMetric(stat.concealedSamples, at: stat.timestamp, label: .clientAudioSubscriberConcealedSamples, strings: &strings, identity: identity, sid: stat.trackIdentifier)
                addMetric(stat.concealmentEvents, at: stat.timestamp, label: .clientAudioSubscriberConcealmentEvents, strings: &strings, identity: identity, sid: stat.trackIdentifier)
                addMetric(stat.silentConcealedSamples, at: stat.timestamp, label: .clientAudioSubscriberSilentConcealedSamples, strings: &strings, identity: identity, sid: stat.trackIdentifier)
                addMetric(stat.interruptionCount, at: stat.timestamp, label: .clientAudioSubscriberInterruptionCount, strings: &strings, identity: identity, sid: stat.trackIdentifier)
                addMetric(stat.totalInterruptionDuration, at: stat.timestamp, label: .clientAudioSubscriberTotalInterruptionDuration, strings: &strings, identity: identity, sid: stat.trackIdentifier)
            } else if stat.kind == "video" {
                addMetric(stat.freezeCount, at: stat.timestamp, label: .clientVideoSubscriberFreezeCount, strings: &strings, identity: identity, sid: stat.trackIdentifier)
                addMetric(stat.totalFreezesDuration, at: stat.timestamp, label: .clientVideoSubscriberTotalFreezeDuration, strings: &strings, identity: identity, sid: stat.trackIdentifier)
                addMetric(stat.pauseCount, at: stat.timestamp, label: .clientVideoSubscriberPauseCount, strings: &strings, identity: identity, sid: stat.trackIdentifier)
                addMetric(stat.totalPausesDuration, at: stat.timestamp, label: .clientVideoSubscriberTotalPausesDuration, strings: &strings, identity: identity, sid: stat.trackIdentifier)
                addMetric(stat.packetsReceived, at: stat.timestamp, label: .clientVideoSubscriberPacketsReceived, strings: &strings, identity: identity, sid: stat.trackIdentifier)
                addMetric(stat.bytesReceived, at: stat.timestamp, label: .clientVideoSubscriberBytesReceived, strings: &strings, identity: identity, sid: stat.trackIdentifier)
                addMetric(stat.packetsLost, at: stat.timestamp, label: .clientVideoSubscriberPacketsLost, strings: &strings, identity: identity, sid: stat.trackIdentifier)
                addMetric(stat.jitter, at: stat.timestamp, label: .clientVideoSubscriberJitter, strings: &strings, identity: identity, sid: stat.trackIdentifier)
                addMetric(stat.framesReceived, at: stat.timestamp, label: .clientVideoSubscriberFramesReceived, strings: &strings, identity: identity, sid: stat.trackIdentifier)
                addMetric(stat.framesDecoded, at: stat.timestamp, label: .clientVideoSubscriberFramesDecoded, strings: &strings, identity: identity, sid: stat.trackIdentifier)
                addMetric(stat.keyFramesDecoded, at: stat.timestamp, label: .clientVideoSubscriberKeyFramesDecoded, strings: &strings, identity: identity, sid: stat.trackIdentifier)
                addMetric(stat.framesDropped, at: stat.timestamp, label: .clientVideoSubscriberFramesDropped, strings: &strings, identity: identity, sid: stat.trackIdentifier)
                addMetric(stat.frameWidth, at: stat.timestamp, label: .clientVideoSubscriberFrameWidth, strings: &strings, identity: identity, sid: stat.trackIdentifier)
                addMetric(stat.frameHeight, at: stat.timestamp, label: .clientVideoSubscriberFrameHeight, strings: &strings, identity: identity, sid: stat.trackIdentifier)
                addMetric(stat.framesPerSecond, at: stat.timestamp, label: .clientVideoSubscriberFramesPerSecond, strings: &strings, identity: identity, sid: stat.trackIdentifier)
                addMetric(stat.jitterBufferTargetDelay, at: stat.timestamp, label: .clientVideoSubscriberJitterBufferTargetDelay, strings: &strings, identity: identity, sid: stat.trackIdentifier)
                addMetric(stat.jitterBufferMinimumDelay, at: stat.timestamp, label: .clientVideoSubscriberJitterBufferMinimumDelay, strings: &strings, identity: identity, sid: stat.trackIdentifier)
                addMetric(stat.totalDecodeTime, at: stat.timestamp, label: .clientVideoSubscriberTotalDecodeTime, strings: &strings, identity: identity, sid: stat.trackIdentifier)
                addMetric(stat.totalProcessingDelay, at: stat.timestamp, label: .clientVideoSubscriberTotalProcessingDelay, strings: &strings, identity: identity, sid: stat.trackIdentifier)
                addMetric(stat.totalAssemblyTime, at: stat.timestamp, label: .clientVideoSubscriberTotalAssemblyTime, strings: &strings, identity: identity, sid: stat.trackIdentifier)
                addMetric(stat.pliCount, at: stat.timestamp, label: .clientVideoSubscriberPliCount, strings: &strings, identity: identity, sid: stat.trackIdentifier)
                addMetric(stat.firCount, at: stat.timestamp, label: .clientVideoSubscriberFirCount, strings: &strings, identity: identity, sid: stat.trackIdentifier)
                addMetric(stat.nackCount, at: stat.timestamp, label: .clientVideoSubscriberNackCount, strings: &strings, identity: identity, sid: stat.trackIdentifier)
            }

            // Common metrics
            addMetric(stat.jitterBufferDelay, at: stat.timestamp, label: .clientSubscriberJitterBufferDelay, strings: &strings, identity: identity, sid: stat.trackIdentifier)
            addMetric(stat.jitterBufferEmittedCount, at: stat.timestamp, label: .clientSubscriberJitterBufferEmittedCount, strings: &strings, identity: identity, sid: stat.trackIdentifier)
        }
    }

    mutating func addConnectionRttMetrics(from statistics: [IceCandidatePairStatistics], strings: inout OrderedSet<String>, identity: Participant.Identity?, isPublisher: Bool) {
        let label: Livekit_MetricLabel = isPublisher ? .publisherRtt : .subscriberRtt
        for stat in statistics {
            addMetric(stat.currentRoundTripTime, at: stat.timestamp, label: label, strings: &strings, identity: identity)
        }
    }

    mutating func addPublisherStreamRttMetrics(
        from statistics: [RemoteInboundRtpStreamStatistics],
        outboundRtpStreams: [OutboundRtpStreamStatistics],
        strings: inout OrderedSet<String>,
        identity: Participant.Identity?,
        sid: String?
    ) {
        for stat in statistics {
            let outbound = outboundRtpStreams.first { $0.id == stat.localId }
            addMetric(stat.roundTripTime, at: stat.timestamp, label: .clientPublisherStreamRtt, strings: &strings, identity: identity, sid: sid, rid: outbound?.rid)
        }
    }

    mutating func addSubscriberStreamRttMetrics(
        from statistics: [RemoteOutboundRtpStreamStatistics],
        inboundRtpStreams: [InboundRtpStreamStatistics],
        strings: inout OrderedSet<String>,
        identity: Participant.Identity?
    ) {
        for stat in statistics {
            let inbound = inboundRtpStreams.first { $0.id == stat.localId }
            addMetric(stat.roundTripTime, at: stat.timestamp, label: .clientSubscriberStreamRtt, strings: &strings, identity: identity, sid: inbound?.trackIdentifier)
        }
    }

    mutating func addSubscriberNetworkMetrics(from statistics: [IceCandidatePairStatistics], strings: inout OrderedSet<String>, identity: Participant.Identity?) {
        for stat in statistics {
            addMetric(stat.currentRoundTripTime, at: stat.timestamp, label: .clientSubscriberCurrentRoundTripTime, strings: &strings, identity: identity)
            addMetric(stat.availableIncomingBitrate, at: stat.timestamp, label: .clientSubscriberAvailableIncomingBitrate, strings: &strings, identity: identity)
        }
    }

    mutating func addMetric(
        _ value: (some Numeric)?,
        at timestampUs: Double,
        label: Livekit_MetricLabel,
        strings: inout OrderedSet<String>,
        identity: Participant.Identity? = nil,
        sid: String? = nil,
        rid: String? = nil
    ) {
        guard let sample = createSample(timestampUs: timestampUs, value: value) else { return }
        let timeSeries = createTimeSeries(
            label: label,
            strings: &strings,
            samples: [sample],
            identity: identity,
            sid: sid,
            rid: rid
        )
        self.timeSeries.append(timeSeries)
    }

    func createSample(timestampUs: Double, value: (some Numeric)?) -> Livekit_MetricSample? {
        guard let floatValue = value?.floatValue else { return nil }
        guard floatValue != .zero else { return nil }

        var sample = Livekit_MetricSample()
        sample.timestampMs = Int64(timestampUs / 1000)
        sample.value = floatValue
        return sample
    }

    func createTimeSeries(
        label: Livekit_MetricLabel,
        strings: inout OrderedSet<String>,
        samples: [Livekit_MetricSample],
        identity: Participant.Identity? = nil,
        sid: String? = nil,
        rid: String? = nil
    ) -> Livekit_TimeSeriesMetric {
        var timeSeries = Livekit_TimeSeriesMetric()
        timeSeries.label = UInt32(label.rawValue)
        timeSeries.samples = samples

        if let identity {
            timeSeries.participantIdentity = getOrCreateIndex(in: &strings, inserting: identity.stringValue)
        }
        if let sid {
            timeSeries.trackSid = getOrCreateIndex(in: &strings, inserting: sid)
        }
        if let rid {
            timeSeries.rid = getOrCreateIndex(in: &strings, inserting: rid)
        }

        return timeSeries
    }

    /// Gets or creates an index for a custom string in the protobuf message
    /// starting from a predefined reserved value.
    ///
    /// Receivers should interpret index values as follows:
    /// ```
    /// if index < predefinedMaxValue {
    ///    MetricLabel(rawValue: index)
    /// } else {
    ///    str_data[index - 4096]
    /// }
    /// ```
    func getOrCreateIndex(in set: inout OrderedSet<String>, inserting string: String) -> UInt32 {
        let offset = Livekit_MetricLabel.predefinedMaxValue.rawValue
        let index = set.append(string).index
        return UInt32(index + offset)
    }

}

private extension Numeric {
    var floatValue: Float? {
        if let integer = self as? any BinaryInteger {
            return Float(integer)
        } else if let floatingPoint = self as? any BinaryFloatingPoint {
            return Float(floatingPoint)
        } else {
            assertionFailure("Cannot convert Numeric \(Self.self)")
            return nil
        }
    }
}
