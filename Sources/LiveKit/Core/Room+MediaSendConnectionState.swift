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

internal import LiveKitWebRTC

extension Room {
    private struct MediaSendConnectionSnapshot {
        let connectionState: ConnectionState
        let isSubscriberPrimary: Bool
        let hasPublished: Bool
        let hasConnectivity: Bool?
        let hasPendingReconnect: Bool
        let isReconnectStartPending: Bool
        let isReconnectingWithMode: Bool
        let generation: UInt64
        let hasPublisherEverConnected: Bool
        let publisherPCStateRaw: Int?

        init(state: State) {
            connectionState = state.connectionState
            isSubscriberPrimary = state.transport?.isSubscriberPrimary ?? false
            hasPublished = state.hasPublished
            hasConnectivity = state.hasConnectivity
            hasPendingReconnect = state.pendingReconnectOnConnectivity != nil
            isReconnectStartPending = state.isReconnectStartPending
            isReconnectingWithMode = state.isReconnectingWithMode != nil
            generation = state.mediaSendConnectionGeneration
            hasPublisherEverConnected = state.hasPublisherEverConnected
            publisherPCStateRaw = state.publisherTransportPCStateRaw
        }
    }

    func enqueueMediaSendConnectionStateTransition(state: State) {
        let snapshot = MediaSendConnectionSnapshot(state: state)
        _blockProcessQueue.async { [weak self] in
            self?.processMediaSendConnectionStateTransition(snapshot)
        }
    }

    private func processMediaSendConnectionStateTransition(_ snapshot: MediaSendConnectionSnapshot) {
        _ = _state.mutate { state -> MediaSendConnectionState in
            guard snapshot.generation == state.mediaSendConnectionGeneration else {
                return state.mediaSendConnectionState
            }

            let pcState = snapshot.publisherPCStateRaw.flatMap {
                LKRTCPeerConnectionState(rawValue: $0)
            }

            state.isWholeConnectionRecovering = Self.computeWholeConnectionRecovering(
                wasRecovering: state.isWholeConnectionRecovering,
                connectionState: snapshot.connectionState,
                hasConnectivity: snapshot.hasConnectivity,
                hasPendingReconnect: snapshot.hasPendingReconnect,
                isReconnectStartPending: snapshot.isReconnectStartPending,
                isReconnectingWithMode: snapshot.isReconnectingWithMode,
                hasPublished: snapshot.hasPublished,
                isPublisherPCConnected: pcState == .connected,
            )

            let computed = Self.computeMediaSendConnectionState(
                connectionState: snapshot.connectionState,
                isSubscriberPrimary: snapshot.isSubscriberPrimary,
                hasPublished: snapshot.hasPublished,
                isWholeConnectionRecovering: state.isWholeConnectionRecovering,
                hasPublisherEverConnected: snapshot.hasPublisherEverConnected,
                publisherPCState: pcState,
            )

            guard state.mediaSendConnectionState != computed else {
                return state.mediaSendConnectionState
            }

            state.mediaSendConnectionState = computed
            return computed
        }
    }

    static func computeMediaSendConnectionState(
        connectionState: ConnectionState,
        isSubscriberPrimary: Bool,
        hasPublished: Bool,
        isWholeConnectionRecovering: Bool,
        hasPublisherEverConnected: Bool,
        publisherPCState: LKRTCPeerConnectionState?,
    ) -> MediaSendConnectionState {
        switch connectionState {
        case .disconnected, .disconnecting:
            return .idle
        default:
            break
        }

        if isWholeConnectionRecovering {
            return .roomRecovering
        }

        if !isSubscriberPrimary {
            switch connectionState {
            case .connected:
                return .connected
            case .connecting, .reconnecting:
                return hasPublished ? .connecting : .idle
            default:
                return .idle
            }
        }

        guard connectionState == .connected || connectionState == .reconnecting else {
            if connectionState == .connecting, hasPublished {
                return .connecting
            }
            return .idle
        }

        guard hasPublished else { return .idle }

        guard let publisherPCState else {
            return .connecting
        }

        switch publisherPCState {
        case .connected:
            return .connected
        case .connecting, .new:
            return .connecting
        case .failed, .closed:
            return .failed
        case .disconnected:
            return hasPublisherEverConnected ? .recovering : .connecting
        @unknown default:
            return .connecting
        }
    }

    static func computeWholeConnectionRecovering(
        wasRecovering: Bool,
        connectionState: ConnectionState,
        hasConnectivity: Bool?,
        hasPendingReconnect: Bool,
        isReconnectStartPending: Bool,
        isReconnectingWithMode: Bool,
        hasPublished: Bool,
        isPublisherPCConnected: Bool,
    ) -> Bool {
        let hasRecoverySignal = hasConnectivity == false
            || hasPendingReconnect
            || isReconnectStartPending
            || isReconnectingWithMode
            || connectionState == .reconnecting

        if hasRecoverySignal {
            return true
        }

        guard wasRecovering else { return false }

        let isStable = connectionState == .connected
            && hasConnectivity != false
            && (!hasPublished || isPublisherPCConnected)
        return !isStable
    }

    /// Test helper that avoids importing LiveKitWebRTC from test targets.
    static func computeMediaSendConnectionState(
        connectionState: ConnectionState,
        isSubscriberPrimary: Bool,
        hasPublished: Bool,
        isWholeConnectionRecovering: Bool,
        hasPublisherEverConnected: Bool,
        publisherPCStateRaw: Int?,
    ) -> MediaSendConnectionState {
        computeMediaSendConnectionState(
            connectionState: connectionState,
            isSubscriberPrimary: isSubscriberPrimary,
            hasPublished: hasPublished,
            isWholeConnectionRecovering: isWholeConnectionRecovering,
            hasPublisherEverConnected: hasPublisherEverConnected,
            publisherPCState: publisherPCStateRaw.flatMap { LKRTCPeerConnectionState(rawValue: $0) },
        )
    }
}
