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

struct RoomMediaUnreachableTests {
    @Test func mediaUnreachableHasStableRawValue() {
        #expect(LiveKitErrorType.mediaUnreachable.rawValue == 2002)
    }

    @Test func transportTimeoutBecomesMediaUnreachable() {
        let error = Room.mediaUnreachableError(from: LiveKitError(.timedOut), transport: "publisher", elapsed: 15)
        let lkError = error as? LiveKitError
        #expect(lkError?.type == .mediaUnreachable)
        #expect(lkError?.message == "publisher transport not connected after 15000ms")
    }

    @Test func transportFailedBecomesMediaUnreachable() {
        let failed = LiveKitError(.network, message: "Transport subscriber state changed to failed")
        let error = Room.mediaUnreachableError(from: failed, transport: "primary", elapsed: 1.2)
        #expect((error as? LiveKitError)?.type == .mediaUnreachable)
    }

    @Test func cancellationIsPreserved() {
        let lk = Room.mediaUnreachableError(from: LiveKitError(.cancelled), transport: "primary", elapsed: 0)
        #expect((lk as? LiveKitError)?.type == .cancelled)
        let task = Room.mediaUnreachableError(from: CancellationError(), transport: "primary", elapsed: 0)
        #expect(task is CancellationError)
    }

    @Test func nonTransportErrorIsPreserved() {
        let wrapped = LiveKitError(.invalidState)
        let error = Room.mediaUnreachableError(from: wrapped, transport: "primary", elapsed: 1)
        #expect((error as? LiveKitError)?.type == .invalidState)
    }

    @Test(arguments: [LiveKitErrorType.roomDeleted, .participantRemoved, .duplicateIdentity, .serverShutdown, .joinFailure])
    func serverDisconnectIsPreserved(type: LiveKitErrorType) {
        let error = Room.mediaUnreachableError(from: LiveKitError(type), transport: "primary", elapsed: 1)
        #expect((error as? LiveKitError)?.type == type)

        let waitError = Room.initialConnectWaitError(from: LiveKitError(type), isSignalConnected: false, terminalLeaveError: nil, transport: "primary", elapsed: 1)
        #expect((waitError as? LiveKitError)?.type == type)
    }

    @Test func nonLiveKitFailureBecomesMediaUnreachable() {
        struct SomeError: Error {}
        let error = Room.mediaUnreachableError(from: SomeError(), transport: "primary", elapsed: 1)
        #expect((error as? LiveKitError)?.type == .mediaUnreachable)
    }

    @Test func waitFailureWithSignalLostBecomesRetryableNetworkError() {
        for source in [LiveKitError(.timedOut), LiveKitError(.network, message: "Transport subscriber state changed to failed"), Room.initialConnectSignalLostError] {
            let error = Room.initialConnectWaitError(from: source, isSignalConnected: false, terminalLeaveError: nil, transport: "primary", elapsed: 1)
            let lkError = error as? LiveKitError
            #expect(lkError?.type == .network)
            #expect(lkError?.message == "signal lost during initial connect")
            #expect(error.isRetryableForRegionFailover)
        }
    }

    @Test func waitFailureWithSignalConnectedBecomesMediaUnreachable() {
        let timeout = Room.initialConnectWaitError(from: LiveKitError(.timedOut), isSignalConnected: true, terminalLeaveError: nil, transport: "publisher", elapsed: 15)
        #expect((timeout as? LiveKitError)?.type == .mediaUnreachable)
        let failed = Room.initialConnectWaitError(from: LiveKitError(.network, message: "Transport publisher state changed to closed"),
                                                  isSignalConnected: true, terminalLeaveError: nil, transport: "publisher", elapsed: 2)
        #expect((failed as? LiveKitError)?.type == .mediaUnreachable)
    }

    @Test func waitCancellationIsPreservedEvenWithSignalLost() {
        let lk = Room.initialConnectWaitError(from: LiveKitError(.cancelled), isSignalConnected: false, terminalLeaveError: nil, transport: "primary", elapsed: 0)
        #expect((lk as? LiveKitError)?.type == .cancelled)
        let task = Room.initialConnectWaitError(from: CancellationError(), isSignalConnected: false, terminalLeaveError: nil, transport: "primary", elapsed: 0)
        #expect(task is CancellationError)
    }

    @Test func recordedTerminalLeaveWinsOverSignalLost() {
        let leave = LiveKitError(.duplicateIdentity)
        for source in [LiveKitError(.timedOut), Room.initialConnectSignalLostError] {
            let error = Room.initialConnectWaitError(from: source, isSignalConnected: false, terminalLeaveError: leave,
                                                     transport: "primary", elapsed: 1)
            #expect((error as? LiveKitError)?.type == .duplicateIdentity)
        }
        #expect(Room.initialConnectSignalLossError(terminalLeaveError: leave).type == .duplicateIdentity)
    }

    @Test func noTerminalLeaveFallsBackToSignalLost() {
        let error = Room.initialConnectWaitError(from: LiveKitError(.timedOut), isSignalConnected: false, terminalLeaveError: nil,
                                                 transport: "primary", elapsed: 1)
        #expect((error as? LiveKitError)?.message == "signal lost during initial connect")
        #expect(Room.initialConnectSignalLossError(terminalLeaveError: nil).message == "signal lost during initial connect")
    }

    @Test func terminalLeaveClassification() {
        func leave(_ action: Livekit_LeaveRequest.Action, _ reason: Livekit_DisconnectReason, canReconnect: Bool = false) -> Livekit_LeaveRequest {
            .with {
                $0.action = action
                $0.reason = reason
                $0.canReconnect = canReconnect
            }
        }
        #expect(SignalClient.terminalLeaveError(for: leave(.disconnect, .duplicateIdentity))?.type == .duplicateIdentity)
        #expect(SignalClient.terminalLeaveError(for: leave(.disconnect, .roomDeleted))?.type == .roomDeleted)
        #expect(SignalClient.terminalLeaveError(for: leave(.disconnect, .roomDeleted, canReconnect: true)) == nil)
        #expect(SignalClient.terminalLeaveError(for: leave(.disconnect, .stateMismatch)) == nil)
        #expect(SignalClient.terminalLeaveError(for: leave(.resume, .roomDeleted)) == nil)
        #expect(SignalClient.terminalLeaveError(for: leave(.reconnect, .roomDeleted)) == nil)
    }

    @Test func onlyTerminalLeaveIsRecorded() async {
        let signalClient = Room().signalClient
        #expect(await signalClient.terminalLeaveError == nil)

        func response(_ action: Livekit_LeaveRequest.Action, _ reason: Livekit_DisconnectReason) -> Livekit_SignalResponse {
            .with {
                $0.leave = .with {
                    $0.action = action
                    $0.reason = reason
                }
            }
        }

        await signalClient.recordTerminalLeave(from: response(.resume, .roomDeleted))
        #expect(await signalClient.terminalLeaveError == nil)

        await signalClient.recordTerminalLeave(from: response(.disconnect, .participantRemoved))
        #expect(await signalClient.terminalLeaveError?.type == .participantRemoved)
    }

    @Test func transportConnectTimeoutsDefaultTo10Seconds() {
        #expect(TimeInterval.defaultTransportState == 10)
        #expect(ConnectOptions().primaryTransportConnectTimeout == 10)
        #expect(ConnectOptions().publisherTransportConnectTimeout == 10)
    }

    @Test func initialConnectTransportTimeoutIs15Seconds() {
        #expect(TimeInterval.initialConnectTransportTimeout == 15)
    }

    @Test func connectResetsQuicUnhealthyMarker() async {
        let room = Room()
        await room.signalClient.markQuicUnhealthyIfFallback(requestedKind: .quic, actualKind: .websocket)
        #expect(await room.signalClient.isQuicMarkedUnhealthy)

        try? await room.connect(url: "not a url", token: "")

        #expect(await room.signalClient.isQuicMarkedUnhealthy == false)
    }
}
