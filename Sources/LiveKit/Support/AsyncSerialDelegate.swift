/*
 * Copyright 2024 LiveKit
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

class AsyncSerialDelegate<T>: Loggable {
    private struct State {
        weak var delegate: AnyObject?
    }

    private let _state = StateSync(State())
    private let _serialRunner = SerialRunnerActor<Void>()

    public func set(delegate: T) {
        _state.mutate { $0.delegate = delegate as AnyObject }
    }

    public func notifyAsync(_ fnc: @escaping (T) async -> Void, name: String = #function, file: String = #file, line: Int = #line) async throws {
       let newName = "\(file):\(line) \(name)"

        guard let delegate = _state.read({ $0.delegate }) as? T else {
            self.log("delegate not found, name:\(String(describing: newName))")
            return
        }
        self.log("delegate found, name:\(String(describing: newName))")
        try await _serialRunner.run(block: {
            await fnc(delegate)
        }, nameoo:name, file: file, line: line)
    }

    public func notifyDetached(_ fnc: @escaping (T) async -> Void, name: String = #function, file: String = #file, line: Int = #line) {
        let newName = "\(file):\(line) \(name)"

        self.log("notifyDetached1111, name:\(String(describing: newName))")
        Task.detached {
            do {
                self.log("notifyDetached22222, name:\(String(describing: newName))")
                try await self.notifyAsync(fnc, name:name, file: file, line: line)
            } catch {
                self.log("Detached notification failed with error: \(error), name:\(String(describing: newName))")
            }
        }
    }
}
