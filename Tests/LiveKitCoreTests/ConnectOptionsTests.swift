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

@testable import LiveKit
import Testing

struct ConnectOptionsTests {
    @Test func quicConnectTimeoutHasDefaultAndCustomValues() {
        #expect(ConnectOptions().quicConnectTimeoutMs == 7000)
        #expect(ConnectOptions(quicConnectTimeoutMs: 3000).quicConnectTimeoutMs == 3000)
    }

    @Test func quicConnectTimeoutParticipatesInEqualityAndHashing() {
        let first = ConnectOptions(quicConnectTimeoutMs: 3000)
        let same = ConnectOptions(quicConnectTimeoutMs: 3000)
        let different = ConnectOptions(quicConnectTimeoutMs: 4000)

        #expect(first == same)
        #expect(first.hash == same.hash)
        #expect(first != different)
    }

    @Test func quicConnectTimeoutNormalizationUsesInclusiveBounds() {
        #expect(normalizeQuicConnectTimeoutMs(1000) == 1000)
        #expect(normalizeQuicConnectTimeoutMs(15000) == 15000)
        #expect(normalizeQuicConnectTimeoutMs(999) == 7000)
        #expect(normalizeQuicConnectTimeoutMs(15001) == 7000)
    }

    @Test func copyWithPreservesQuicConnectTimeoutByDefault() {
        let options = ConnectOptions(quicConnectTimeoutMs: 3000)

        #expect(options.copyWith().quicConnectTimeoutMs == 3000)
    }

    @Test func copyWithOverridesQuicConnectTimeout() {
        let options = ConnectOptions(quicConnectTimeoutMs: 3000)

        #expect(options.copyWith(quicConnectTimeoutMs: .value(5000)).quicConnectTimeoutMs == 5000)
    }

    @Test func forcePhysicalParticipatesInEqualityHashingAndCopying() {
        let direct = ConnectOptions(forcePhysical: true)
        let same = ConnectOptions(forcePhysical: true)
        let systemRouted = ConnectOptions(forcePhysical: false)

        #expect(direct == same)
        #expect(direct.hash == same.hash)
        #expect(direct != systemRouted)
        #expect(direct.copyWith().forcePhysical)
        #expect(!direct.copyWith(forcePhysical: .value(false)).forcePhysical)
    }
}
