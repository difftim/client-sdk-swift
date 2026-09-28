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

#if os(iOS)
import TTSignal

extension TTSignalHttpConnector: @unchecked Sendable {}
#endif

public struct PhysicalHTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
    public let peerIP: String
    public let boundInterfaceIndex: UInt32
    public let pinMethod: String
}

public struct PhysicalHTTPError: Error, Sendable {
    public let result: Int32
    public let name: String?
    public let message: String?
}

/// A reusable HTTP client that forces requests onto a physical interface.
///
/// This transport is available on iOS. Callers should fall back to their
/// existing HTTP stack when initialization or a request fails.
public actor PhysicalHTTPClient {
    #if os(iOS)
    private var connector: TTSignalHttpConnector?
    #endif

    public init?(caCertificatePEM: String? = nil,
                 drainTimeoutMilliseconds: UInt32 = 5000)
    {
        #if os(iOS)
        var config = TTSignalHttpConfig()
        config.net.vpnPolicy = .forcePhysical
        config.net.drainTimeoutMs = drainTimeoutMilliseconds
        if let caCertificatePEM {
            config.net.caCerts = caCertificatePEM
        }
        guard let connector = TTSignalHttpConnector(config: config) else {
            return nil
        }
        self.connector = connector
        #else
        return nil
        #endif
    }

    public func request(method: String = "GET",
                        url: URL,
                        headers: [String: String] = [:],
                        body: Data? = nil,
                        timeoutMilliseconds: UInt32 = 8000) async throws -> PhysicalHTTPResponse
    {
        #if os(iOS)
        guard let connector else {
            throw PhysicalHTTPError(
                result: -1,
                name: "BC_R_SHUTTINGDOWN",
                message: "Physical HTTP connector is closed",
            )
        }
        do {
            let response = try await connector.request(
                method: method,
                url: url.absoluteString,
                headers: headers,
                body: body,
                timeoutMs: timeoutMilliseconds,
            )
            return PhysicalHTTPResponse(
                status: Int(response.status),
                headers: response.headers,
                body: response.body,
                peerIP: response.peerIp,
                boundInterfaceIndex: response.boundIfIndex,
                pinMethod: response.pinMethod,
            )
        } catch let error as TTSignalError {
            throw PhysicalHTTPError(
                result: error.result,
                name: error.errName,
                message: error.errMessage,
            )
        }
        #else
        throw PhysicalHTTPError(
            result: -1,
            name: "BC_R_NOTIMPLEMENTED",
            message: "Physical HTTP is only available on iOS",
        )
        #endif
    }

    public func close() async {
        #if os(iOS)
        guard let connector else { return }
        self.connector = nil
        await connector.close()
        #endif
    }
}
