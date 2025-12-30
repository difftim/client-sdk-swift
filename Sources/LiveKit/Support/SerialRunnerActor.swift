/*
 * Copyright 2025 LiveKit
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

actor SerialRunnerActor<Value: Sendable> {
    private var previous: (id: UInt64, task: Task<Value, Error>)?
    private var nextId: UInt64 = 0

    func run(block: @Sendable @escaping () async throws -> Value) async throws -> Value {
        let prevTask = previous?.task

        nextId &+= 1
        let id = nextId

        let task = Task { [prevTask] in
            // Always wait for the previous task to maintain serial ordering
            if let prevTask {
                _ = try? await prevTask.value
            }

            // Check for cancellation before running the block
            try Task.checkCancellation()

            // Run the new block
            return try await block()
        }

        previous = (id, task)

        do {
            let ret = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }

            // Only clear if we are still the latest task
            if previous?.id == id {
                previous = nil
            }
            return ret
        } catch {
            if previous?.id == id {
                previous = nil
            }
            throw error
        }
    }
}
