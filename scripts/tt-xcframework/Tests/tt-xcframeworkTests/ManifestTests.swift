import Testing
@testable import XCFrameworkKit

struct ManifestTests {
    private let forkManifest = """
        dependencies: [
            // LK-Prefixed Dynamic WebRTC XCFramework
            .package(url: "https://github.com/3th1UOYgUtJkurSZ/webrtc-xcframework.git", exact: "144.7559.15"),
            .package(url: "https://github.com/livekit/livekit-uniffi-xcframework.git", exact: "0.0.6"),
            .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.31.0"),
            .package(url: "https://github.com/3th1UOYgUtJkurSZ/ttsignal-xcframework.git", exact: "1.0.20261019"),
        ],
        """

    @Test func forkDependencyReadsExactPins() throws {
        let webrtc = try forkDependency("webrtc-xcframework", in: forkManifest)
        #expect(webrtc.url == "https://github.com/3th1UOYgUtJkurSZ/webrtc-xcframework.git")
        #expect(webrtc.version == "144.7559.15")

        let ttsignal = try forkDependency("ttsignal-xcframework", in: forkManifest)
        #expect(ttsignal.url == "https://github.com/3th1UOYgUtJkurSZ/ttsignal-xcframework.git")
        #expect(ttsignal.version == "1.0.20261019")

        #expect(try forkDependency("swift-protobuf", in: forkManifest).version == "1.31.0")
        #expect(throws: (any Error).self) { try forkDependency("missing-xcframework", in: forkManifest) }
    }

    @Test func binaryDepReadsUrlAndChecksum() throws {
        let upstream = """
            .binaryTarget(
                name: "LiveKitWebRTC",
                url: "https://github.com/3th1UOYgUtJkurSZ/webrtc-xcframework/releases/download/144.7559.15/LiveKitWebRTC.xcframework.zip",
                checksum: "9003e3ae71ec76abd4b2495121e582ca0930b3d4c7a09ef5ce6ea7004c80004b"
            ),
            """
        let dep = try binaryDep(fromCheckoutManifest: upstream)
        #expect(dep.url == "https://github.com/3th1UOYgUtJkurSZ/webrtc-xcframework/releases/download/144.7559.15/LiveKitWebRTC.xcframework.zip")
        #expect(dep.checksum == "9003e3ae71ec76abd4b2495121e582ca0930b3d4c7a09ef5ce6ea7004c80004b")
        #expect(throws: (any Error).self) { try binaryDep(fromCheckoutManifest: "// no binary target") }
    }

    @Test func sdkVersionReadsLiveKitSDKVersion() throws {
        let source = """
            public enum LiveKitSDK {
                public static let version = "2.15.2-a12"
            }
            """
        #expect(try sdkVersion(fromLiveKitSwift: source) == "2.15.2-a12")
        #expect(throws: (any Error).self) { try sdkVersion(fromLiveKitSwift: "enum LiveKitSDK {}") }
    }

    @Test func renderManifestUsesGivenSources() {
        let liveKitURL = "https://api.github.com/repos/difftim/client-sdk-swift-xcframework/releases/assets/1.zip"
        let checksum = String(repeating: "a", count: 64)
        let webrtc = BinaryDep(url: "https://example.com/LiveKitWebRTC.xcframework.zip", checksum: String(repeating: "b", count: 64))
        let uniffi = BinaryDep(url: "https://example.com/RustLiveKitUniFFI.xcframework.zip", checksum: String(repeating: "c", count: 64))

        let remote = renderManifest(liveKit: .url(liveKitURL, checksum: checksum), webrtc: webrtc, uniffi: uniffi)
        #expect(remote.contains("url: \"\(liveKitURL)\""))
        #expect(remote.contains("checksum: \"\(checksum)\""))
        #expect(remote.contains("platforms: [.iOS(.v15)]"))
        #expect(remote.contains(".library(name: \"LiveKit\", targets: [\"LiveKit\", \"LiveKitWebRTC\", \"RustLiveKitUniFFI\"])"))
        for name in ["LiveKit", "LiveKitWebRTC", "RustLiveKitUniFFI"] {
            #expect(remote.contains("name: \"\(name)\""))
        }
        #expect(remote.contains("url: \"\(webrtc.url)\""))
        #expect(remote.contains("checksum: \"\(uniffi.checksum)\""))
        #expect(!remote.contains("path:"))

        let local = renderManifest(liveKit: .path("LiveKit.xcframework.zip"), webrtc: webrtc, uniffi: uniffi)
        #expect(local.contains(".binaryTarget(name: \"LiveKit\", path: \"LiveKit.xcframework.zip\")"))
        #expect(!local.contains(checksum))
    }

    @Test func renderWebRTCManifestUsesGivenURL() {
        let url = "https://api.github.com/repos/difftim/webrtc-xcframework/releases/assets/1.zip"
        let checksum = "9003e3ae71ec76abd4b2495121e582ca0930b3d4c7a09ef5ce6ea7004c80004b"

        let manifest = renderWebRTCManifest(url: url, checksum: checksum)
        #expect(manifest.contains("name: \"LiveKitWebRTC\""))
        #expect(manifest.contains(".library(name: \"LiveKitWebRTC\", targets: [\"LiveKitWebRTC\"])"))
        #expect(manifest.contains("url: \"\(url)\""))
        #expect(manifest.contains("checksum: \"\(checksum)\""))
        // Same platforms as the 3th1UOYgUtJkurSZ package it replaces, so the fork's iOS 13 / macOS /
        // tvOS declarations keep resolving.
        #expect(manifest.contains("platforms: [.iOS(.v13), .macOS(.v10_15), .macCatalyst(.v14)]"))
        #expect(!manifest.contains("path:"))
    }
}
