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

extension LKRTCPeerConnectionState {
    var isConnected: Bool {
        self == .connected
    }

    var isDisconnected: Bool {
        // WebRTC .disconnected is transient during network switches and can recover by itself.
        [.failed, .closed].contains(self)
    }
}

extension Room: TransportDelegate {
    static func isCurrentPublisherTransport(
        callbackTransportID: String,
        currentPublisherTransportID: String?,
    ) -> Bool {
        callbackTransportID == currentPublisherTransportID
    }

    func transport(_ transport: Transport, didUpdateState pcState: LKRTCPeerConnectionState) {
        log("target: \(transport.target), connectionState: \(pcState.description)")

        let pcError: LiveKitError? = _state.connectionState.isTearingDown ? nil : LiveKitError(
            .network, message: "Transport \(transport.target) state changed to \(pcState.description)",
        )

        // primary connected
        if transport.isPrimary {
            if pcState.isConnected {
                primaryTransportConnectedCompleter.resume(returning: ())
            } else if pcState.isDisconnected {
                primaryTransportConnectedCompleter.reset(throwing: pcError)
            }
        }

        // publisher connected
        if case .publisher = transport.target {
            if pcState.isConnected {
                publisherTransportConnectedCompleter.resume(returning: ())
            } else if pcState.isDisconnected {
                publisherTransportConnectedCompleter.reset(throwing: pcError)
            }
            _state.mutate {
                guard Self.isCurrentPublisherTransport(
                    callbackTransportID: transport.id,
                    currentPublisherTransportID: $0.transport?.publisher.id,
                ) else {
                    return
                }

                $0.publisherTransportPCStateRaw = pcState.rawValue
                if pcState == .connected {
                    $0.hasPublisherEverConnected = true
                }
            }
        }

        // Allow `.reconnecting` too: when we previously deferred a reconnect
        // due to lost connectivity we are now externally `.reconnecting`, but a
        // subsequent transport failure should still merge into the pending
        // reconnect (upgrading `mode` to `.full` via `requestReconnect`'s merge
        // policy). `requestReconnect`'s own Layer 2 guard prevents re-entering
        // an actively running retry cycle.
        if _state.connectionState == .connected || _state.connectionState == .reconnecting {
            // Attempt re-connect if primary or publisher transport failed
            if transport.isPrimary || (_state.hasPublished && transport.target == .publisher), pcState.isDisconnected {
                requestReconnect(reason: .transport, nextReconnectMode: .full)
            }
        }
    }

    func transport(_ transport: Transport, didGenerateIceCandidate iceCandidate: IceCandidate) {
        Task {
            do {
                log("Transport(\(transport.target)) sending iceCandidate: \(iceCandidate)")
                try await signalClient.sendCandidate(candidate: iceCandidate, target: transport.target)
            } catch {
                log("Failed to send iceCandidate, error: \(error)", .error)
            }
        }
    }

    func transport(_ transport: Transport, didAddTrack track: LKRTCMediaStreamTrack, rtpReceiver: LKRTCRtpReceiver, streams: [LKRTCMediaStream]) {
        guard !streams.isEmpty else {
            log("Received onTrack with no streams!", .warning)
            return
        }

        let currentTransportId = transport.id

        guard currentTransportId == _state.transport?.subscriber.id else { return }

        // execute block when connected
        execute(when: { state, _ in
                    state.connectionState == .connected
                },
                // always remove this block when disconnected
                removeWhen: { state, _ in
                    if state.connectionState == .disconnected {
                        return true
                    } else if currentTransportId != state.transport?.subscriber.id {
                        self.log("Removing track callback from stale transport", .warning)
                        return true
                    } else {
                        return false
                    }
                }) { [weak self] in
            guard let self else { return }
            Task {
                await self.engine(self,
                                  didAddTrack: track,
                                  rtpReceiver: rtpReceiver,
                                  stream: streams.first!,
                                  subscriberId: currentTransportId)
            }
        }
    }

    func transport(_ transport: Transport, didRemoveTrack track: LKRTCMediaStreamTrack) {
        guard transport.target == _state.transport?.subscriber.target else { return }

        Task {
            await engine(self, didRemoveTrack: track)
        }
    }

    func transport(_ transport: Transport, didOpenDataChannel dataChannel: LKRTCDataChannel) {
        log("Server opened data channel \(dataChannel.label)(\(dataChannel.readyState))")

        guard transport.target == _state.transport?.subscriber.target else { return }

        switch dataChannel.label {
        case LKRTCDataChannel.Labels.reliable: subscriberDataChannel.set(reliable: dataChannel)
        case LKRTCDataChannel.Labels.lossy: subscriberDataChannel.set(lossy: dataChannel)
        default: log("Unknown data channel label \(dataChannel.label)", .warning)
        }
    }

    func transportShouldNegotiate(_: Transport) {}
}
