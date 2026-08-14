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

private final class MediaSendStateRecorder: NSObject, RoomDelegate, @unchecked Sendable {
    private let recordedStates = StateSync<[MediaSendConnectionState]>([])

    var states: [MediaSendConnectionState] {
        recordedStates.copy()
    }

    func clear() {
        recordedStates.mutate { $0.removeAll() }
    }

    func room(
        _: Room,
        didUpdateMediaSendConnectionState mediaSendConnectionState: MediaSendConnectionState,
        from _: MediaSendConnectionState,
    ) {
        recordedStates.mutate { $0.append(mediaSendConnectionState) }
    }
}

struct MediaSendConnectionStateTests {
    // LKRTCPeerConnectionState raw values (NS_ENUM starting at 0).
    private enum PC: Int {
        case new = 0
        case connecting = 1
        case connected = 2
        case disconnected = 3
        case failed = 4
        case closed = 5
    }

    private func compute(
        connectionState: ConnectionState,
        isSubscriberPrimary: Bool = true,
        hasPublished: Bool,
        isWholeConnectionRecovering: Bool = false,
        hasPublisherEverConnected: Bool = false,
        publisherPC: PC?,
    ) -> MediaSendConnectionState {
        Room.computeMediaSendConnectionState(
            connectionState: connectionState,
            isSubscriberPrimary: isSubscriberPrimary,
            hasPublished: hasPublished,
            isWholeConnectionRecovering: isWholeConnectionRecovering,
            hasPublisherEverConnected: hasPublisherEverConnected,
            publisherPCStateRaw: publisherPC?.rawValue,
        )
    }

    private func drainMediaSendWork(for room: Room) async {
        await withCheckedContinuation { continuation in
            room._blockProcessQueue.async {
                continuation.resume()
            }
        }
        await room.delegates.notifyAsync { _ in }
    }

    @Test func enumCasesPreserveRawValuesAndDescriptions() {
        #expect(MediaSendConnectionState.idle.rawValue == 0)
        #expect(MediaSendConnectionState.connecting.rawValue == 1)
        #expect(MediaSendConnectionState.connected.rawValue == 2)
        #expect(MediaSendConnectionState.recovering.rawValue == 3)
        #expect(MediaSendConnectionState.failed.rawValue == 4)
        #expect(MediaSendConnectionState.roomRecovering.rawValue == 5)
        #expect(MediaSendConnectionState.roomRecovering.description == ".roomRecovering")
    }

    @Test func helperSemanticsDistinguishNegotiationAndRecovery() {
        #expect(!MediaSendConnectionState.connecting.isRoomRecovering)
        #expect(!MediaSendConnectionState.connecting.isMediaSendAbnormal)
        #expect(!MediaSendConnectionState.connecting.isAbnormal)
        #expect(MediaSendConnectionState.connecting.isDegraded)

        #expect(MediaSendConnectionState.roomRecovering.isRoomRecovering)
        #expect(!MediaSendConnectionState.roomRecovering.isMediaSendAbnormal)
        #expect(!MediaSendConnectionState.roomRecovering.isAbnormal)
        #expect(MediaSendConnectionState.roomRecovering.isDegraded)

        #expect(!MediaSendConnectionState.recovering.isRoomRecovering)
        #expect(MediaSendConnectionState.recovering.isMediaSendAbnormal)
        #expect(MediaSendConnectionState.recovering.isAbnormal)
        #expect(MediaSendConnectionState.recovering.isDegraded)
        #expect(MediaSendConnectionState.failed.isMediaSendAbnormal)
    }

    @Test func stalePublisherCallbackIdentityIsRejectedAfterCleanupOrReplacement() {
        let oldPublisherID = "old-publisher"
        let newPublisherID = "new-publisher"

        #expect(!Room.isCurrentPublisherTransport(
            callbackTransportID: oldPublisherID,
            currentPublisherTransportID: nil,
        ))
        #expect(!Room.isCurrentPublisherTransport(
            callbackTransportID: oldPublisherID,
            currentPublisherTransportID: newPublisherID,
        ))
        #expect(Room.isCurrentPublisherTransport(
            callbackTransportID: newPublisherID,
            currentPublisherTransportID: newPublisherID,
        ))
    }

    @Test func idleWhenDisconnected() {
        #expect(compute(
            connectionState: .disconnected,
            hasPublished: true,
            isWholeConnectionRecovering: true,
            hasPublisherEverConnected: true,
            publisherPC: .failed,
        ) == .idle)
        #expect(compute(
            connectionState: .disconnecting,
            hasPublished: true,
            isWholeConnectionRecovering: true,
            hasPublisherEverConnected: true,
            publisherPC: .connected,
        ) == .idle)
    }

    @Test func idleWithoutPublishDemand() {
        #expect(compute(connectionState: .connected, hasPublished: false, publisherPC: nil) == .idle)
        #expect(compute(connectionState: .connected, hasPublished: false, publisherPC: .connecting) == .idle)
    }

    @Test func connectingWhilePublisherNegotiates() {
        #expect(compute(connectionState: .connected, hasPublished: true, publisherPC: nil) == .connecting)
        #expect(compute(connectionState: .connected, hasPublished: true, publisherPC: .new) == .connecting)
        #expect(compute(connectionState: .connected, hasPublished: true, publisherPC: .connecting) == .connecting)
        #expect(compute(connectionState: .connecting, hasPublished: true, publisherPC: .connecting) == .connecting)
        #expect(compute(connectionState: .connected, hasPublished: true, publisherPC: .disconnected) == .connecting)
    }

    @Test func connectedWhenPublisherReady() {
        #expect(compute(connectionState: .connected, hasPublished: true, publisherPC: .connected) == .connected)
    }

    @Test func recoveringOnlyAfterPublisherPreviouslyConnected() {
        #expect(compute(
            connectionState: .connected,
            hasPublished: true,
            hasPublisherEverConnected: true,
            publisherPC: .disconnected,
        ) == .recovering)
    }

    @Test func roomRecoveryHasPriorityOverPublisherState() {
        for publisherPC in [PC.new, .connecting, .connected, .disconnected, .failed, .closed] {
            #expect(compute(
                connectionState: .connected,
                hasPublished: true,
                isWholeConnectionRecovering: true,
                hasPublisherEverConnected: true,
                publisherPC: publisherPC,
            ) == .roomRecovering)
        }

        #expect(compute(
            connectionState: .reconnecting,
            hasPublished: false,
            isWholeConnectionRecovering: true,
            publisherPC: nil,
        ) == .roomRecovering)
    }

    @Test func failedWhenPublisherFailedOrClosed() {
        #expect(compute(connectionState: .connected, hasPublished: true, publisherPC: .failed) == .failed)
        #expect(compute(connectionState: .connected, hasPublished: true, publisherPC: .closed) == .failed)
    }

    @Test func publisherPrimaryMirrorsRoomWhenConnected() {
        #expect(compute(
            connectionState: .connected,
            isSubscriberPrimary: false,
            hasPublished: false,
            publisherPC: nil,
        ) == .connected)

        #expect(compute(
            connectionState: .connected,
            isSubscriberPrimary: false,
            hasPublished: true,
            isWholeConnectionRecovering: true,
            hasPublisherEverConnected: true,
            publisherPC: .failed,
        ) == .roomRecovering)

        #expect(compute(
            connectionState: .connecting,
            isSubscriberPrimary: false,
            hasPublished: true,
            publisherPC: .connecting,
        ) == .connecting)

        #expect(compute(
            connectionState: .connecting,
            isSubscriberPrimary: false,
            hasPublished: false,
            publisherPC: nil,
        ) == .idle)
    }

    @Test func wholeConnectionRecoveryLatchEntryAndStableClear() {
        #expect(Room.computeWholeConnectionRecovering(
            wasRecovering: false,
            connectionState: .connected,
            hasConnectivity: false,
            hasPendingReconnect: false,
            isReconnectStartPending: false,
            isReconnectingWithMode: false,
            hasPublished: true,
            isPublisherPCConnected: true,
        ))

        #expect(Room.computeWholeConnectionRecovering(
            wasRecovering: true,
            connectionState: .connected,
            hasConnectivity: nil,
            hasPendingReconnect: false,
            isReconnectStartPending: false,
            isReconnectingWithMode: false,
            hasPublished: true,
            isPublisherPCConnected: true,
        ) == false)

        #expect(Room.computeWholeConnectionRecovering(
            wasRecovering: true,
            connectionState: .connected,
            hasConnectivity: true,
            hasPendingReconnect: false,
            isReconnectStartPending: false,
            isReconnectingWithMode: false,
            hasPublished: true,
            isPublisherPCConnected: false,
        ))

        #expect(Room.computeWholeConnectionRecovering(
            wasRecovering: true,
            connectionState: .connected,
            hasConnectivity: true,
            hasPendingReconnect: false,
            isReconnectStartPending: false,
            isReconnectingWithMode: false,
            hasPublished: false,
            isPublisherPCConnected: false,
        ) == false)
    }

    @Test func everyWholeRecoveryEntrySignalSetsLatch() {
        let stable = (
            connectionState: ConnectionState.connected,
            hasConnectivity: Optional(true),
            hasPendingReconnect: false,
            isReconnectStartPending: false,
            isReconnectingWithMode: false,
        )

        #expect(Room.computeWholeConnectionRecovering(
            wasRecovering: false,
            connectionState: .reconnecting,
            hasConnectivity: stable.hasConnectivity,
            hasPendingReconnect: stable.hasPendingReconnect,
            isReconnectStartPending: stable.isReconnectStartPending,
            isReconnectingWithMode: stable.isReconnectingWithMode,
            hasPublished: false,
            isPublisherPCConnected: false,
        ))
        #expect(Room.computeWholeConnectionRecovering(
            wasRecovering: false,
            connectionState: stable.connectionState,
            hasConnectivity: stable.hasConnectivity,
            hasPendingReconnect: true,
            isReconnectStartPending: stable.isReconnectStartPending,
            isReconnectingWithMode: stable.isReconnectingWithMode,
            hasPublished: false,
            isPublisherPCConnected: false,
        ))
        #expect(Room.computeWholeConnectionRecovering(
            wasRecovering: false,
            connectionState: stable.connectionState,
            hasConnectivity: stable.hasConnectivity,
            hasPendingReconnect: stable.hasPendingReconnect,
            isReconnectStartPending: true,
            isReconnectingWithMode: stable.isReconnectingWithMode,
            hasPublished: false,
            isPublisherPCConnected: false,
        ))
        #expect(Room.computeWholeConnectionRecovering(
            wasRecovering: false,
            connectionState: stable.connectionState,
            hasConnectivity: stable.hasConnectivity,
            hasPendingReconnect: stable.hasPendingReconnect,
            isReconnectStartPending: stable.isReconnectStartPending,
            isReconnectingWithMode: true,
            hasPublished: false,
            isPublisherPCConnected: false,
        ))
    }

    @Test func fullReconnectPreservesSessionHistoryAndRecoveryUntilCompleteCleanup() async {
        let recorder = MediaSendStateRecorder()
        let room = Room(delegate: recorder)
        room._state.mutate {
            $0.mediaSendConnectionGeneration = 42
            $0.connectionState = .reconnecting
            $0.isReconnectingWithMode = .full
            $0.hasPublisherEverConnected = true
            $0.isWholeConnectionRecovering = true
            $0.mediaSendConnectionState = .roomRecovering
        }
        await drainMediaSendWork(for: room)
        recorder.clear()

        await room.cleanUp(isFullReconnect: true)
        await drainMediaSendWork(for: room)

        #expect(room._state.hasPublisherEverConnected)
        #expect(room._state.isWholeConnectionRecovering)
        #expect(room._state.mediaSendConnectionGeneration == 42)
        #expect(room.mediaSendConnectionState == .roomRecovering)
        #expect(recorder.states == [])

        await room.cleanUp()
        await drainMediaSendWork(for: room)

        #expect(!room._state.hasPublisherEverConnected)
        #expect(!room._state.isWholeConnectionRecovering)
        #expect(room.mediaSendConnectionState == .idle)
        #expect(recorder.states == [.idle])
    }

    @Test func transientWholeRecoveryEntryIsProcessedBeforeStableClear() async {
        let recorder = MediaSendStateRecorder()
        let room = Room(delegate: recorder)

        room._state.mutate {
            $0.connectionState = .connected
            $0.hasConnectivity = true
            $0.mediaSendConnectionState = .idle
        }
        await drainMediaSendWork(for: room)
        #expect(room.mediaSendConnectionState == .connected)
        recorder.clear()

        room._blockProcessQueue.suspend()
        room._state.mutate { $0.hasConnectivity = false }
        room._state.mutate { $0.hasConnectivity = true }

        #expect(room._state.hasConnectivity == true)
        room._blockProcessQueue.resume()
        await drainMediaSendWork(for: room)

        #expect(recorder.states == [.roomRecovering, .connected])
    }

    @Test func completeCleanupInvalidatesQueuedRecoverySnapshots() async {
        let recorder = MediaSendStateRecorder()
        let room = Room(delegate: recorder)

        room._state.mutate {
            $0.connectionState = .connected
            $0.hasConnectivity = true
            $0.mediaSendConnectionState = .connected
        }
        await drainMediaSendWork(for: room)
        recorder.clear()
        let oldGeneration = room._state.mediaSendConnectionGeneration

        room._blockProcessQueue.suspend()
        room._state.mutate { $0.hasConnectivity = false }
        await room.cleanUp()
        room._blockProcessQueue.resume()
        await drainMediaSendWork(for: room)

        #expect(room.connectionState == .disconnected)
        #expect(room._state.mediaSendConnectionGeneration != oldGeneration)
        #expect(room.mediaSendConnectionState == .idle)
        #expect(!room._state.hasPublisherEverConnected)
        #expect(!room._state.isWholeConnectionRecovering)
        #expect(recorder.states == [.idle])

        room._state.mutate {
            $0.connectionState = .connected
            $0.hasConnectivity = true
        }
        await drainMediaSendWork(for: room)

        #expect(room.mediaSendConnectionState == .connected)
        #expect(recorder.states == [.idle, .connected])
    }

    @Test func lookupWarningConditionDoesNotWarnForConnecting() {
        func shouldWarn(room: ConnectionState, send: MediaSendConnectionState) -> Bool {
            room == .connected && (send.isRoomRecovering || send.isMediaSendAbnormal)
        }

        #expect(!shouldWarn(room: .connected, send: .idle))
        #expect(!shouldWarn(room: .connected, send: .connected))
        #expect(!shouldWarn(room: .connected, send: .connecting))
        #expect(shouldWarn(room: .connected, send: .roomRecovering))
        #expect(shouldWarn(room: .connected, send: .recovering))
        #expect(shouldWarn(room: .connected, send: .failed))
        #expect(!shouldWarn(room: .connecting, send: .failed))
        #expect(!shouldWarn(room: .reconnecting, send: .roomRecovering))
    }
}
