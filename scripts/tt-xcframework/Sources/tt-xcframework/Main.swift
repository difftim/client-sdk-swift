import ArgumentParser

@main
struct TTXCFramework: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tt-xcframework",
        abstract: "Build LiveKit.xcframework for iOS and render the distribution Package.swift.",
        subcommands: [BuildCommand.self, ManifestCommand.self, WebRTCManifestCommand.self]
    )
}
