import ArgumentParser
import XCFrameworkKit

struct BuildCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Archive iOS device + simulator and write LiveKit.xcframework.zip, build-info.json and a local Package.swift."
    )

    @Option(help: "Fork checkout (the directory containing Package.swift).")
    var repo: String

    @Option(help: "Output directory; recreated on every run. Build products go to its sibling xcfw-build/ and xcfw-logs/.")
    var output: String

    func run() throws {
        let info = try Builder(repoRoot: repo, outputDir: output).run { print("==> \($0)") }
        print("LiveKit \(info.version): \(output)/LiveKit.xcframework.zip")
        print("checksum: \(info.checksum)")
    }
}
