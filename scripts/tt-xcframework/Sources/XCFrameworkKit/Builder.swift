// Archives the generated project for iOS device and simulator, then packages
// LiveKit.xcframework.zip, build-info.json and a local Package.swift.

import Foundation
import PathKit

struct Platform: Sendable {
    let label, destination, archiveName: String
}

let platforms: [Platform] = [
    .init(label: "iOS Device", destination: "generic/platform=iOS", archiveName: "ios-arm64"),
    .init(label: "iOS Simulator", destination: "generic/platform=iOS Simulator", archiveName: "ios-arm64_x86_64-simulator"),
]

/// Runs a command with stdout and stderr in `log`; on failure throws with the log tail.
@discardableResult
func exec(_ args: [String], log: Path) throws -> String {
    FileManager.default.createFile(atPath: log.string, contents: nil)
    let handle = try FileHandle(forWritingTo: log.url)
    defer { try? handle.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = args
    process.standardOutput = handle
    process.standardError = handle
    try process.run()
    process.waitUntilExit()
    let text = (try? String(contentsOf: log.url, encoding: .utf8)) ?? ""
    guard process.terminationStatus == 0 else {
        throw ManifestError("\(args.prefix(2).joined(separator: " ")) failed (\(process.terminationStatus)), log: \(log)\n\(text.suffix(3000))")
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

public struct Builder {
    let repoRoot: Path
    let outputDir: Path

    public init(repoRoot: String, outputDir: String) {
        self.repoRoot = Path(repoRoot).absolute()
        self.outputDir = Path(outputDir).absolute()
    }

    /// Build products and logs live next to the output directory, never inside it, so the output
    /// directory is a clean local package.
    var buildDir: Path { outputDir.parent() + "xcfw-build" }
    var logDir: Path { outputDir.parent() + "xcfw-logs" }

    public func run(progress: (String) -> Void) throws -> BuildInfo {
        for dir in [buildDir, logDir, outputDir] where dir.exists { try dir.delete() }
        for dir in [buildDir, logDir, outputDir] { try dir.mkpath() }
        let spmDir = buildDir + "spm"
        let version = try sdkVersion(fromLiveKitSwift: (repoRoot + "Sources/LiveKit/LiveKit.swift").read())

        progress("Generating Xcode project for LiveKit \(version)")
        let projectPath = buildDir + "LiveKit.xcodeproj"
        try generateFrameworkProject(at: projectPath, repoRoot: repoRoot)

        progress("Resolving Swift packages")
        try exec(["xcodebuild", "-resolvePackageDependencies", "-project", projectPath.string, "-scheme", "LiveKit",
                  "-clonedSourcePackagesDirPath", spmDir.string], log: logDir + "resolve.log")
        let webrtc = try binaryDep(fromCheckoutManifest: (spmDir + "checkouts/webrtc-xcframework/Package.swift").read())
        let uniffi = try binaryDep(fromCheckoutManifest: (spmDir + "checkouts/livekit-uniffi-xcframework/Package.swift").read())

        progress("Archiving \(platforms.map(\.label).joined(separator: ", "))")
        let archives = try archive(projectPath: projectPath, spmDir: spmDir)

        progress("Creating LiveKit.xcframework")
        let xcframework = outputDir + "LiveKit.xcframework"
        try exec(["xcodebuild", "-create-xcframework"]
            + archives.flatMap { ["-archive", $0.string, "-framework", "LiveKit.framework"] }
            + ["-output", xcframework.string], log: logDir + "create-xcframework.log")

        progress("Zipping")
        let zip = outputDir + "LiveKit.xcframework.zip"
        try exec(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", xcframework.string, zip.string], log: logDir + "zip.log")
        let checksum = try String(exec(["shasum", "-a", "256", zip.string], log: logDir + "checksum.log").prefix(64))

        let webrtcVersion = try forkDependency("webrtc-xcframework", in: (repoRoot + "Package.swift").read()).version
        let info = BuildInfo(version: version, checksum: checksum, webrtc: webrtc, uniffi: uniffi, webrtcVersion: webrtcVersion)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try (outputDir + "build-info.json").write(encoder.encode(info) + Data("\n".utf8))
        try (outputDir + "Package.swift").write(renderManifest(liveKit: .path(zip.lastComponent), webrtc: webrtc, uniffi: uniffi))
        return info
    }

    private func archive(projectPath: Path, spmDir: Path) throws -> [Path] {
        let results = LockedResults(count: platforms.count)
        DispatchQueue.concurrentPerform(iterations: platforms.count) { index in
            let platform = platforms[index]
            let archivePath = buildDir + "\(platform.archiveName).xcarchive"
            results.set(index, Result {
                try exec(["xcodebuild", "archive", "-project", projectPath.string, "-scheme", "LiveKit",
                          "-configuration", "Release", "-destination", platform.destination,
                          "-archivePath", archivePath.string,
                          "-derivedDataPath", (buildDir + "dd-\(platform.archiveName)").string,
                          "-clonedSourcePackagesDirPath", spmDir.string],
                         log: logDir + "archive-\(platform.archiveName).log")
                return archivePath
            })
        }
        return try results.values.map { try $0.get() }
    }
}

private final class LockedResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Result<Path, Error>]

    init(count: Int) {
        storage = Array(repeating: .failure(ManifestError("not run")), count: count)
    }

    func set(_ index: Int, _ value: Result<Path, Error>) {
        lock.lock()
        storage[index] = value
        lock.unlock()
    }

    var values: [Result<Path, Error>] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
