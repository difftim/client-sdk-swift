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

/// Options used when establishing a connection.
@objcMembers
public final class ConnectOptions: NSObject, Sendable {
    /// Automatically subscribe to ``RemoteParticipant``'s tracks.
    /// Defaults to true.
    public let autoSubscribe: Bool

    /// The number of attempts to reconnect when the network disconnects.
    public let reconnectAttempts: Int

    /// The minimum delay value for reconnection attempts.
    /// Default is 0.3 seconds (TimeInterval.defaultReconnectDelay).
    ///
    /// This value serves as the starting point for the easeOutCirc reconnection curve.
    /// See `reconnectMaxDelay` for more details on how the reconnection delay is calculated.
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
    public let reconnectMaxDelay: TimeInterval

    /// The timeout interval for the initial websocket connection.
    public let socketConnectTimeoutInterval: TimeInterval

    public let primaryTransportConnectTimeout: TimeInterval

    public let publisherTransportConnectTimeout: TimeInterval

    /// Custom ice servers
    public let iceServers: [IceServer]

    public let iceTransportPolicy: IceTransportPolicy

    /// Allows DSCP codes to be set on outgoing packets when network priority is used.
    /// Defaults to false.
    public let isDscpEnabled: Bool

    /// Enable microphone concurrently while connecting.
    public let enableMicrophone: Bool

    /// LiveKit server protocol version to use. Generally, it's not recommended to change this.
    public let protocolVersion: ProtocolVersion

    public let ttCallRequest: Livekit_TTCallRequest?

    public let userAgent: String?

    // MARK: - Transport Selection

    /// The signaling transport to use when establishing the connection.
    /// Defaults to `.websocket`.
    ///
    /// QUIC is experimental and may not be available on all platforms or build configurations.
    /// When set to `.quic` but unsupported, the SDK will gracefully fall back to `.websocket`.
    public let transportKind: TransportKind

    // MARK: - QUIC signaling (ttsignal)

    /// Device type for QUIC signaling (e.g. 1 = phone, 2 = PC). Only used when the transport kind is QUIC.
    public let quicDeviceType: Int

    /// Connection ID tag for QUIC signaling. Only used when the transport kind is QUIC.
    public let quicCidTag: String

    /// Root CA certificate(s) in PEM format for TLS verification when the server chain is signed by a non-public CA.
    ///
    /// When `nil` or empty:
    /// - **WebSocket** uses the system trust store only.
    /// - **QUIC** uses the ttsignal stack default verification.
    ///
    /// When non-empty:
    /// - **WebSocket** validates the server certificate chain against these anchors only (hostname checks still apply
    ///   for the URL host). Malformed PEM fails the WebSocket connection before the TLS handshake starts.
    /// - **QUIC** passes the PEM to the ttsignal stack for custom CA and IP-direct scenarios.
    public let caCertPem: String?

    /// Logical hostname for TLS SNI and certificate hostname checks when the signaling URL host is an IP literal.
    ///
    /// `SignalTransportFactory` may rewrite the WebSocket URL host from the IP to this value when both `caCertPem`
    /// and `serverHost` are set, so TLS hostname verification matches the certificate (aligned with Android
    /// QUIC-to-WebSocket fallback). For domain-based WebSocket URLs, this field is ignored.
    public let serverHost: String?

    // MARK: - QUIC-over-proxy (MASQUE CONNECT-UDP)

    /// Per-connection outbound proxy for the QUIC signaling transport (RFC 9298 CONNECT-UDP / MASQUE).
    /// When set, the QUIC connection is tunnelled through the proxy. Only used when ``transportKind`` is `.quic`.
    /// A raw proxy URL or the split host/port fields may be supplied.
    ///
    /// - Note: Requires an iOS `ttsignal` build with CONNECT-UDP support; ignored otherwise.
    /// - Note: The WebSocket signaling path uses ``webSocketProxyHost`` / ``webSocketProxyPort`` instead.
    public let quicProxyUrl: String?
    public let quicProxyHost: String?
    public let quicProxyPort: Int
    public let quicProxySni: String?

    /// Outer-hop (proxy) CA certificate in PEM format, separate from the inner SFU ``caCertPem``. When empty, the
    /// proxy certificate is accepted unverified (acceptable for a self-signed Mode-B proxy on a trusted path);
    /// supply this to enforce verification of the proxy's TLS certificate.
    public let quicProxyCaCertPem: String?

    /// Outer-hop (proxy) SPKI pin: base64 SHA-256 of the proxy leaf's SubjectPublicKeyInfo. When set, the
    /// QUIC-over-proxy OUTER hop pins the proxy's TLS certificate to this value (the same pin used for the
    /// TURN-TLS relay), instead of CA-chain verification. The inner connection (client↔SFU) is unaffected and
    /// keeps verifying via ``caCertPem``.
    public let quicProxySpkiPin: String?

    // MARK: - WebSocket-over-proxy (HTTP CONNECT to a local tunnel)

    /// HTTP CONNECT proxy host applied to the **WebSocket** signaling URLSession via
    /// `URLSessionConfiguration.connectionProxyDictionary`. Typically the app's loopback
    /// TLS-in-TLS tunnel (e.g. `127.0.0.1`); the tunnel performs the outer (camouflage/pinned)
    /// TLS to the remote proxy, while URLSession performs the inner TLS to the SFU (still pinned
    /// via ``caCertPem``) transparently — i.e. TLS-in-TLS without the SDK opening a custom socket.
    ///
    /// When set together with ``webSocketProxyPort`` (> 0), the WebSocket transport (direct and the
    /// QUIC→WebSocket fallback) routes through this CONNECT proxy. The value is snapshotted when the
    /// socket is built, so pass the current tunnel endpoint on each connect. Only affects WebSocket
    /// signaling; QUIC uses the `quicProxy*` fields above.
    ///
    /// - Important: `URLSessionWebSocketTask` only honors `connectionProxyDictionary` on **iOS 17+**.
    ///   On iOS 15/16 it is silently ignored and the WebSocket connects directly (verified empirically:
    ///   iOS 26 tunnels, iOS 15.8 does not). To proxy signaling on older iOS, use QUIC (`quicProxy*`),
    ///   which tunnels natively via ttsignal MASQUE and does not depend on URLSession.
    public let webSocketProxyHost: String?

    /// HTTP CONNECT proxy port for ``webSocketProxyHost``. `0` (default) disables WebSocket-over-proxy.
    public let webSocketProxyPort: Int

    /// Custom verifier for the TURN-TLS (transport) certificate of an ICE relay server, enabling SPKI certificate
    /// pinning of the outer `turns:` TLS layer (e.g. a self-hosted, self-signed coturn used as a media relay/proxy).
    ///
    /// When provided, the media `PeerConnection` is constructed so the native stack invokes
    /// ``SSLCertificateVerifier/verify(certificate:)`` with the peer leaf certificate (X.509 DER) during the
    /// TURN TLS handshake. When `nil`, the default behavior is used and no custom verification is performed.
    ///
    /// Pair with an ``IceServer`` whose `tlsCertPolicy` is `.secure` (the default) and ``iceTransportPolicy`` `.relay`
    /// to force relay-only media through the operator's TURN server. Media itself stays DTLS-SRTP end-to-end; this only
    /// hardens the TURN transport-camouflage TLS.
    @nonobjc
    public let sslCertificateVerifier: (any SSLCertificateVerifier)?

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
        isDscpEnabled = false
        enableMicrophone = false
        protocolVersion = .v16
        ttCallRequest = nil
        userAgent = nil
        transportKind = .websocket
        quicDeviceType = 0
        quicCidTag = ""
        caCertPem = nil
        serverHost = nil
        quicProxyUrl = nil
        quicProxyHost = nil
        quicProxyPort = 0
        quicProxySni = nil
        quicProxyCaCertPem = nil
        quicProxySpkiPin = nil
        webSocketProxyHost = nil
        webSocketProxyPort = 0
        sslCertificateVerifier = nil
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
                isDscpEnabled: Bool = false,
                enableMicrophone: Bool = false,
                protocolVersion: ProtocolVersion = .v16,
                ttCallRequest: Livekit_TTCallRequest? = nil,
                userAgent: String? = nil,
                transportKind: TransportKind = .websocket,
                quicDeviceType: Int = 0,
                quicCidTag: String = "",
                caCertPem: String? = nil,
                serverHost: String? = nil,
                quicProxyUrl: String? = nil,
                quicProxyHost: String? = nil,
                quicProxyPort: Int = 0,
                quicProxySni: String? = nil,
                quicProxyCaCertPem: String? = nil,
                quicProxySpkiPin: String? = nil,
                webSocketProxyHost: String? = nil,
                webSocketProxyPort: Int = 0,
                sslCertificateVerifier: (any SSLCertificateVerifier)? = nil)
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
        self.isDscpEnabled = isDscpEnabled
        self.enableMicrophone = enableMicrophone
        self.protocolVersion = protocolVersion
        self.ttCallRequest = ttCallRequest
        self.userAgent = userAgent
        self.transportKind = transportKind
        self.quicDeviceType = quicDeviceType
        self.quicCidTag = quicCidTag
        self.caCertPem = caCertPem
        self.serverHost = serverHost
        self.quicProxyUrl = quicProxyUrl
        self.quicProxyHost = quicProxyHost
        self.quicProxyPort = quicProxyPort
        self.quicProxySni = quicProxySni
        self.quicProxyCaCertPem = quicProxyCaCertPem
        self.quicProxySpkiPin = quicProxySpkiPin
        self.webSocketProxyHost = webSocketProxyHost
        self.webSocketProxyPort = webSocketProxyPort
        self.sslCertificateVerifier = sslCertificateVerifier
    }

    // MARK: - Equal
    // Note: `sslCertificateVerifier` is intentionally excluded from `isEqual`/`hash`
    // (it is a non-Hashable closure-like verifier; identity is not meaningful for
    // option equality/caching).

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
            isDscpEnabled == other.isDscpEnabled &&
            enableMicrophone == other.enableMicrophone &&
            protocolVersion == other.protocolVersion &&
            ttCallRequest == other.ttCallRequest &&
            userAgent == other.userAgent &&
            transportKind == other.transportKind &&
            quicDeviceType == other.quicDeviceType &&
            quicCidTag == other.quicCidTag &&
            caCertPem == other.caCertPem &&
            serverHost == other.serverHost &&
            quicProxyUrl == other.quicProxyUrl &&
            quicProxyHost == other.quicProxyHost &&
            quicProxyPort == other.quicProxyPort &&
            quicProxySni == other.quicProxySni &&
            quicProxyCaCertPem == other.quicProxyCaCertPem &&
            quicProxySpkiPin == other.quicProxySpkiPin &&
            webSocketProxyHost == other.webSocketProxyHost &&
            webSocketProxyPort == other.webSocketProxyPort
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
        hasher.combine(isDscpEnabled)
        hasher.combine(enableMicrophone)
        hasher.combine(protocolVersion)
        hasher.combine(ttCallRequest)
        hasher.combine(userAgent)
        hasher.combine(transportKind)
        hasher.combine(quicDeviceType)
        hasher.combine(quicCidTag)
        hasher.combine(caCertPem)
        hasher.combine(serverHost)
        hasher.combine(quicProxyUrl)
        hasher.combine(quicProxyHost)
        hasher.combine(quicProxyPort)
        hasher.combine(quicProxySni)
        hasher.combine(quicProxyCaCertPem)
        hasher.combine(quicProxySpkiPin)
        hasher.combine(webSocketProxyHost)
        hasher.combine(webSocketProxyPort)
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
}
