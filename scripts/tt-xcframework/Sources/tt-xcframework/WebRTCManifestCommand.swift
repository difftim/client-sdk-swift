import ArgumentParser
import XCFrameworkKit

struct WebRTCManifestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "webrtc-manifest",
        abstract: "Write the Package.swift of a WebRTC distribution repo."
    )

    @Option(help: "Release asset URL of LiveKitWebRTC.xcframework.zip.")
    var url: String

    @Option(help: "SHA-256 of the zip.")
    var checksum: String

    @Option(help: "Package.swift to write.")
    var output: String

    func validate() throws {
        guard checksum.wholeMatch(of: #/[0-9a-f]{64}/#) != nil else {
            throw ValidationError("--checksum must be 64 lowercase hex characters")
        }
    }

    func run() throws {
        try renderWebRTCManifest(url: url, checksum: checksum).write(toFile: output, atomically: true, encoding: .utf8)
    }
}
