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

/// Custom verifier for the TURN-TLS (transport) certificate of an ICE relay
/// server, enabling SPKI certificate pinning of the outer `turns:` TLS layer.
///
/// When provided via ``ConnectOptions/sslCertificateVerifier``, the underlying
/// WebRTC stack invokes ``verify(certificate:)`` with the peer leaf certificate
/// (X.509 DER) during the TURN TLS handshake. Returning `false` rejects the
/// connection.
///
/// Unlike ``ConnectOptions/caCertPem`` (which verifies the **signaling**
/// transport), this applies to the **media** TURN PeerConnection transport.
/// Media itself stays DTLS-SRTP end-to-end; this only hardens the TURN
/// transport-camouflage TLS.
///
/// - Important: The implementation must be fast, non-blocking, and must never
///   throw — it runs on a WebRTC network thread once per TURN-TLS handshake.
public protocol SSLCertificateVerifier: Sendable {
    /// Verify the peer leaf certificate (X.509 DER). Return `true` to accept.
    func verify(certificate: Data) -> Bool
}
