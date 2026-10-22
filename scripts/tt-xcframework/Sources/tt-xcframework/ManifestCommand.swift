import ArgumentParser
import Foundation
import XCFrameworkKit

struct ManifestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "manifest",
        abstract: "Write a distribution Package.swift whose LiveKit target downloads from --livekit-url."
    )

    @Option(help: "build-info.json written by `build`.")
    var info: String

    @Option(name: .customLong("livekit-url"), help: "Release asset URL of LiveKit.xcframework.zip.")
    var liveKitURL: String

    @Option(name: .customLong("webrtc-url"), help: "WebRTC zip URL to use instead of the one in build-info.json.")
    var webrtcURL: String?

    @Option(help: "Package.swift to write.")
    var output: String

    func run() throws {
        let buildInfo = try JSONDecoder().decode(BuildInfo.self, from: Data(contentsOf: URL(fileURLWithPath: info)))
        let (liveKit, webrtc, uniffi) = manifestSources(info: buildInfo, liveKitURL: liveKitURL, webrtcURL: webrtcURL)
        try renderManifest(liveKit: liveKit, webrtc: webrtc, uniffi: uniffi).write(toFile: output, atomically: true, encoding: .utf8)
    }
}
