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

/// Bridges the public ``SSLCertificateVerifier`` to the WebRTC ObjC
/// `LKRTCSSLCertificateVerifier` protocol so it can be passed to
/// `peerConnection(with:constraints:certificateVerifier:delegate:)`.
final class RTCSSLCertificateVerifierAdapter: NSObject, LKRTCSSLCertificateVerifier {
    private let verifier: any SSLCertificateVerifier

    init(_ verifier: any SSLCertificateVerifier) {
        self.verifier = verifier
    }

    func verify(_ derCertificate: Data) -> Bool {
        verifier.verify(certificate: derCertificate)
    }
}
