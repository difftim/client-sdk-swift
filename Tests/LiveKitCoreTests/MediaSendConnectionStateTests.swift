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

@testable import LiveKit
import Testing

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
        isReconnectingWithMode: ReconnectMode? = nil,
        publisherPC: PC?
    ) -> MediaSendConnectionState {
        Room.computeMediaSendConnectionState(
            connectionState: connectionState,
            isSubscriberPrimary: isSubscriberPrimary,
            hasPublished: hasPublished,
            isReconnectingWithMode: isReconnectingWithMode,
            publisherPCStateRaw: publisherPC?.rawValue
        )
    }

    @Test func idleWhenDisconnected() {
        #expect(compute(connectionState: .disconnected, hasPublished: true, publisherPC: .failed) == .idle)
        #expect(compute(connectionState: .disconnecting, hasPublished: true, publisherPC: .connected) == .idle)
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
    }

    @Test func connectedWhenPublisherReady() {
        #expect(compute(connectionState: .connected, hasPublished: true, publisherPC: .connected) == .connected)
    }

    @Test func recoveringOnTransientDisconnectOrRoomReconnect() {
        #expect(compute(connectionState: .connected, hasPublished: true, publisherPC: .disconnected) == .recovering)
        #expect(compute(connectionState: .reconnecting, hasPublished: true, publisherPC: .connected) == .recovering)
        #expect(compute(
            connectionState: .connected,
            hasPublished: true,
            isReconnectingWithMode: .quick,
            publisherPC: .connected
        ) == .recovering)
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
            publisherPC: nil
        ) == .connected)

        #expect(compute(
            connectionState: .connected,
            isSubscriberPrimary: false,
            hasPublished: true,
            isReconnectingWithMode: .full,
            publisherPC: .failed
        ) == .recovering)

        #expect(compute(
            connectionState: .connecting,
            isSubscriberPrimary: false,
            hasPublished: true,
            publisherPC: .connecting
        ) == .connecting)

        #expect(compute(
            connectionState: .connecting,
            isSubscriberPrimary: false,
            hasPublished: false,
            publisherPC: nil
        ) == .idle)
    }

    @Test func demoWarningCondition() {
        func shouldWarn(room: ConnectionState, send: MediaSendConnectionState) -> Bool {
            room == .connected && send != .idle && send != .connected
        }

        #expect(!shouldWarn(room: .connected, send: .idle))
        #expect(!shouldWarn(room: .connected, send: .connected))
        #expect(shouldWarn(room: .connected, send: .connecting))
        #expect(shouldWarn(room: .connected, send: .recovering))
        #expect(shouldWarn(room: .connected, send: .failed))
        #expect(!shouldWarn(room: .connecting, send: .failed))
        #expect(!shouldWarn(room: .reconnecting, send: .recovering))
    }
}
