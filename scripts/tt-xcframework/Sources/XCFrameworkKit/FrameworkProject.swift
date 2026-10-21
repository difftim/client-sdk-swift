// Generates a temporary Xcode project with one dynamic framework target that compiles the
// LiveKit sources directly. Adapted from upstream scripts/xcframework.swift: iOS only, the
// fork's WebRTC URL, and TTSignal as an extra package dependency.

import Foundation
import PathKit
import XcodeProj

/// Package dependencies of the framework target, matched by substring against the fork's
/// Package.swift `.package(...)` lines.
let packageProducts: [(pattern: String, product: String)] = [
    ("webrtc-xcframework", "LiveKitWebRTC"),
    ("uniffi-xcframework", "LiveKitUniFFI"),
    ("swift-protobuf", "SwiftProtobuf"),
    ("ttsignal-xcframework", "TTSignal"),
]

public func generateFrameworkProject(at projectPath: Path, repoRoot: Path) throws {
    let objcHelpers = repoRoot + "Sources/LKObjCHelpers"
    guard (objcHelpers + "module.modulemap").exists else {
        throw ManifestError("\(objcHelpers)/module.modulemap is missing")
    }

    let pbxProj = PBXProj()

    let projectConfig = XCBuildConfiguration(name: "Release", buildSettings: [
        "SDKROOT": "iphoneos",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
        "SWIFT_VERSION": "6.0",
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "IPHONEOS_DEPLOYMENT_TARGET": "15.0",
    ])
    pbxProj.add(object: projectConfig)
    let projectConfigList = XCConfigurationList(buildConfigurations: [projectConfig], defaultConfigurationName: "Release")
    pbxProj.add(object: projectConfigList)
    let mainGroup = PBXGroup(sourceTree: .sourceRoot)
    pbxProj.add(object: mainGroup)
    let project = PBXProject(name: "LiveKit", buildConfigurationList: projectConfigList,
                             compatibilityVersion: "Xcode 14.0", mainGroup: mainGroup)
    pbxProj.add(object: project)
    pbxProj.rootObject = project

    let forkManifest: String = try (repoRoot + "Package.swift").read()
    var deps: [XCSwiftPackageProductDependency] = []
    for (pattern, product) in packageProducts {
        let dep = try forkDependency(pattern, in: forkManifest)
        let ref = XCRemoteSwiftPackageReference(repositoryURL: dep.url, versionRequirement: .exact(dep.version))
        pbxProj.add(object: ref)
        project.packages.append(ref)
        let productDep = XCSwiftPackageProductDependency(productName: product, package: ref)
        pbxProj.add(object: productDep)
        deps.append(productDep)
    }

    let sourcesBP = PBXSourcesBuildPhase()
    let frameworksBP = PBXFrameworksBuildPhase()
    let resourcesBP = PBXResourcesBuildPhase()
    let headersBP = PBXHeadersBuildPhase()
    [sourcesBP, frameworksBP, resourcesBP, headersBP].forEach { pbxProj.add(object: $0) }

    let targetConfig = XCBuildConfiguration(name: "Release", buildSettings: [
        "PRODUCT_NAME": "LiveKit",
        "PRODUCT_BUNDLE_IDENTIFIER": "io.livekit.LiveKit",
        "GENERATE_INFOPLIST_FILE": "YES",
        "CURRENT_PROJECT_VERSION": "1",
        "MARKETING_VERSION": "1.0",
        "SKIP_INSTALL": "NO",
        "BUILD_LIBRARY_FOR_DISTRIBUTION": "YES",
        "INSTALL_PATH": "$(LOCAL_LIBRARY_DIR)/Frameworks",
        "DYLIB_INSTALL_NAME_BASE": "@rpath",
        "DEFINES_MODULE": "YES",
        "MACH_O_TYPE": "mh_dylib",
        "CLANG_ENABLE_MODULES": "YES",
        "HEADER_SEARCH_PATHS": "$(inherited) " + (objcHelpers + "include").string,
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "LK_XCFRAMEWORK",
        "SWIFT_INCLUDE_PATHS": "$(inherited) " + objcHelpers.string,
    ])
    pbxProj.add(object: targetConfig)
    let targetConfigList = XCConfigurationList(buildConfigurations: [targetConfig], defaultConfigurationName: "Release")
    pbxProj.add(object: targetConfigList)
    let target = PBXNativeTarget(name: "LiveKit", buildConfigurationList: targetConfigList,
                                 buildPhases: [headersBP, sourcesBP, frameworksBP, resourcesBP],
                                 productType: .framework)
    pbxProj.add(object: target)
    target.packageProductDependencies = deps
    project.targets.append(target)

    for (name, dir, excludes) in [("LiveKit", repoRoot + "Sources/LiveKit", ["NOTICE"]), ("LKObjCHelpers", objcHelpers, [])] {
        let group = PBXGroup(sourceTree: .group, name: name, path: dir.string)
        pbxProj.add(object: group)
        mainGroup.children.append(group)
        try addSources(dir: dir, group: group, sourcesBP: sourcesBP, resourcesBP: resourcesBP,
                       pbxProj: pbxProj, excludes: excludes)
    }
    for header in try (objcHelpers + "include").children() where header.extension == "h" {
        if let fileRef = pbxProj.fileReferences.first(where: { $0.path == header.string }) {
            let buildFile = PBXBuildFile(file: fileRef, settings: ["ATTRIBUTES": ["Public"]])
            pbxProj.add(object: buildFile)
            headersBP.files?.append(buildFile)
        }
    }

    try XcodeProj(workspace: XCWorkspace(), pbxproj: pbxProj).write(path: projectPath)
}

private func addSources(dir: Path, group: PBXGroup, sourcesBP: PBXSourcesBuildPhase, resourcesBP: PBXResourcesBuildPhase,
                        pbxProj: PBXProj, excludes: [String]) throws
{
    for child in try dir.children().sorted(by: { $0.string < $1.string }) {
        let name = child.lastComponent
        if excludes.contains(name) { continue }
        if child.isDirectory {
            let subgroup = PBXGroup(sourceTree: .group, name: name, path: name)
            pbxProj.add(object: subgroup)
            group.children.append(subgroup)
            try addSources(dir: child, group: subgroup, sourcesBP: sourcesBP, resourcesBP: resourcesBP,
                           pbxProj: pbxProj, excludes: [])
            continue
        }
        let fileRef = PBXFileReference(sourceTree: .absolute, name: name, path: child.string)
        pbxProj.add(object: fileRef)
        group.children.append(fileRef)
        let buildFile = PBXBuildFile(file: fileRef)
        switch child.extension ?? "" {
        case "swift", "m":
            pbxProj.add(object: buildFile)
            sourcesBP.files?.append(buildFile)
        case "xcprivacy":
            pbxProj.add(object: buildFile)
            resourcesBP.files?.append(buildFile)
        default:
            break
        }
    }
}
