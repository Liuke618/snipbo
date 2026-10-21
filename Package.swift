// swift-tools-version: 6.0
import Foundation
import PackageDescription

// A Command Line Tools-only install ships the Swift Testing macro plugin in a
// "testing" subdirectory that SwiftPM does not add to the macro search path.
// Point the test target at it when present so `swift test` works without Xcode.
let cltTestingMacrosPath = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
var testSwiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v6)]
if FileManager.default.fileExists(atPath: cltTestingMacrosPath) {
    testSwiftSettings.append(.unsafeFlags(["-plugin-path", cltTestingMacrosPath]))
}

let package = Package(
    name: "LightShot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LightShot", targets: ["LightShotApp"]),
        .library(name: "LightShotCore", targets: ["LightShotCore"]),
    ],
    targets: [
        .target(
            name: "LightShotCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "LightShotApp",
            dependencies: ["LightShotCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LightShotCoreTests",
            dependencies: ["LightShotCore"],
            swiftSettings: testSwiftSettings
        ),
    ]
)
