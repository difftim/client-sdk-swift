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

/// Options used when establishing a connection.
@objcMembers
public final class IceServer: NSObject, Sendable {
    /// TLS certificate policy for `turns:` (TURN-over-TLS) servers.
    @objc
    public enum TlsCertPolicy: Int, Sendable {
        /// Verify the server certificate (default). Combine with
        /// ``ConnectOptions/sslCertificateVerifier`` to pin a self-signed cert.
        case secure
        /// Skip certificate verification (insecure; not recommended).
        case insecureNoCheck
    }

    public let urls: [String]
    public let username: String?
    public let credential: String?
    public let tlsCertPolicy: TlsCertPolicy

    public init(urls: [String],
                username: String?,
                credential: String?,
                tlsCertPolicy: TlsCertPolicy = .secure)
    {
        self.urls = urls
        self.username = username
        self.credential = credential
        self.tlsCertPolicy = tlsCertPolicy
    }
}

extension IceServer {
    func toRTCType() -> LKRTCIceServer {
        DispatchQueue.liveKitWebRTC.sync { LKRTCIceServer(urlStrings: urls,
                                                          username: username,
                                                          credential: credential,
                                                          tlsCertPolicy: tlsCertPolicy.toRTCType()) }
    }
}

extension IceServer.TlsCertPolicy {
    func toRTCType() -> LKRTCTlsCertPolicy {
        switch self {
        case .secure: .secure
        case .insecureNoCheck: .insecureNoCheck
        }
    }
}

extension Livekit_ICEServer {
    func toRTCType() -> LKRTCIceServer {
        let rtcUsername = !username.isEmpty ? username : nil
        let rtcCredential = !credential.isEmpty ? credential : nil
        return DispatchQueue.liveKitWebRTC.sync { LKRTCIceServer(urlStrings: urls,
                                                                 username: rtcUsername,
                                                                 credential: rtcCredential) }
    }
}
