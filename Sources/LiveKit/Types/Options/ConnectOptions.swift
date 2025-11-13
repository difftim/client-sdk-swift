/*
 * Copyright 2025 LiveKit
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

/// Options used when establishing a connection.
@objc
public final class ConnectOptions: NSObject, Sendable {
    /// Automatically subscribe to ``RemoteParticipant``'s tracks.
    /// Defaults to true.
    @objc
    public let autoSubscribe: Bool

    /// The number of attempts to reconnect when the network disconnects.
    @objc
    public let reconnectAttempts: Int

    /// The minimum delay value for reconnection attempts.
    /// Default is 0.3 seconds (TimeInterval.defaultReconnectDelay).
    ///
    /// This value serves as the starting point for the easeOutCirc reconnection curve.
    /// See `reconnectMaxDelay` for more details on how the reconnection delay is calculated.
    @objc
    public let reconnectAttemptDelay: TimeInterval

    /// The maximum delay between reconnect attempts.
    /// Default is 7 seconds (TimeInterval.defaultReconnectMaxDelay).
    ///
    /// The reconnection delay uses an "easeOutCirc" curve between reconnectAttemptDelay and reconnectMaxDelay:
    /// - For all attempts except the last, the delay follows this curve
    /// - The curve grows rapidly at first and then more gradually approaches the maximum
    /// - The last attempt always uses exactly reconnectMaxDelay
    ///
    /// Example for 10 reconnection attempts with baseDelay=0.3s and maxDelay=7s:
    /// - Attempt 0: ~0.85s (already 12% of the way to max)
    /// - Attempt 1: ~2.2s (30% of the way to max)
    /// - Attempt 2: ~3.4s (45% of the way to max)
    /// - Attempt 5: ~5.9s (82% of the way to max)
    /// - Attempt 9: 7.0s (exactly maxDelay)
    ///
    /// This approach provides larger delays early in the reconnection sequence to reduce
    /// unnecessary network traffic when connections are likely to fail.
    @objc
    public let reconnectMaxDelay: TimeInterval

    /// The timeout interval for the initial websocket connection.
    @objc
    public let socketConnectTimeoutInterval: TimeInterval

    @objc
    public let primaryTransportConnectTimeout: TimeInterval

    @objc
    public let publisherTransportConnectTimeout: TimeInterval

    /// Custom ice servers
    @objc
    public let iceServers: [IceServer]

    @objc
    public let iceTransportPolicy: IceTransportPolicy

    /// Enable microphone concurrently while connecting.
    @objc
    public let enableMicrophone: Bool

    /// LiveKit server protocol version to use. Generally, it's not recommended to change this.
    @objc
    public let protocolVersion: ProtocolVersion

    public let ttCallRequest: Livekit_TTCallRequest?

    @objc
    public let userAgent: String?

    // MARK: - Transport Selection

    /// The signaling transport to use when establishing the connection.
    /// Defaults to `.websocket`.
    ///
    /// QUIC is experimental and may not be available on all platforms or build configurations.
    /// When set to `.quic` but unsupported, the SDK will gracefully fall back to `.websocket`.
    public let transportKind: TransportKind

    @objc
    override public init() {
        autoSubscribe = true
        reconnectAttempts = 10
        reconnectAttemptDelay = .defaultReconnectDelay
        reconnectMaxDelay = .defaultReconnectMaxDelay
        socketConnectTimeoutInterval = .defaultSocketConnect
        primaryTransportConnectTimeout = .defaultTransportState
        publisherTransportConnectTimeout = .defaultTransportState
        iceServers = []
        iceTransportPolicy = .all
        enableMicrophone = false
        protocolVersion = .v12
        ttCallRequest = nil
        userAgent = nil
        transportKind = .websocket
    }

    @objc
    public init(autoSubscribe: Bool = true,
                reconnectAttempts: Int = 10,
                reconnectAttemptDelay: TimeInterval = .defaultReconnectDelay,
                reconnectMaxDelay: TimeInterval = .defaultReconnectMaxDelay,
                socketConnectTimeoutInterval: TimeInterval = .defaultSocketConnect,
                primaryTransportConnectTimeout: TimeInterval = .defaultTransportState,
                publisherTransportConnectTimeout: TimeInterval = .defaultTransportState,
                iceServers: [IceServer] = [],
                iceTransportPolicy: IceTransportPolicy = .all,
                enableMicrophone: Bool = false,
                protocolVersion: ProtocolVersion = .v12,
                userAgent: String? = nil,
                transportKind: TransportKind = .websocket)
    {
        self.autoSubscribe = autoSubscribe
        self.reconnectAttempts = reconnectAttempts
        self.reconnectAttemptDelay = reconnectAttemptDelay
        self.reconnectMaxDelay = max(reconnectMaxDelay, reconnectAttemptDelay)
        self.socketConnectTimeoutInterval = socketConnectTimeoutInterval
        self.primaryTransportConnectTimeout = primaryTransportConnectTimeout
        self.publisherTransportConnectTimeout = publisherTransportConnectTimeout
        self.iceServers = iceServers
        self.iceTransportPolicy = iceTransportPolicy
        self.enableMicrophone = enableMicrophone
        self.protocolVersion = protocolVersion
        ttCallRequest = nil
        self.userAgent = userAgent
        self.transportKind = transportKind
    }

    public init(autoSubscribe: Bool = true,
                reconnectAttempts: Int = 10,
                reconnectAttemptDelay: TimeInterval = .defaultReconnectDelay,
                reconnectMaxDelay: TimeInterval = .defaultReconnectMaxDelay,
                socketConnectTimeoutInterval: TimeInterval = .defaultSocketConnect,
                primaryTransportConnectTimeout: TimeInterval = .defaultTransportState,
                publisherTransportConnectTimeout: TimeInterval = .defaultTransportState,
                iceServers: [IceServer] = [],
                iceTransportPolicy: IceTransportPolicy = .all,
                enableMicrophone: Bool = false,
                protocolVersion: ProtocolVersion = .v12,
                ttCallRequest: Livekit_TTCallRequest? = nil,
                userAgent: String? = nil,
                transportKind: TransportKind = .websocket)
    {
        self.autoSubscribe = autoSubscribe
        self.reconnectAttempts = reconnectAttempts
        self.reconnectAttemptDelay = reconnectAttemptDelay
        self.reconnectMaxDelay = max(reconnectMaxDelay, reconnectAttemptDelay)
        self.socketConnectTimeoutInterval = socketConnectTimeoutInterval
        self.primaryTransportConnectTimeout = primaryTransportConnectTimeout
        self.publisherTransportConnectTimeout = publisherTransportConnectTimeout
        self.iceServers = iceServers
        self.iceTransportPolicy = iceTransportPolicy
        self.enableMicrophone = enableMicrophone
        self.protocolVersion = protocolVersion
        self.ttCallRequest = ttCallRequest
        self.userAgent = userAgent
        self.transportKind = transportKind
    }

    // MARK: - Equal

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return autoSubscribe == other.autoSubscribe &&
            reconnectAttempts == other.reconnectAttempts &&
            reconnectAttemptDelay == other.reconnectAttemptDelay &&
            reconnectMaxDelay == other.reconnectMaxDelay &&
            socketConnectTimeoutInterval == other.socketConnectTimeoutInterval &&
            primaryTransportConnectTimeout == other.primaryTransportConnectTimeout &&
            publisherTransportConnectTimeout == other.publisherTransportConnectTimeout &&
            iceServers == other.iceServers &&
            iceTransportPolicy == other.iceTransportPolicy &&
            enableMicrophone == other.enableMicrophone &&
            protocolVersion == other.protocolVersion &&
            ttCallRequest == other.ttCallRequest &&
            userAgent == other.userAgent &&
            transportKind == other.transportKind
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(autoSubscribe)
        hasher.combine(reconnectAttempts)
        hasher.combine(reconnectAttemptDelay)
        hasher.combine(reconnectMaxDelay)
        hasher.combine(socketConnectTimeoutInterval)
        hasher.combine(primaryTransportConnectTimeout)
        hasher.combine(publisherTransportConnectTimeout)
        hasher.combine(iceServers)
        hasher.combine(iceTransportPolicy)
        hasher.combine(enableMicrophone)
        hasher.combine(protocolVersion)
        hasher.combine(transportKind)
        return hasher.finalize()
    }
}

// MARK: - TransportKind

/// Signaling transport kinds supported by the Swift SDK.
/// WebSocket is the stable default; QUIC is experimental.
@objc
public enum TransportKind: Int, Sendable {
    case websocket
    case quic

    /// Returns true if this kind requires runtime OS features only available iOS 15+/macOS 12+.
    public var requiresModernOS: Bool {
        switch self {
        case .websocket: false
        case .quic: true
        }
    }
}
