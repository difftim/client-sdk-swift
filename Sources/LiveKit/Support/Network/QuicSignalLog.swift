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

#if os(iOS)
import TTSignal

enum QuicSignalLog {
    static func configure() {
        guard LiveKitSDK.enableQuicLogging else {
            TTSignalLog.setSink(nil)
            return
        }

        TTSignalLog.setSink { level, message in
            forward(level: level, message: message)
        }
    }

    static func ttSignalLogLevel(from level: LogLevel) -> TTSignalConfig.LogLevel {
        switch level {
        case .debug: .debug
        case .info: .info
        case .warning: .warn
        case .error: .error
        }
    }

    private static func forward(level: TTSignalConfig.LogLevel, message: String) {
        sharedLogger.log(sanitizedMessage(message),
                         liveKitLogLevel(from: level),
                         source: nil,
                         file: #fileID,
                         type: Self.self,
                         function: #function,
                         line: #line,
                         metaData: [:],
                         ptr: nil)
    }

    private static func liveKitLogLevel(from level: TTSignalConfig.LogLevel) -> LogLevel {
        switch level {
        case .debug: .debug
        case .info: .info
        case .warn: .warning
        case .error, .fatal: .error
        }
    }

    private static func sanitizedMessage(_ message: String) -> String {
        guard var start = indexAfterTimestampPrefix(in: message) else {
            return message
        }

        if let afterLevelTag = indexAfterLevelTagPrefix(in: message, from: start) {
            start = afterLevelTag
        }

        return String(message[start...])
    }

    private static func indexAfterTimestampPrefix(in message: String) -> String.Index? {
        var index = message.startIndex

        guard consume("[", in: message, index: &index),
              consumeDigits(4, in: message, index: &index),
              consume("/", in: message, index: &index),
              consumeDigits(2, in: message, index: &index),
              consume("/", in: message, index: &index),
              consumeDigits(2, in: message, index: &index),
              consume(" ", in: message, index: &index),
              consumeDigits(2, in: message, index: &index),
              consume(":", in: message, index: &index),
              consumeDigits(2, in: message, index: &index),
              consume(":", in: message, index: &index),
              consumeDigits(2, in: message, index: &index),
              consume(" ", in: message, index: &index),
              consumeDigits(in: message, index: &index),
              consume("]", in: message, index: &index)
        else {
            return nil
        }

        consumeSpaces(in: message, index: &index)
        return index
    }

    private static func indexAfterLevelTagPrefix(in message: String, from start: String.Index) -> String.Index? {
        guard start < message.endIndex, message[start] == "[" else {
            return nil
        }

        let tagStart = message.index(after: start)
        guard let tagEnd = message[tagStart...].firstIndex(of: "]") else {
            return nil
        }

        let tag = message[tagStart ..< tagEnd]
        guard isLevelTag(tag) else {
            return nil
        }

        var index = message.index(after: tagEnd)
        consumeSpaces(in: message, index: &index)
        return index
    }

    private static func isLevelTag(_ tag: Substring) -> Bool {
        switch tag {
        case "report", "fatal", "error", "warn", "stats", "info", "debug":
            true
        default:
            false
        }
    }

    private static func consume(_ character: Character, in message: String, index: inout String.Index) -> Bool {
        guard index < message.endIndex, message[index] == character else {
            return false
        }
        index = message.index(after: index)
        return true
    }

    private static func consumeDigits(_ count: Int, in message: String, index: inout String.Index) -> Bool {
        for _ in 0 ..< count {
            guard consumeDigit(in: message, index: &index) else {
                return false
            }
        }
        return true
    }

    private static func consumeDigits(in message: String, index: inout String.Index) -> Bool {
        var consumed = false
        while consumeDigit(in: message, index: &index) {
            consumed = true
        }
        return consumed
    }

    private static func consumeDigit(in message: String, index: inout String.Index) -> Bool {
        guard index < message.endIndex,
              let scalar = message[index].unicodeScalars.first,
              scalar.value >= 48,
              scalar.value <= 57
        else {
            return false
        }
        index = message.index(after: index)
        return true
    }

    private static func consumeSpaces(in message: String, index: inout String.Index) {
        while index < message.endIndex, message[index] == " " {
            index = message.index(after: index)
        }
    }
}
#endif
