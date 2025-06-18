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

actor SerialRunnerActor<Value: Sendable>: Loggable {
    private var previousTask: Task<Value, Error>?

    func run(
        block: @Sendable @escaping () async throws -> Value,
        nameoo: String = #function, file: String = #file, line: Int = #line
    ) async throws -> Value {
        let name = "\(file):\(line) \(nameoo)"

        self.log("task entery name:\(String(describing: name))")

        let task: Task<Value, Error> = Task<Value, Error> { [previousTask] in

            self.log("task name:\(String(describing: name))")

            do {
                // Wait for the previous task to complete, but cancel it if needed
                if let previousTask, !Task.isCancelled {
                    // If previous task is still running, wait for it
                    self.log("task name start wait :\(String(describing: name))")
                    _ = try? await previousTask.value
                    self.log("task name endwait :\(String(describing: name))")
                }
            } catch {
                self.log(
                    "task name exception :\(String(describing: name)), error: \(error)"
                )
                // If cancelled, throw cancellation error
                throw error
            }

            self.log("task name 11111:\(String(describing: name))")

            do {
                // Check if the task is cancelled before running the block
                try Task.checkCancellation()
            } catch {
                self.log(
                    "task name exception 22222:\(String(describing: name)), error: \(error)"
                )
                // If cancelled, throw cancellation error
                throw error
            }

            self.log("task name 33333:\(String(describing: name))")

            // Run the new block
            do {
            let ret = try await block()
                
                self.log("task name 33333 out:\(String(describing: name))")
                
                return ret
            } catch {
                self.log(
                    "task name exception 44444:\(String(describing: name)), error: \(error)"
                )
                // If cancelled, throw cancellation error
                throw error
            }
        }

        previousTask = task

        self.log("task entery22 name:\(String(describing: name))")

        do {
            return try await withTaskCancellationHandler {
                // Await the current task's result
                do {
                    self.log("task entery222' in name:\(String(describing: name))")
                    let ret = try await task.value
                    self.log("task entery222' out name:\(String(describing: name))")
                    return ret
                } catch {
                    self.log(
                        "task entery33 result exception name:\(String(describing: name)), error: \(error)"
                    )
                    // If cancelled, throw cancellation error
                    throw error
                }
            } onCancel: {
                // Ensure the task is canceled when requested
                task.cancel()
            }
        } catch {
            self.log(
                "task entery44 exception name:\(String(describing: name)), error: \(error)"
            )
            // If cancelled, throw cancellation error
            throw error
        }
    }
}
