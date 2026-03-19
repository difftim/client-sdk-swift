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
import Security

/// Shared TLS trust evaluation logic for both WebSocket and QUIC connections.
/// When custom CA certificates are provided, they are injected as additional
/// trust anchors alongside the system trust store.
enum TLSHelper: Loggable {
    static func evaluate(
        trust: SecTrust,
        customCACertificates: [Data],
        insecureSkipTLSVerify: Bool = false,
        queue: DispatchQueue = .global(qos: .userInitiated),
        completion: @escaping (_ success: Bool, _ error: Error?) -> Void
    ) {
        if insecureSkipTLSVerify {
            log("TLS verification SKIPPED (insecureSkipTLSVerify=true)", .warning)
            completion(true, nil)
            return
        }

        if !customCACertificates.isEmpty {
            let secCerts: [SecCertificate] = customCACertificates.compactMap {
                SecCertificateCreateWithData(nil, $0 as CFData)
            }

            if secCerts.isEmpty {
                log("All provided CA certificates failed DER parsing", .error)
            } else {
                SecTrustSetAnchorCertificates(trust, secCerts as CFArray)
                // Trust both custom CAs and system CAs
                SecTrustSetAnchorCertificatesOnly(trust, false)
            }
        }

        SecTrustEvaluateAsyncWithError(trust, queue) { _, result, error in
            completion(result, error)
        }
    }
}
