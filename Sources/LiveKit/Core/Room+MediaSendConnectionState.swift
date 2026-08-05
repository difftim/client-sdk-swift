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
    func recomputeMediaSendConnectionState(publisherPCState: LKRTCPeerConnectionState? = nil) {
        _ = _state.mutate { state -> MediaSendConnectionState in
            if let publisherPCState {
                state.publisherTransportPCStateRaw = publisherPCState.rawValue
            }

            let pcState = publisherPCState ?? state.publisherTransportPCStateRaw.flatMap {
                LKRTCPeerConnectionState(rawValue: $0)
            }

            let isSubscriberPrimary: Bool = state.transport?.isSubscriberPrimary ?? false

            let computed = Self.computeMediaSendConnectionState(
                connectionState: state.connectionState,
                isSubscriberPrimary: isSubscriberPrimary,
                hasPublished: state.hasPublished,
                isReconnectingWithMode: state.isReconnectingWithMode,
                publisherPCState: pcState
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
        isReconnectingWithMode: ReconnectMode?,
        publisherPCState: LKRTCPeerConnectionState?
    ) -> MediaSendConnectionState {
        switch connectionState {
        case .disconnected, .disconnecting:
            return .idle
        default:
            break
        }

        if !isSubscriberPrimary {
            switch connectionState {
            case .connected where isReconnectingWithMode == nil:
                return .connected
            case .connected:
                return .recovering
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

        if isReconnectingWithMode != nil || connectionState == .reconnecting {
            return .recovering
        }

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
            return .recovering
        @unknown default:
            return .connecting
        }
    }

    /// Test helper that avoids importing LiveKitWebRTC from test targets.
    static func computeMediaSendConnectionState(
        connectionState: ConnectionState,
        isSubscriberPrimary: Bool,
        hasPublished: Bool,
        isReconnectingWithMode: ReconnectMode?,
        publisherPCStateRaw: Int?
    ) -> MediaSendConnectionState {
        computeMediaSendConnectionState(
            connectionState: connectionState,
            isSubscriberPrimary: isSubscriberPrimary,
            hasPublished: hasPublished,
            isReconnectingWithMode: isReconnectingWithMode,
            publisherPCState: publisherPCStateRaw.flatMap { LKRTCPeerConnectionState(rawValue: $0) }
        )
    }
}
