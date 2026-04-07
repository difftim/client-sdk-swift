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

/// Scalability modes for SVC codecs (VP9, AV1).
///
/// The naming convention follows the WebRTC standard: `L{spatial}T{temporal}{suffix}`.
/// - SeeAlso: [WebRTC SVC Extension](https://www.w3.org/TR/webrtc-svc/)
@objc
public enum ScalabilityMode: Int, Sendable {
    case L1T1 = 1
    case L1T2 = 2
    case L1T3 = 3
    case L2T1 = 4
    case L2T1h = 5
    case L2T1_KEY = 6
    case L2T2 = 7
    case L2T2h = 8
    case L2T2_KEY = 9
    case L2T3 = 10
    case L2T3h = 11
    case L2T3_KEY = 12
    case L3T1 = 13
    case L3T1h = 14
    case L3T1_KEY = 15
    case L3T2 = 16
    case L3T2h = 17
    case L3T2_KEY = 18
    case L3T3 = 19
    case L3T3h = 20
    case L3T3_KEY = 21
    case L3T3_KEY_SHIFT = 22
}

public extension ScalabilityMode {
    static func fromString(_ rawString: String?) -> ScalabilityMode? {
        guard let rawString else { return nil }
        switch rawString {
        case "L1T1": return .L1T1
        case "L1T2": return .L1T2
        case "L1T3": return .L1T3
        case "L2T1": return .L2T1
        case "L2T1h": return .L2T1h
        case "L2T1_KEY": return .L2T1_KEY
        case "L2T2": return .L2T2
        case "L2T2h": return .L2T2h
        case "L2T2_KEY": return .L2T2_KEY
        case "L2T3": return .L2T3
        case "L2T3h": return .L2T3h
        case "L2T3_KEY": return .L2T3_KEY
        case "L3T1": return .L3T1
        case "L3T1h": return .L3T1h
        case "L3T1_KEY": return .L3T1_KEY
        case "L3T2": return .L3T2
        case "L3T2h": return .L3T2h
        case "L3T2_KEY": return .L3T2_KEY
        case "L3T3": return .L3T3
        case "L3T3h": return .L3T3h
        case "L3T3_KEY": return .L3T3_KEY
        case "L3T3_KEY_SHIFT": return .L3T3_KEY_SHIFT
        default: return nil
        }
    }

    var rawStringValue: String {
        switch self {
        case .L1T1: "L1T1"
        case .L1T2: "L1T2"
        case .L1T3: "L1T3"
        case .L2T1: "L2T1"
        case .L2T1h: "L2T1h"
        case .L2T1_KEY: "L2T1_KEY"
        case .L2T2: "L2T2"
        case .L2T2h: "L2T2h"
        case .L2T2_KEY: "L2T2_KEY"
        case .L2T3: "L2T3"
        case .L2T3h: "L2T3h"
        case .L2T3_KEY: "L2T3_KEY"
        case .L3T1: "L3T1"
        case .L3T1h: "L3T1h"
        case .L3T1_KEY: "L3T1_KEY"
        case .L3T2: "L3T2"
        case .L3T2h: "L3T2h"
        case .L3T2_KEY: "L3T2_KEY"
        case .L3T3: "L3T3"
        case .L3T3h: "L3T3h"
        case .L3T3_KEY: "L3T3_KEY"
        case .L3T3_KEY_SHIFT: "L3T3_KEY_SHIFT"
        }
    }

    var spatial: Int {
        switch self {
        case .L1T1, .L1T2, .L1T3: 1
        case .L2T1, .L2T1h, .L2T1_KEY, .L2T2, .L2T2h, .L2T2_KEY, .L2T3, .L2T3h, .L2T3_KEY: 2
        case .L3T1, .L3T1h, .L3T1_KEY, .L3T2, .L3T2h, .L3T2_KEY, .L3T3, .L3T3h, .L3T3_KEY, .L3T3_KEY_SHIFT: 3
        }
    }

    var temporal: Int {
        switch self {
        case .L1T1, .L2T1, .L2T1h, .L2T1_KEY, .L3T1, .L3T1h, .L3T1_KEY: 1
        case .L1T2, .L2T2, .L2T2h, .L2T2_KEY, .L3T2, .L3T2h, .L3T2_KEY: 2
        case .L1T3, .L2T3, .L2T3h, .L2T3_KEY, .L3T3, .L3T3h, .L3T3_KEY, .L3T3_KEY_SHIFT: 3
        }
    }
}

// MARK: - CustomStringConvertible

extension ScalabilityMode: CustomStringConvertible {
    public var description: String {
        "ScalabilityMode(\(rawStringValue))"
    }
}
