// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Swift Testing on a Command Line Tools-only machine: the CLT toolchain builds
// the Swift Testing macro plugins into a "testing" subdirectory that SwiftPM
// does not add to the macro search path, so `swift test` needs an explicit
// `-plugin-path`.
//
// This workaround applies only when the Command Line Tools are the *active*
// toolchain. The plugins directory also exists on machines with Xcode
// installed, and pointing Xcode's compiler at CLT-built macro plugins would
// cause an ABI/version mismatch (or ambiguous `TestingMacros` resolution), so
// the flag is added only when `/usr/bin/xcode-select -p` reports the CLT
// developer directory *and* the plugins directory is present.
//
// Can be deleted once Xcode is selected as the active toolchain (or XCTest is
// available), where SwiftPM resolves the macro plugins on its own.
let cltDeveloperDir = "/Library/Developer/CommandLineTools"
let cltTestingMacrosPath = cltDeveloperDir + "/usr/lib/swift/host/plugins/testing"

/// The developer directory currently selected via `xcode-select`, or `nil` if
/// it cannot be determined.
func activeDeveloperDirectory() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    process.arguments = ["-p"]
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return nil
    }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    var path = String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    while path.count > 1 && path.hasSuffix("/") {
        path.removeLast()
    }
    return path.isEmpty ? nil : path
}

var testSwiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v6)]
if activeDeveloperDirectory() == cltDeveloperDir,
   FileManager.default.fileExists(atPath: cltTestingMacrosPath) {
    testSwiftSettings.append(.unsafeFlags(["-plugin-path", cltTestingMacrosPath]))
}

let package = Package(
    name: "Snipbo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Snipbo", targets: ["SnipboApp"]),
        // Lowercase "snipbo" would collide with "Snipbo" on a case-insensitive
        // filesystem, so the SwiftPM product keeps the -cli suffix. The build
        // script installs it as dist/snipbo.
        .executable(name: "snipbo-cli", targets: ["SnipboCLI"]),
        .library(name: "SnipboCore", targets: ["SnipboCore"]),
    ],
    targets: [
        .target(
            name: "SnipboCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "SnipboApp",
            dependencies: ["SnipboCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "SnipboCLI",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SnipboCoreTests",
            dependencies: ["SnipboCore"],
            swiftSettings: testSwiftSettings
        ),
    ]
)
