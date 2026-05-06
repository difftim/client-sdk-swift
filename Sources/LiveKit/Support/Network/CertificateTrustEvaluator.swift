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

/// Parses PEM-encoded X.509 certificates and evaluates ``SecTrust`` for WebSocket TLS.
enum CertificateTrustEvaluator {
    /// Parses one or more PEM `CERTIFICATE` blocks into ``SecCertificate`` instances.
    /// - Returns: `nil` if [pem] is empty after trimming, or no valid certificate blocks were found.
    static func certificates(fromPEM pem: String) -> [SecCertificate]? {
        let trimmed = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let beginMarker = "-----BEGIN CERTIFICATE-----"
        let endMarker = "-----END CERTIFICATE-----"
        var result: [SecCertificate] = []
        var searchStart = trimmed.startIndex

        while let beginRange = trimmed.range(of: beginMarker, range: searchStart ..< trimmed.endIndex) {
            let afterBegin = beginRange.upperBound
            guard let endRange = trimmed.range(of: endMarker, range: afterBegin ..< trimmed.endIndex) else {
                break
            }

            let base64Body = trimmed[afterBegin ..< endRange.lowerBound]
                .replacingOccurrences(of: "\r", with: "")
                .components(separatedBy: .newlines)
                .map { $0.filter { !$0.isWhitespace } }
                .joined()

            guard !base64Body.isEmpty,
                  let der = Data(base64Encoded: base64Body, options: [.ignoreUnknownCharacters]),
                  let cert = SecCertificateCreateWithData(nil, der as CFData)
            else {
                return nil
            }

            result.append(cert)
            searchStart = endRange.upperBound
        }

        return result.isEmpty ? nil : result
    }

    /// Evaluates [serverTrust] using SSL policy for [host] and custom anchor certificates only.
    static func evaluateServerTrust(_ serverTrust: SecTrust, host: String, anchorCertificates: [SecCertificate]) -> Bool {
        guard !anchorCertificates.isEmpty else { return false }

        let hostCF: CFString? = host.isEmpty ? nil : host as CFString
        let policy = SecPolicyCreateSSL(true, hostCF)
        let policies: [SecPolicy] = [policy]
        guard SecTrustSetPolicies(serverTrust, policies as CFArray) == errSecSuccess else {
            return false
        }

        guard SecTrustSetAnchorCertificates(serverTrust, anchorCertificates as CFArray) == errSecSuccess else {
            return false
        }

        guard SecTrustSetAnchorCertificatesOnly(serverTrust, true) == errSecSuccess else {
            return false
        }

        var error: CFError?
        return SecTrustEvaluateWithError(serverTrust, &error)
    }
}
