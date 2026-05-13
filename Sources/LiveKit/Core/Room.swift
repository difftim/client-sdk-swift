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

// swiftlint:disable file_length

import Combine
import Foundation

#if canImport(Network)
import Network
#endif

@objcMembers
// swiftlint:disable:next type_body_length
public class Room: NSObject, @unchecked Sendable, ObservableObject, Loggable {
    // MARK: - MulticastDelegate

    public let delegates = MulticastDelegate<RoomDelegate>(label: "RoomDelegate")

    // MARK: - Metrics

    lazy var metricsManager = MetricsManager()

    // MARK: - Public

    /// Server assigned id of the Room.
    public var sid: Sid? { _state.sid }

    /// Server assigned id of the Room. *async* version of ``Room/sid``.
    public func sid() async throws -> Sid {
        try await _sidCompleter.wait()
    }

    /// Local identifier for this ``Room`` instance.
    ///
    /// This value is generated locally when the ``Room`` is created. Prefer ``sid`` or ``name`` when
    /// they are available; use ``localId`` only when a local fallback identifier is needed before
    /// server room information has been populated.
    public let localId = UUID().uuidString

    public var name: String? { _state.name }

    /// Room's metadata.
    public var metadata: String? { _state.metadata }

    public var serverVersion: String? { _state.serverInfo?.version.nilIfEmpty }

    /// Region code the client is currently connected to.
    public var serverRegion: String? { _state.serverInfo?.region.nilIfEmpty }

    /// Region code the client is currently connected to.
    public var serverNodeId: String? { _state.serverInfo?.nodeID.nilIfEmpty }

    public var remoteParticipants: [Participant.Identity: RemoteParticipant] { _state.remoteParticipants }

    public var activeSpeakers: [Participant] { _state.activeSpeakers }

    public var creationTime: Date? { _state.creationTime }

    /// If the current room has a participant with `recorder:true` in its JWT grant.
    public var isRecording: Bool { _state.isRecording }

    public var maxParticipants: Int { _state.maxParticipants }

    public var participantCount: Int { _state.numParticipants }

    public var publishersCount: Int { _state.numPublishers }

    /// User-provided URL.
    public var url: String? { _state.providedUrl?.absoluteString }

    /// Actual server URL used for the current connection (may include a regional URL).
    public var connectedUrl: String? { _state.connectedUrl?.absoluteString }

    public var token: String? { _state.token }

    /// Current ``ConnectionState`` of the ``Room``.
    public var connectionState: ConnectionState { _state.connectionState }

    public var disconnectError: LiveKitError? { _state.disconnectError }

    public var connectStopwatch: Stopwatch { _state.connectStopwatch }

    // MARK: - Internal

    private let _e2eeManager = StateSync<E2EEManager?>(nil)

    public var e2eeManager: E2EEManager? {
        get { _e2eeManager.copy() }
        set { _e2eeManager.mutate { $0 = newValue } }
    }

    public internal(set) var ttCallResp: Livekit_TTCallResponse?

    public lazy var localParticipant: LocalParticipant = .init(room: self)

    let primaryTransportConnectedCompleter = AsyncCompleter<Void>(label: "Primary transport connect", defaultTimeout: .defaultTransportState)
    let publisherTransportConnectedCompleter = AsyncCompleter<Void>(label: "Publisher transport connect", defaultTimeout: .defaultTransportState)

    let activeParticipantCompleters = CompleterMapActor<Void>(label: "Participant active", defaultTimeout: .defaultParticipantActiveTimeout)

    let signalClient = SignalClient()

    // MARK: - DataChannels

    lazy var subscriberDataChannel = DataChannelPair(delegate: self)
    lazy var publisherDataChannel = DataChannelPair(delegate: self)

    let incomingStreamManager = IncomingStreamManager()
    lazy var outgoingStreamManager = OutgoingStreamManager { [weak self] packet in
        try await self?.send(dataPacket: packet)
    } encryptionProvider: { [weak self] in
        self?.e2eeManager?.dataChannelEncryptionType ?? .none
    }

    // MARK: - PreConnect

    lazy var preConnectBuffer = PreConnectAudioBuffer(room: self)

    // MARK: - Queue

    var _blockProcessQueue = DispatchQueue(label: "LiveKitSDK.engine.pendingBlocks",
                                           qos: .default)

    var _queuedBlocks = [ConditionalExecutionEntry]()

    // MARK: - RPC

    let rpcState = RpcStateManager()

    // MARK: - State

    struct State: Equatable {
        // Options
        var connectOptions: ConnectOptions
        var roomOptions: RoomOptions

        var sid: Sid?
        var name: String?
        var metadata: String?

        var remoteParticipants = [Participant.Identity: RemoteParticipant]()
        var activeSpeakers = [Participant]()

        var creationTime: Date?
        var isRecording: Bool = false

        var maxParticipants: Int = 0
        var numParticipants: Int = 0
        var numPublishers: Int = 0

        var serverInfo: Livekit_ServerInfo?

        // Engine
        var providedUrl: URL?
        var connectedUrl: URL?
        var token: String?
        var preparedRegion: RegionInfo?

        // preferred reconnect mode which will be used only for next attempt
        var nextReconnectMode: ReconnectMode?
        var isReconnectingWithMode: ReconnectMode?
        var connectionState: ConnectionState = .disconnected
        // var reconnectTask: Task<Result<Void, LiveKitError>, Error>?
        var reconnectTask: AnyTaskCancellable?
        var isReconnectStartPending: Bool = false
        var pendingReconnectOnConnectivity: PendingReconnect?
        // Mirrored from `ConnectivityListener.shared.hasConnectivity` so that all
        // reconnect-scheduling decisions can read connectivity inside the same
        // `_state.mutate` block that performs the transition. Treat `nil` as
        // "unknown / allow", `false` as offline.
        var hasConnectivity: Bool?
        var disconnectError: LiveKitError?
        var connectStopwatch = Stopwatch(label: "connect")
        var hasPublished: Bool = false

        var publisher: Transport?
        var subscriber: Transport?
        var isSubscriberPrimary: Bool = false

        var serverNotifyDisconnect: Bool = false

        struct PendingReconnect: Equatable {
            var reason: StartReconnectReason
            var nextReconnectMode: ReconnectMode?

            // Manual `==` implemented via pattern matching so that
            // `StartReconnectReason` / `ReconnectMode` do NOT need to declare
            // public `Equatable` conformance just to satisfy the synthesis here.
            // (`State: Equatable` would otherwise force the cascade up to the
            // public enums.) Pattern matching works on case-only enums without
            // requiring `Equatable`.
            static func == (lhs: PendingReconnect, rhs: PendingReconnect) -> Bool {
                let reasonsEqual = switch (lhs.reason, rhs.reason) {
                case (.websocket, .websocket),
                     (.transport, .transport),
                     (.networkSwitch, .networkSwitch),
                     (.debug, .debug):
                    true
                default:
                    false
                }

                let modesEqual = switch (lhs.nextReconnectMode, rhs.nextReconnectMode) {
                case (nil, nil),
                     (.quick?, .quick?),
                     (.full?, .full?):
                    true
                default:
                    false
                }

                return reasonsEqual && modesEqual
            }
        }

        // Agents
        var transcriptionReceivedTimes: [String: Date] = [:]

        @discardableResult
        mutating func updateRemoteParticipant(info: Livekit_ParticipantInfo, room: Room, ignoreUpdate: Bool = false) -> RemoteParticipant {
            let identity = Participant.Identity(from: info.identity)

            // Check if RemoteParticipant with same identity exists...
            if let participant = remoteParticipants[identity] {
                if !ignoreUpdate {
                    participant.set(info: info, connectionState: connectionState)
                }
                return participant
            }

            // Create new RemoteParticipant...
            let participant = RemoteParticipant(info: info, room: room, connectionState: connectionState)
            remoteParticipants[identity] = participant
            return participant
        }

        // Find RemoteParticipant by Sid
        func remoteParticipant(forSid sid: Participant.Sid) -> RemoteParticipant? {
            remoteParticipants.values.first(where: { $0.sid == sid })
        }
    }

    let _state: StateSync<State>

    private let _sidCompleter = AsyncCompleter<Sid>(label: "sid", defaultTimeout: .resolveSid)
    private let _disconnectCompleter = AsyncCompleter<Void>(label: "disconnect", defaultTimeout: .defaultDisconnectCompletion)

    // MARK: - Region

    let _regionManager = StateSync<RegionManager?>(nil)

    // MARK: Objective-C Support

    override public convenience init() {
        self.init(delegate: nil,
                  connectOptions: ConnectOptions(),
                  roomOptions: RoomOptions())
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public init(delegate: RoomDelegate? = nil,
                connectOptions: ConnectOptions? = nil,
                roomOptions: RoomOptions? = nil)
    {
        // Ensure manager shared objects are instantiated
        DeviceManager.prepare()
        AudioManager.prepare()

        _state = StateSync(State(connectOptions: connectOptions ?? ConnectOptions(),
                                 roomOptions: roomOptions ?? RoomOptions()))

        super.init()
        // log sdk & os versions
        log("sdk: \(LiveKitSDK.version), ffi: \(LiveKitSDK.ffiVersion), os: \(String(describing: Utils.os()))(\(Utils.osVersionString())), modelId: \(String(describing: Utils.modelIdentifier() ?? "unknown"))")

        signalClient._delegate.set(delegate: self)

        log()

        if let delegate {
            log("delegate: \(String(describing: delegate))")
            delegates.add(delegate: delegate)
        }

        // listen to app states
        Task { @MainActor in
            AppStateListener.shared.delegates.add(delegate: self)
        }
        ConnectivityListener.shared.add(delegate: self)
        // Seed the mirror with whatever the listener already observed; subsequent
        // updates flow through `connectivityListener(_:didUpdate:)` /
        // `connectivityListener(_:didSwitch:)` below.
        _state.mutate { $0.hasConnectivity = ConnectivityListener.shared.hasConnectivity }

        Task {
            await metricsManager.register(room: self)
        }

        // trigger events when state mutates
        _state.onDidMutate = { [weak self] newState, oldState in
            guard let self else { return }

            // sid updated
            if let sid = newState.sid, sid != oldState.sid {
                // Resolve sid
                _sidCompleter.resume(returning: sid)
            }

            if case .connected = newState.connectionState {
                // metadata updated
                if let metadata = newState.metadata, metadata != oldState.metadata,
                   // don't notify if empty string (first time only)
                   oldState.metadata == nil ? !metadata.isEmpty : true
                {
                    delegates.notify(label: { "room.didUpdate metadata: \(metadata)" }) {
                        $0.room?(self, didUpdateMetadata: metadata)
                    }
                }

                // isRecording updated
                if newState.isRecording != oldState.isRecording {
                    delegates.notify(label: { "room.didUpdate isRecording: \(newState.isRecording)" }) {
                        $0.room?(self, didUpdateIsRecording: newState.isRecording)
                    }
                }
            }

            if newState.connectionState == .reconnecting, newState.isReconnectingWithMode == nil {
                log("reconnectMode should not be .none", .error)
            }

            if (newState.connectionState != oldState.connectionState) || (newState.isReconnectingWithMode != oldState.isReconnectingWithMode) {
                log("connectionState: \(oldState.connectionState) -> \(newState.connectionState), reconnectMode: \(String(describing: oldState.isReconnectingWithMode)) -> \(String(describing: newState.isReconnectingWithMode))")
            }

            engine(self, didMutateState: newState, oldState: oldState)

            // execution control
            _blockProcessQueue.async { [weak self] in
                guard let self, !self._queuedBlocks.isEmpty else { return }

                log("[execution control] processing pending entries (\(_queuedBlocks.count))...")

                _queuedBlocks.removeAll { entry in
                    // return and remove this entry if matches remove condition
                    guard !entry.removeCondition(newState, oldState) else { return true }
                    // return but don't remove this entry if doesn't match execute condition
                    guard entry.executeCondition(newState, oldState) else { return false }

                    self.log("[execution control] condition matching block...")
                    entry.block()
                    // remove this entry
                    return true
                }
            }

            // Notify Room when state mutates
            Task { @MainActor in
                self.objectWillChange.send()
            }
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public func connect(url urlString: String,
                        token: String,
                        connectOptions: ConnectOptions? = nil,
                        roomOptions: RoomOptions? = nil) async throws
    {
        guard let providedUrl = URL(string: urlString), providedUrl.isValidForConnect else {
            log("URL parse failed", .error)
            throw LiveKitError(.failedToParseUrl)
        }

        log("Connecting to room...", .info)

        var state = _state.copy()

        // update options if specified
        if let roomOptions, roomOptions != state.roomOptions {
            state = _state.mutate {
                $0.roomOptions = roomOptions
                return $0
            }
        }

        // update options if specified
        if let connectOptions, connectOptions != _state.connectOptions {
            _state.mutate { $0.connectOptions = connectOptions }
        }

        let preparedRegion = consumePreparedRegion(for: providedUrl)

        await cleanUp()

        try Task.checkCancellation()

        // enable E2EE
        if let e2eeOptions = state.roomOptions.e2eeOptions {
            e2eeManager = E2EEManager(e2eeOptions: e2eeOptions)
            e2eeManager!.setup(room: self)
        } else if let encryptionOptions = state.roomOptions.encryptionOptions {
            e2eeManager = E2EEManager(options: encryptionOptions)
            e2eeManager!.setup(room: self)

            subscriberDataChannel.e2eeManager = e2eeManager
            publisherDataChannel.e2eeManager = e2eeManager
        } else {
            e2eeManager = nil

            subscriberDataChannel.e2eeManager = nil
            publisherDataChannel.e2eeManager = nil
        }

        _state.mutate {
            $0.providedUrl = providedUrl
            $0.token = token
            $0.connectionState = .connecting
        }

        var nextUrl = providedUrl
        var nextRegion: RegionInfo?
        let regionManager = await regionManager(for: providedUrl)

        if providedUrl.isCloud {
            if let regionManager {
                await regionManager.resetAttempts(onlyIfExhausted: true)

                if let preparedRegion {
                    nextUrl = preparedRegion.url
                    nextRegion = preparedRegion
                } else if await regionManager.shouldRequestSettings() {
                    await regionManager.prepareSettingsFetch(token: token)
                }
            }
        }

        // Concurrent mic publish mode
        let enableMicrophone = _state.connectOptions.enableMicrophone
        log("Concurrent enable microphone mode: \(enableMicrophone)")

        let createMicrophoneTrackTask: Task<LocalTrack, any Error>? = if let recorder = preConnectBuffer.recorder, recorder.isRecording {
            Task {
                recorder.track
            }
        } else if enableMicrophone {
            Task {
                let localTrack = LocalAudioTrack.createTrack(options: _state.roomOptions.defaultAudioCaptureOptions,
                                                             reportStatistics: _state.roomOptions.reportRemoteTrackStatistics)
                // Initializes AudioDeviceModule's recording
                try await localTrack.start()
                return localTrack
            }
        } else {
            nil
        }

        do {
            let finalUrl: URL
            if providedUrl.isCloud {
                guard let regionManager else {
                    throw LiveKitError(.onlyForCloud)
                }

                finalUrl = try await connectWithCloudRegionFailover(regionManager: regionManager,
                                                                    initialUrl: nextUrl,
                                                                    initialRegion: nextRegion,
                                                                    token: token)
            } else {
                try await fullConnectSequence(nextUrl, token)
                finalUrl = nextUrl
            }

            // Connect sequence successful
            log("Connect sequence completed")
            // Final check if cancelled, don't fire connected events
            try Task.checkCancellation()

            _state.mutate {
                $0.connectedUrl = finalUrl

                // Only set token if server hasn't provided(refreashToken) one yet
                if $0.token == nil {
                    $0.token = token
                }

                $0.connectionState = .connected
            }
            // Publish mic if mic task was created
            if let createMicrophoneTrackTask, !createMicrophoneTrackTask.isCancelled {
                let track = try await createMicrophoneTrackTask.value
                try await localParticipant._publish(track: track, options: _state.roomOptions.defaultAudioPublishOptions.withPreconnect(preConnectBuffer.recorder?.isRecording ?? false))
            }
        } catch {
            log("Failed to resolve a region or connect: \(error)")
            // Stop the track if it was created but not published
            if let createMicrophoneTrackTask, !createMicrophoneTrackTask.isCancelled,
               case let .success(track) = await createMicrophoneTrackTask.result
            {
                try? await track.stop()
            }

            await cleanUp(withError: error)
            throw error // Re-throw the original error
        }

        log("Connected to \(String(describing: self))", .info)
    }

    public func disconnect() async {
        let disconnectId = UUID().uuidString
        var sw = Stopwatch(label: "disconnect")
        log("[disconnect]\(disconnectId): in", .info)
        enum DisconnectIntent {
            case start
            case wait
            case noOp
        }

        let intent = _state.mutate { state -> DisconnectIntent in
            switch state.connectionState {
            case .disconnecting:
                return .wait
            case .disconnected:
                return .noOp
            default:
                state.connectionState = .disconnecting
                return .start
            }
        }

        switch intent {
        case .wait:
            log("[disconnect]\(disconnectId): already in progress, waiting for completion", .info)
            do {
                try await _disconnectCompleter.wait()
            } catch {
                log("[disconnect]\(disconnectId): wait failed with error: \(error)", .warning)
            }
            log("[disconnect]\(disconnectId): waiting for completion success", .info)
            return
        case .noOp:
            log("[disconnect]\(disconnectId): skipped (already disconnected)", .info)
            return
        case .start:
            break
        }

        _disconnectCompleter.reset()

        defer {
            _disconnectCompleter.resume(returning: ())
        }

        cancelReconnect()

        do {
            try await signalClient.sendLeave()
        } catch {
            log("[disconnect]\(disconnectId): Failed to send leave with error: \(error)")
        }
        sw.split(label: "sendLeave")

        cancelReconnect()

        // must clean local info — single cleanUp call site for client-initiated disconnect
        await cleanUp(stopTrackCaptureImmediately: true)
        sw.split(label: "cleanUp")

        cancelReconnect()
        sw.split(label: "done")

        log("[disconnect]\(disconnectId): out \(sw.msDescription)", .info)
    }

    private func cancelReconnect() {
        _state.mutate {
            $0.reconnectTask = nil
        }
    }
}

// MARK: - Internal

extension Room {
    // Resets state of Room.
    //
    // Safety properties:
    //
    //   Non-throwing: Every operation is either synchronous or `async` (no `try`).
    //   CancellationError cannot interrupt the sequence mid-execution because
    //   there are no throwing suspension points (`try await`).
    //
    //   Idempotent: Socket close, timer cancel, completer reset, and state
    //   mutation to .disconnected are all safe to call multiple times. A second
    //   cleanUp() on an already-disconnected Room is a no-op in effect.
    //
    //   No re-entrancy risk: The subscribe() helper suppresses onFailure
    //   callbacks when Task.isCancelled is true (AsyncSequence+Subscribe:47),
    //   so cancelling the messageLoopTask inside cleanUp cannot trigger a
    //   recursive cleanUp call through the onFailure path.
    //
    // Cancellation contract — cleanUp() must NEVER be guarded by Task.isCancelled:
    //
    //   disconnect()
    //       cancelReconnect() ──► reconnectTask cancelled
    //       await cleanUp()   ──► runs in disconnect's own (non-cancelled) Task
    //
    //   startReconnect() catch
    //       if !Task.isCancelled ──► skips when reconnect was cancelled;
    //       await cleanUp()         caller (disconnect/new reconnect) owns cleanup
    //
    //   connect() catch
    //       await cleanUp()   ──► connect failed, clean up and re-throw
    //
    // @nonobjc is required: Room is @objcMembers, which causes async method
    // calls to create a new task context — silently breaking Task.isCancelled
    // propagation. This method is internal and never called from ObjC.
    @nonobjc func cleanUp(withError disconnectError: Error? = nil,
                          isFullReconnect: Bool = false,
                          stopTrackCaptureImmediately: Bool = false) async
    {
        log("withError: \(String(describing: disconnectError)), isFullReconnect: \(isFullReconnect), stopTrackCaptureImmediately: \(stopTrackCaptureImmediately)")

        // Reset completers
        _sidCompleter.reset()
        primaryTransportConnectedCompleter.reset()
        publisherTransportConnectedCompleter.reset()

        await signalClient.cleanUp(withError: disconnectError)

        // stop local track capture before cleaning up RTC, speeds up clean rtc process
        if stopTrackCaptureImmediately {
            await localParticipant.stopAllTrackCapture()
        }

        // Clean up sender-related resources (incl. encryption state) before tearing down RTC.
        // During reconnect local capture may still produce frames; tearing down RTC/cryptors first can cause callbacks to touch released objects and crash.
        // Cancel all track stats timers before closing transports to prevent
        // stats collection from accessing destroyed WebRTC channels.
        cancelTimers()

        // Cleanup for E2EE
        if let e2eeManager {
            log("[cleanup] e2eeManager.cleanUp begin")
            e2eeManager.cleanUp()
            log("[cleanup] e2eeManager.cleanUp end")
        }

        log("[cleanup] cleanUpParticipants begin")
        await cleanUpParticipants(isFullReconnect: isFullReconnect)
        log("[cleanup] cleanUpParticipants end")

        log("[cleanup] cleanUpRTC begin")
        await cleanUpRTC()
        log("[cleanup] cleanUpRTC end")

        // Reset state
        _state.mutate {
            // if isFullReconnect, keep connection related states
            $0 = isFullReconnect ? State(
                connectOptions: $0.connectOptions,
                roomOptions: $0.roomOptions,
                // remoteParticipants: removePar ? [:] : $0.remoteParticipants,
                providedUrl: $0.providedUrl,
                connectedUrl: $0.connectedUrl,
                token: $0.token,
                nextReconnectMode: $0.nextReconnectMode,
                isReconnectingWithMode: $0.isReconnectingWithMode,
                connectionState: $0.connectionState,
                reconnectTask: $0.reconnectTask,
                disconnectError: LiveKitError.from(error: disconnectError)
            ) : State(
                connectOptions: $0.connectOptions,
                roomOptions: $0.roomOptions,
                // remoteParticipants: removePar ? [:] : $0.remoteParticipants,
                connectionState: .disconnected,
                reconnectTask: $0.reconnectTask,
                disconnectError: LiveKitError.from(error: disconnectError)
            )
        }
    }

    private func cancelTimers() {
        for (_, participant) in allParticipants {
            for (_, publication) in participant._state.trackPublications {
                publication.track?.cancelStatisticsTimer()
            }
        }
    }
}

// MARK: - Internal

extension Room {
    func cleanUpParticipants(isFullReconnect: Bool = false, notify _notify: Bool = true) async {
        log("notify: \(_notify), isFullReconnect: \(isFullReconnect)")

        // Stop all local & remote tracks
        var allParticipants: [Participant] = Array(_state.remoteParticipants.values)
        if !isFullReconnect {
            allParticipants.append(localParticipant)
        }

        // Clean up Participants concurrently
        await withTaskGroup(of: Void.self) { group in
            for participant in allParticipants {
                group.addTask {
                    await participant.cleanUp(notify: _notify)
                }
            }

            await group.waitForAll()
        }

        _state.mutate {
            $0.remoteParticipants = [:]
        }
    }

    func _onParticipantDidDisconnect(identity: Participant.Identity) async throws {
        guard let participant = _state.mutate({ $0.remoteParticipants.removeValue(forKey: identity) }) else {
            throw LiveKitError(.invalidState, message: "Participant not found for \(identity)")
        }

        await participant.cleanUp(notify: true)
    }
}

// MARK: - Session Migration

extension Room {
    func resetTrackSettings() {
        log("resetting track settings...")

        // create an array of RemoteTrackPublication
        let remoteTrackPublications = _state.remoteParticipants.values.map {
            $0._state.trackPublications.values.compactMap { $0 as? RemoteTrackPublication }
        }.joined()

        // reset track settings for all RemoteTrackPublication
        for publication in remoteTrackPublications {
            publication.resetTrackSettings()
        }
    }
}

// MARK: - AppStateDelegate

extension Room: AppStateDelegate {
    func appDidEnterBackground() {
        guard _state.roomOptions.suspendLocalVideoTracksInBackground else { return }

        let cameraVideoTracks = localParticipant.localVideoTracks.filter { $0.source == .camera }

        guard !cameraVideoTracks.isEmpty else { return }

        Task.detached {
            for cameraVideoTrack in cameraVideoTracks {
                do {
                    try await cameraVideoTrack.suspend()
                } catch {
                    self.log("Failed to suspend video track with error: \(error)")
                }
            }
        }
    }

    func appWillEnterForeground() {
        let cameraVideoTracks = localParticipant.localVideoTracks.filter { $0.source == .camera }

        guard !cameraVideoTracks.isEmpty else { return }

        Task.detached {
            for cameraVideoTrack in cameraVideoTracks {
                do {
                    try await cameraVideoTrack.resume()
                } catch {
                    self.log("Failed to resumed video track with error: \(error)")
                }
            }
        }
    }

    func appWillTerminate() {
        // attempt to disconnect if already connected.
        // this is not guranteed since there is no reliable way to detect app termination.
        Task.detached {
            await self.disconnect()
        }
    }

    func appWillSleep() {
        Task.detached {
            await self.disconnect()
        }
    }

    func appDidWake() {}
}

// MARK: - ConnectivityListenerDelegate

extension Room: ConnectivityListenerDelegate {
    func connectivityListener(_: ConnectivityListener, didUpdate hasConnectivity: Bool) {
        // Snapshot the new value into `_state` first so any concurrent
        // `requestReconnect(...)` observes it under the same lock.
        _state.mutate { $0.hasConnectivity = hasConnectivity }

        guard hasConnectivity else {
            handleConnectivityLost()
            return
        }
        resumeReconnectAfterConnectivityRestored(source: "connectivity update",
                                                 restartInterface: ConnectivityListener.shared.path?.activeInterface)
    }

    func connectivityListener(_: ConnectivityListener, didSwitch path: NWPath) {
        guard path.isSatisfied() else {
            log("[reconnect][net] network switch ignored, path is not satisfied")
            return
        }

        // The listener has already updated `hasConnectivity` to true before
        // notifying didSwitch; mirror it explicitly so the reconnect decision
        // below sees a consistent view even if the prior `didUpdate` raced.
        _state.mutate { $0.hasConnectivity = true }

        guard !resumeReconnectAfterConnectivityRestored(source: "network switch",
                                                        restartInterface: path.activeInterface) else { return }

        requestReconnect(reason: .networkSwitch, restartInterface: path.activeInterface)
    }
}

// MARK: - Reconnect scheduling

extension Room {
    func handleConnectivityLost() {
        Task.detached { [weak self] in
            guard let self else { return }
            guard await signalClient.connectionState != .disconnected else { return }

            if _state.connectOptions.transportKind == .quic,
               !(await signalClient.isQuicMarkedUnhealthy),
               await signalClient.canRestartTransport()
            {
                log("[reconnect][net] connectivity lost with QUIC signal, deferring reconnect without closing signal transport")
                requestReconnect(reason: .networkSwitch)
                return
            }

            log("[reconnect][net] connectivity lost, closing signal transport")
            await signalClient.cleanUp(withError: LiveKitError(.network, message: "Connectivity lost"))
        }
    }

    @discardableResult
    func resumeReconnectAfterConnectivityRestored(source: String, restartInterface: NWInterface? = nil) -> Bool {
        let pendingReconnect = _state.mutate { state -> State.PendingReconnect? in
            guard state.connectionState == .connected,
                  state.isReconnectingWithMode == nil,
                  state.reconnectTask == nil,
                  !state.isReconnectStartPending,
                  let pendingReconnect = state.pendingReconnectOnConnectivity
            else {
                return nil
            }

            state.pendingReconnectOnConnectivity = nil
            return pendingReconnect
        }

        guard let pendingReconnect else { return false }

        log("[reconnect][net] connectivity restored from \(source), resuming pending reconnect, reason: \(pendingReconnect.reason)")
        requestReconnect(reason: pendingReconnect.reason,
                         nextReconnectMode: pendingReconnect.nextReconnectMode,
                         restartInterface: restartInterface)
        return true
    }

    func requestReconnect(reason: StartReconnectReason,
                          nextReconnectMode: ReconnectMode? = nil,
                          restartInterface: NWInterface? = nil)
    {
        // Single critical section that decides:
        //   - .start    : safe to launch a reconnect right now
        //   - .deferred : we're offline, stash a pending entry instead
        //   - .skip     : not eligible (not connected / already reconnecting)
        //
        // Reading `state.hasConnectivity` *inside* this same `_state.mutate`
        // block is the whole point — `ConnectivityListener` writes that field
        // through the same lock, so we cannot lose a `didUpdate(false)` that
        // races with this decision.
        enum Decision {
            case start
            case deferred
            case skip(String)
        }

        let decision = _state.mutate { state -> Decision in
            guard state.connectionState == .connected else {
                return .skip("not in connected state")
            }
            guard state.isReconnectingWithMode == nil,
                  state.reconnectTask == nil,
                  !state.isReconnectStartPending
            else {
                return .skip("reconnect already in progress or pending")
            }

            if state.hasConnectivity == false {
                // Offline: stash a pending entry. Merge policy:
                //  - reason: latest caller wins (transport disconnect arriving after a
                //    websocket failure is the more recent intent).
                //  - mode: any caller asking for `.full` upgrades the pending entry to
                //    `.full` and it stays there. A transport disconnect genuinely needs
                //    a full reconnect — we must not silently drop that signal just
                //    because we happened to be offline when it arrived.
                let pendingMode = state.pendingReconnectOnConnectivity?.nextReconnectMode
                let mergedMode: ReconnectMode? = (pendingMode == .full || nextReconnectMode == .full)
                    ? .full
                    : (pendingMode ?? nextReconnectMode)
                state.pendingReconnectOnConnectivity = State.PendingReconnect(
                    reason: reason,
                    nextReconnectMode: mergedMode
                )
                return .deferred
            }

            state.isReconnectStartPending = true
            state.pendingReconnectOnConnectivity = nil
            return .start
        }

        switch decision {
        case .start:
            log("[reconnect][net] starting reconnect, reason: \(reason)")
            Task.detached { [weak self] in
                guard let self else { return }
                defer {
                    self._state.mutate { $0.isReconnectStartPending = false }
                }

                do {
                    try await startReconnect(reason: reason,
                                             nextReconnectMode: nextReconnectMode,
                                             restartInterface: restartInterface)
                } catch {
                    log("[reconnect][net] failed to start reconnect, reason: \(reason), error: \(error)", .error)
                }
            }
        case .deferred:
            log("[reconnect][net] reconnect deferred until connectivity is restored, reason: \(reason)")
        case let .skip(why):
            log("[reconnect][net] reconnect ignored (\(why)), reason: \(reason)")
        }
    }
}

// MARK: - Devices

public extension Room {
    /// Set this to true to bypass initialization of voice processing.
    @available(*, deprecated, renamed: "AudioManager.shared.isVoiceProcessingBypassed")
    @objc
    static var bypassVoiceProcessing: Bool {
        get { AudioManager.shared.isVoiceProcessingBypassed }
        set { AudioManager.shared.isVoiceProcessingBypassed = newValue }
    }
}

// MARK: - DataChannelDelegate

extension Room: DataChannelDelegate {
    func dataChannel(_: DataChannelPair, didReceiveDataPacket dataPacket: Livekit_DataPacket) {
        switch dataPacket.value {
        case let .speaker(update): engine(self, didUpdateSpeakers: update.speakers)
        case let .user(userPacket): engine(self, didReceiveUserPacket: userPacket, encryptionType: dataPacket.encryptedPacket.encryptionType.toLKType())
        case let .transcription(packet): room(didReceiveTranscriptionPacket: packet)
        case let .rpcResponse(response): room(didReceiveRpcResponse: response)
        case let .rpcAck(ack): room(didReceiveRpcAck: ack)
        case let .rpcRequest(request): room(didReceiveRpcRequest: request, from: dataPacket.participantIdentity)
        case let .streamHeader(header):
            incomingStreamManager.handle(.header(header, dataPacket.participantIdentity, dataPacket.encryptedPacket.encryptionType.toLKType()))
        case let .streamChunk(chunk):
            incomingStreamManager.handle(.chunk(chunk, dataPacket.encryptedPacket.encryptionType.toLKType()))
        case let .streamTrailer(trailer):
            incomingStreamManager.handle(.trailer(trailer, dataPacket.encryptedPacket.encryptionType.toLKType()))
        default: return
        }
    }

    func dataChannel(_: DataChannelPair, didFailToDecryptDataPacket _: Livekit_DataPacket, error: LiveKitError) {
        delegates.notify {
            $0.room?(self, didFailToDecryptDataWithEror: error)
        }
    }
}
