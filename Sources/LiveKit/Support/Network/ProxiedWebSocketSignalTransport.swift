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

import CryptoKit
import Foundation
import Network
import Security

// MARK: - Signaling proxy descriptor

/// A resolved self-hosted signaling proxy (shared by the QUIC MASQUE path and the
/// WebSocket TLS-in-TLS tunnel). Derived from the `ConnectOptions.quicProxy*` fields.
struct SignalingProxyDescriptor: Sendable {
    /// Proxy host the client dials (typically an IP literal in Mode B).
    let host: String
    /// Outer TLS port (the stealth front uses 443).
    let port: Int
    /// Non-empty decoy SNI for the OUTER handshake (camouflage; the 443 front routes a
    /// hostname SNI to the signaling terminator, an IP/empty SNI to the media listener).
    let decoySni: String
    /// base64(SHA-256(DER SubjectPublicKeyInfo)) of the proxy leaf cert. When set, the
    /// outer hop is SPKI-pinned instead of CA-verified (Mode B self-signed proxy).
    let spkiPin: String?
    /// Optional outer-hop (proxy) CA in PEM, used when no SPKI pin is supplied.
    let outerCaPem: String?

    /// Default decoy SNI when none is configured (never the bare IP host).
    static let defaultDecoySni = "www.bing.com"
}

extension ConnectOptions {
    /// The signaling proxy resolved from the `quicProxy*` fields, or `nil` when no proxy
    /// host/url is configured. Used by both the QUIC MASQUE transport and the WebSocket
    /// TLS-in-TLS tunnel so a single proxy config covers either signaling transport.
    var resolvedSignalingProxy: SignalingProxyDescriptor? {
        var host = quicProxyHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var port = quicProxyPort

        if host.isEmpty, let rawUrl = quicProxyUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !rawUrl.isEmpty {
            // Accept "masque://host:port", "https://host:port", or bare "host:port".
            let withoutScheme = rawUrl.range(of: "://").map { String(rawUrl[$0.upperBound...]) } ?? rawUrl
            let authority = withoutScheme.split(separator: "/", maxSplits: 1).first.map(String.init) ?? withoutScheme
            if authority.hasPrefix("[") , let close = authority.firstIndex(of: "]") {
                host = String(authority[authority.index(after: authority.startIndex) ..< close])
                let rest = authority[authority.index(after: close)...]
                if rest.hasPrefix(":"), let p = Int(rest.dropFirst()) { port = p }
            } else if let colon = authority.lastIndex(of: ":") {
                host = String(authority[authority.startIndex ..< colon])
                port = Int(authority[authority.index(after: colon)...]) ?? port
            } else {
                host = authority
            }
        }

        guard !host.isEmpty else { return nil }
        let resolvedPort = port > 0 ? port : 443
        let sni = quicProxySni?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pin = quicProxySpkiPin?.trimmingCharacters(in: .whitespacesAndNewlines)
        let outerCa = quicProxyCaCertPem?.trimmingCharacters(in: .whitespacesAndNewlines)

        return SignalingProxyDescriptor(
            host: host,
            port: resolvedPort,
            decoySni: (sni?.isEmpty == false) ? sni! : SignalingProxyDescriptor.defaultDecoySni,
            spkiPin: (pin?.isEmpty == false) ? pin : nil,
            outerCaPem: (outerCa?.isEmpty == false) ? outerCa : nil
        )
    }
}

// MARK: - SignalTransport wrapper

/// WebSocket signaling transport that tunnels through a self-hosted TLS-in-TLS proxy:
/// TCP → outer TLS (SPKI-pinned, decoy SNI) → inner TLS (real SNI + `caCertPem`) → an
/// RFC 6455 WebSocket spoken over the inner stream. Used when a signaling proxy is
/// configured and the chosen signaling transport is WebSocket (direct or QUIC→WS fallback).
///
/// `URLSessionWebSocketTask` cannot dial through a custom TLS-in-TLS socket, so this path
/// is implemented directly on `NWConnection` + a minimal WebSocket framer.
actor ProxiedWebSocketSignalTransport: SignalTransport {
    typealias Element = URLSessionWebSocketTask.Message
    nonisolated let transportKind: TransportKind = .websocket

    private let engine: ProxiedWebSocketEngine

    init(innerURL: URL,
         token: String,
         proxy: SignalingProxyDescriptor,
         connectOptions: ConnectOptions?,
         sendAfterOpen: Data?) async throws
    {
        engine = ProxiedWebSocketEngine(
            innerURL: innerURL,
            token: token,
            proxy: proxy,
            innerCaPem: connectOptions?.caCertPem,
            userAgent: connectOptions?.userAgent,
            timeout: connectOptions?.socketConnectTimeoutInterval ?? .defaultSocketConnect
        )
        try await engine.connect()
        if let sendAfterOpen { try? await engine.send(data: sendAfterOpen) }
    }

    nonisolated func send(data: Data) async throws {
        try await engine.send(data: data)
    }

    nonisolated func close() {
        engine.close()
    }

    // MARK: - AsyncSequence

    struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate let engine: ProxiedWebSocketEngine

        func next() async throws -> URLSessionWebSocketTask.Message? {
            try await withTaskCancellationHandler {
                try await engine.nextMessage()
            } onCancel: {
                engine.close()
            }
        }
    }

    nonisolated func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(engine: engine)
    }
}

// MARK: - Engine (NWConnection tunnel + WebSocket framing)

/// Owns the `NWConnection` (TLS-in-TLS) and a hand-rolled RFC 6455 client. Thread-safe via
/// `StateSync`; callbacks from Network.framework are funneled into continuation-driven async.
private final class ProxiedWebSocketEngine: Loggable, @unchecked Sendable {
    private let innerURL: URL
    private let token: String
    private let proxy: SignalingProxyDescriptor
    private let innerCaPem: String?
    private let userAgent: String?
    private let timeout: TimeInterval

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "livekit.proxied-websocket")
    private let wsAcceptKey: String

    private struct State {
        var rxBuffer = Data() // raw bytes off the inner TLS stream (handshake then frames)
        var handshakeDone = false
        var assembling = Data() // fragmented message reassembly
        var assemblingOpcode: UInt8 = 0
        var messages: [URLSessionWebSocketTask.Message] = []
        var messageContinuation: CheckedContinuation<URLSessionWebSocketTask.Message?, Error>?
        var failure: Error?
        var finished = false
    }

    private let _state = StateSync(State())

    init(innerURL: URL, token: String, proxy: SignalingProxyDescriptor,
         innerCaPem: String?, userAgent: String?, timeout: TimeInterval)
    {
        self.innerURL = innerURL
        self.token = token
        self.proxy = proxy
        self.innerCaPem = innerCaPem
        self.userAgent = userAgent
        self.timeout = timeout

        var keyBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, keyBytes.count, &keyBytes)
        wsAcceptKey = Data(keyBytes).base64EncodedString()

        let innerHost = innerURL.host ?? proxy.host
        let params = ProxiedWebSocketEngine.makeParameters(
            proxy: proxy,
            innerHost: innerHost,
            innerCaPem: innerCaPem,
            verifyQueue: queue
        )
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(proxy.host),
            port: NWEndpoint.Port(rawValue: UInt16(proxy.port)) ?? 443
        )
        connection = NWConnection(to: endpoint, using: params)
    }

    // MARK: - Connect

    func connect() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.startConnectionAndHandshake() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.timeout * 1_000_000_000))
                throw LiveKitError(.timedOut, message: "proxied websocket connect timed out")
            }
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                close()
                throw error
            }
        }
    }

    private func startConnectionAndHandshake() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    sendHandshake(continuation: continuation)
                case let .failed(error):
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: LiveKitError(.network, message: "proxy tunnel failed: \(error)"))
                case let .waiting(error):
                    log("proxied websocket waiting: \(error)", .warning)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    /// Build the TLS-in-TLS + (no WS protocol) NWParameters. WebSocket framing is handled
    /// manually over the inner TLS plaintext, so we only stack two TLS layers here.
    private static func makeParameters(proxy: SignalingProxyDescriptor,
                                       innerHost: String,
                                       innerCaPem: String?,
                                       verifyQueue: DispatchQueue) -> NWParameters
    {
        let tcp = NWProtocolTCP.Options()
        let params = NWParameters(tls: nil, tcp: tcp)

        // Capture only Sendable values (Strings); parse certificates inside the verify
        // blocks so no non-Sendable SecCertificate/SecTrust crosses a concurrency boundary.
        let spkiPin = proxy.spkiPin
        let outerCaPem = proxy.outerCaPem

        // OUTER TLS (client ↔ proxy): decoy SNI + SPKI pin / optional CA / Mode-B accept.
        let outer = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(outer.securityProtocolOptions, proxy.decoySni)
        sec_protocol_options_set_verify_block(outer.securityProtocolOptions, { _, secTrust, complete in
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
            if let pin = spkiPin, !pin.isEmpty {
                complete(Self.leafSpkiMatches(trust: trust, expectedPin: pin))
            } else if let pem = outerCaPem, let anchors = CertificateTrustEvaluator.certificates(fromPEM: pem), !anchors.isEmpty {
                complete(Self.evaluate(trust: trust, anchors: anchors, host: nil))
            } else {
                // Mode B: self-signed proxy, no pin/CA → accept the outer hop.
                complete(true)
            }
        }, verifyQueue)

        // INNER TLS (client ↔ SFU): real SNI + caCertPem anchors (or system default).
        let inner = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(inner.securityProtocolOptions, innerHost)
        sec_protocol_options_set_verify_block(inner.securityProtocolOptions, { _, secTrust, complete in
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
            if let pem = innerCaPem, let anchors = CertificateTrustEvaluator.certificates(fromPEM: pem), !anchors.isEmpty {
                complete(Self.evaluate(trust: trust, anchors: anchors, host: innerHost))
            } else {
                var err: CFError?
                complete(SecTrustEvaluateWithError(trust, &err))
            }
        }, verifyQueue)

        // Stack order: applicationProtocols index 0 = top (closest to app).
        // Result: TCP → outer TLS → inner TLS.
        params.defaultProtocolStack.applicationProtocols.insert(outer, at: 0)
        params.defaultProtocolStack.applicationProtocols.insert(inner, at: 0)
        return params
    }

    // MARK: - WebSocket handshake

    private func sendHandshake(continuation: CheckedContinuation<Void, Error>) {
        let host = innerURL.host ?? proxy.host
        var pathAndQuery = innerURL.path.isEmpty ? "/" : innerURL.path
        if let q = innerURL.query, !q.isEmpty { pathAndQuery += "?\(q)" }

        var lines = [
            "GET \(pathAndQuery) HTTP/1.1",
            "Host: \(host)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(wsAcceptKey)",
            "Sec-WebSocket-Version: 13",
        ]
        if !token.isEmpty { lines.append("Authorization: Bearer \(token)") }
        if let ua = userAgent, !ua.isEmpty { lines.append("User-Agent: \(ua)") }
        let request = lines.joined(separator: "\r\n") + "\r\n\r\n"

        connection.send(content: Data(request.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                continuation.resume(throwing: LiveKitError(.network, message: "ws handshake send failed: \(error)"))
                return
            }
            receiveHandshakeResponse(continuation: continuation)
        })
    }

    private func receiveHandshakeResponse(continuation: CheckedContinuation<Void, Error>) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                continuation.resume(throwing: LiveKitError(.network, message: "ws handshake recv failed: \(error)"))
                return
            }
            if let data, !data.isEmpty {
                _state.mutate { $0.rxBuffer.append(data) }
            }
            let headerEnd = _state.read { $0.rxBuffer.range(of: Data("\r\n\r\n".utf8)) }
            guard let headerEnd else {
                if isComplete {
                    continuation.resume(throwing: LiveKitError(.network, message: "ws handshake closed early"))
                    return
                }
                receiveHandshakeResponse(continuation: continuation)
                return
            }

            let (headerData, leftover): (Data, Data) = _state.mutate {
                let header = $0.rxBuffer.subdata(in: $0.rxBuffer.startIndex ..< headerEnd.upperBound)
                let rest = $0.rxBuffer.subdata(in: headerEnd.upperBound ..< $0.rxBuffer.endIndex)
                $0.rxBuffer = Data()
                return (header, rest)
            }

            guard Self.isValidHandshake(headerData, expectedKey: wsAcceptKey) else {
                continuation.resume(throwing: LiveKitError(.network, message: "ws upgrade rejected"))
                return
            }

            _state.mutate {
                $0.handshakeDone = true
                $0.rxBuffer = leftover
            }
            continuation.resume()
            // Parse any frame bytes that arrived with the handshake, then keep reading.
            drainFrames()
            receiveLoop()
        }
    }

    private static func isValidHandshake(_ header: Data, expectedKey: String) -> Bool {
        guard let text = String(data: header, encoding: .utf8) else { return false }
        let lower = text.lowercased()
        guard lower.contains(" 101 ") || lower.hasPrefix("http/1.1 101") else { return false }
        // RFC 6455 §1.3: the server's Sec-WebSocket-Accept must equal
        // base64(SHA-1(Sec-WebSocket-Key + WS_GUID)). WS_GUID is the fixed magic value
        // mandated by the spec (not arbitrary). URLSession/OkHttp hide this because they
        // perform the upgrade internally; we validate it ourselves since the handshake is
        // hand-rolled over the tunnel.
        let wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let accept = Data(Insecure.SHA1.hash(data: Data((expectedKey + wsGUID).utf8))).base64EncodedString()
        return lower.contains("sec-websocket-accept: \(accept.lowercased())")
    }

    // MARK: - Receive loop + framing

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                fail(LiveKitError(.network, message: "proxied websocket recv error: \(error)"))
                return
            }
            if let data, !data.isEmpty {
                _state.mutate { $0.rxBuffer.append(data) }
                drainFrames()
            }
            if isComplete {
                finishStream()
                return
            }
            receiveLoop()
        }
    }

    /// Extract as many complete RFC 6455 frames as the buffer holds.
    private func drainFrames() {
        while true {
            let frame: (fin: Bool, opcode: UInt8, payload: Data)? = _state.mutate { state in
                Self.parseFrame(&state.rxBuffer)
            }
            guard let frame else { return }
            handleFrame(fin: frame.fin, opcode: frame.opcode, payload: frame.payload)
        }
    }

    /// Parse a single frame from the front of `buffer` (server→client frames are unmasked).
    /// Returns nil and leaves the buffer intact when a full frame is not yet available.
    private static func parseFrame(_ buffer: inout Data) -> (fin: Bool, opcode: UInt8, payload: Data)? {
        guard buffer.count >= 2 else { return nil }
        let bytes = [UInt8](buffer)
        let b0 = bytes[0]
        let b1 = bytes[1]
        let fin = (b0 & 0x80) != 0
        let opcode = b0 & 0x0F
        let masked = (b1 & 0x80) != 0
        var len = Int(b1 & 0x7F)
        var offset = 2

        if len == 126 {
            guard bytes.count >= 4 else { return nil }
            len = (Int(bytes[2]) << 8) | Int(bytes[3])
            offset = 4
        } else if len == 127 {
            guard bytes.count >= 10 else { return nil }
            len = 0
            for i in 2 ..< 10 { len = (len << 8) | Int(bytes[i]) }
            offset = 10
        }

        var maskKey: [UInt8] = []
        if masked {
            guard bytes.count >= offset + 4 else { return nil }
            maskKey = Array(bytes[offset ..< offset + 4])
            offset += 4
        }

        guard bytes.count >= offset + len else { return nil }
        var payload = Array(bytes[offset ..< offset + len])
        if masked {
            for i in 0 ..< payload.count { payload[i] ^= maskKey[i % 4] }
        }

        let consumed = offset + len
        buffer.removeFirst(consumed)
        return (fin, opcode, Data(payload))
    }

    private func handleFrame(fin: Bool, opcode: UInt8, payload: Data) {
        switch opcode {
        case 0x0, 0x1, 0x2: // continuation / text / binary
            _state.mutate { state in
                if opcode != 0x0 {
                    state.assembling = Data()
                    state.assemblingOpcode = opcode
                }
                state.assembling.append(payload)
                guard fin else { return }
                let complete = state.assembling
                let op = state.assemblingOpcode
                state.assembling = Data()
                let message: URLSessionWebSocketTask.Message = (op == 0x1)
                    ? .string(String(data: complete, encoding: .utf8) ?? "")
                    : .data(complete)
                deliver(message, into: &state)
            }
        case 0x9: // ping → pong
            sendFrame(opcode: 0xA, payload: payload)
        case 0xA: // pong
            break
        case 0x8: // close
            finishStream()
        default:
            break
        }
    }

    private func deliver(_ message: URLSessionWebSocketTask.Message, into state: inout State) {
        if let continuation = state.messageContinuation {
            state.messageContinuation = nil
            continuation.resume(returning: message)
        } else {
            state.messages.append(message)
        }
    }

    // MARK: - Send

    func send(data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sendFrame(opcode: 0x2, payload: data) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Build and send a client frame (always masked per RFC 6455).
    private func sendFrame(opcode: UInt8, payload: Data, completion: (@Sendable (Error?) -> Void)? = nil) {
        var frame = Data()
        frame.append(0x80 | opcode) // FIN + opcode
        let len = payload.count
        if len < 126 {
            frame.append(0x80 | UInt8(len))
        } else if len <= 0xFFFF {
            frame.append(0x80 | 126)
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((len >> shift) & 0xFF))
            }
        }
        var mask = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, 4, &mask)
        frame.append(contentsOf: mask)
        var masked = [UInt8](payload)
        for i in 0 ..< masked.count { masked[i] ^= mask[i % 4] }
        frame.append(contentsOf: masked)

        connection.send(content: frame, completion: .contentProcessed { error in
            completion?(error.map { LiveKitError(.network, message: "proxied websocket send failed: \($0)") })
        })
    }

    // MARK: - Async message delivery

    func nextMessage() async throws -> URLSessionWebSocketTask.Message? {
        let immediate: Result<URLSessionWebSocketTask.Message?, Error>? = _state.mutate { state in
            if let error = state.failure { state.failure = nil; return .failure(error) }
            if !state.messages.isEmpty { return .success(state.messages.removeFirst()) }
            if state.finished { return .success(nil) }
            return nil
        }
        if let immediate { return try immediate.get() }

        return try await withCheckedThrowingContinuation { continuation in
            _state.mutate { state in
                if let error = state.failure {
                    state.failure = nil
                    continuation.resume(throwing: error)
                } else if !state.messages.isEmpty {
                    continuation.resume(returning: state.messages.removeFirst())
                } else if state.finished {
                    continuation.resume(returning: nil)
                } else {
                    state.messageContinuation = continuation
                }
            }
        }
    }

    private func fail(_ error: Error) {
        _state.mutate { state in
            guard !state.finished else { return }
            state.finished = true
            if let continuation = state.messageContinuation {
                state.messageContinuation = nil
                continuation.resume(throwing: error)
            } else {
                state.failure = error
            }
        }
        connection.cancel()
    }

    private func finishStream() {
        _state.mutate { state in
            guard !state.finished else { return }
            state.finished = true
            state.messageContinuation?.resume(returning: nil)
            state.messageContinuation = nil
        }
        connection.cancel()
    }

    func close() {
        finishStream()
    }

    // MARK: - TLS verification helpers

    /// SPKI pin: SHA-256 of the leaf certificate's DER SubjectPublicKeyInfo, base64-compared.
    private static func leafSpkiMatches(trust: SecTrust, expectedPin: String) -> Bool {
        guard let leaf = leafCertificate(trust),
              let der = SecCertificateCopyData(leaf) as Data?,
              let spki = SPKIExtractor.subjectPublicKeyInfo(fromCertificateDER: der)
        else { return false }
        let pin = Data(SHA256.hash(data: spki)).base64EncodedString()
        return normalizePin(pin) == normalizePin(expectedPin)
    }

    private static func evaluate(trust: SecTrust, anchors: [SecCertificate], host: String?) -> Bool {
        if let host, !host.isEmpty {
            return CertificateTrustEvaluator.evaluateServerTrust(trust, host: host, anchorCertificates: anchors)
        }
        // No hostname (decoy outer hop): anchors-only with basic X.509 policy.
        let policy = SecPolicyCreateBasicX509()
        guard SecTrustSetPolicies(trust, policy) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess
        else { return false }
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }

    private static func leafCertificate(_ trust: SecTrust) -> SecCertificate? {
        if #available(iOS 15.0, macOS 12.0, tvOS 15.0, visionOS 1.0, *) {
            return (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
        } else {
            return SecTrustGetCertificateAtIndex(trust, 0)
        }
    }

    private static func normalizePin(_ s: String) -> String {
        s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "=", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - SPKI extraction (minimal ASN.1 DER walk)

/// Extracts the DER `SubjectPublicKeyInfo` from an X.509 certificate DER. The SPKI pin is
/// SHA-256 over this exact substructure (matches Android/JS pin generation).
enum SPKIExtractor {
    static func subjectPublicKeyInfo(fromCertificateDER der: Data) -> Data? {
        let bytes = [UInt8](der)
        var index = 0
        // Certificate ::= SEQUENCE { tbsCertificate SEQUENCE { ... }, ... }
        guard let cert = readSequence(bytes, &index) else { return nil }
        var tbsIndex = cert.contentStart
        guard let tbs = readSequence(bytes, &tbsIndex), tbs.contentStart <= bytes.count else { return nil }

        var i = tbs.contentStart
        let tbsEnd = tbs.contentStart + tbs.length
        // tbsCertificate fields (in order):
        //  [0] version (optional, context tag 0xA0), serialNumber (INTEGER),
        //  signature (SEQ), issuer (SEQ), validity (SEQ), subject (SEQ),
        //  subjectPublicKeyInfo (SEQ) <-- the 7th element (or 6th if version absent).
        // Walk elements; the SPKI is the first SEQUENCE that appears after exactly
        // 3 prior SEQUENCEs (signature, issuer, validity, subject ... ) — to stay robust
        // we count top-level elements and pick the SPKI by position.
        var elementCount = 0
        // Skip optional [0] version.
        if i < tbsEnd, bytes[i] == 0xA0 {
            guard let v = readTLV(bytes, &i) else { return nil }
            i = v.contentStart + v.length
        }
        // Now: serialNumber, signature, issuer, validity, subject, subjectPublicKeyInfo
        // Indices after version: 0 serial, 1 signature, 2 issuer, 3 validity, 4 subject, 5 SPKI
        while i < tbsEnd {
            let elemStart = i
            guard let tlv = readTLV(bytes, &i) else { return nil }
            if elementCount == 5 {
                // subjectPublicKeyInfo: return the full TLV (header + content).
                let end = tlv.contentStart + tlv.length
                guard end <= bytes.count else { return nil }
                return Data(bytes[elemStart ..< end])
            }
            i = tlv.contentStart + tlv.length
            elementCount += 1
        }
        return nil
    }

    private struct TLV { let contentStart: Int; let length: Int }

    private static func readSequence(_ bytes: [UInt8], _ index: inout Int) -> TLV? {
        guard index < bytes.count, bytes[index] == 0x30 else { return nil }
        return readTLV(bytes, &index)
    }

    /// Reads a DER TLV header at `index`, returning the content start offset and length.
    /// Leaves `index` pointing at the tag (does not advance past content).
    private static func readTLV(_ bytes: [UInt8], _ index: inout Int) -> TLV? {
        var i = index
        guard i < bytes.count else { return nil }
        i += 1 // tag
        guard i < bytes.count else { return nil }
        let first = bytes[i]; i += 1
        var length = 0
        if first & 0x80 == 0 {
            length = Int(first)
        } else {
            let numBytes = Int(first & 0x7F)
            guard numBytes > 0, numBytes <= 4, i + numBytes <= bytes.count else { return nil }
            for _ in 0 ..< numBytes { length = (length << 8) | Int(bytes[i]); i += 1 }
        }
        return TLV(contentStart: i, length: length)
    }
}
