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

public struct Stopwatch: Sendable {
    public struct Entry: Equatable, Sendable {
        let label: String
        let time: TimeInterval
    }

    public let label: String
    public private(set) var start: TimeInterval
    public private(set) var splits = [Entry]()

    init(label: String) {
        self.label = label
        start = ProcessInfo.processInfo.systemUptime
    }

    mutating func split(label: String = "") {
        splits.append(Entry(label: label, time: ProcessInfo.processInfo.systemUptime))
    }

    public func total() -> TimeInterval {
        guard let last = splits.last else { return 0 }
        return last.time - start
    }
}

extension Stopwatch: Equatable {
    public static func == (lhs: Stopwatch, rhs: Stopwatch) -> Bool {
        lhs.start == rhs.start &&
            lhs.splits == rhs.splits
    }
}

extension Stopwatch: CustomStringConvertible {
    public var description: String { formatted { "\($0.rounded(to: 2))s" } }
    public var msDescription: String { formatted { "\(Int($0 * 1000))ms" } }

    private func formatted(interval: (TimeInterval) -> String) -> String {
        var parts = [String]()
        var s = start
        for x in splits {
            parts.append("\(x.label) +\(interval(x.time - s))")
            s = x.time
        }
        parts.append("total \(interval(s - start))")
        return "Stopwatch(\(label), \(parts.joined(separator: ", ")))"
    }
}
