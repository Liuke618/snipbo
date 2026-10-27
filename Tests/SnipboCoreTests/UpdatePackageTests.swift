import Foundation
import Testing
@testable import SnipboCore

@Suite("UpdatePackageTests")
struct UpdatePackageTests {
    private func release(_ names: [String]) -> UpdateRelease {
        UpdateRelease(
            tagName: "v0.6.0",
            displayName: "Snipbo 0.6.0",
            notes: "",
            assets: names.map {
                UpdateAsset(
                    name: $0,
                    url: URL(string: "https://github.com/x/\($0)")!,
                    size: 1
                )
            }
        )
    }

    @Test func picksExactAssets() {
        let picked = UpdatePackage.pick(
            from: release([
                "Snipbo-0.6.0-arm64.zip",
                "Snipbo-0.6.0-arm64.zip.sha256",
            ]),
            runningVersion: "0.6.0"
        )
        #expect(picked?.zip.name == "Snipbo-0.6.0-arm64.zip")
        #expect(picked?.sha256?.name == "Snipbo-0.6.0-arm64.zip.sha256")
    }

    @Test func fallsBackToSingleZip() {
        let picked = UpdatePackage.pick(
            from: release(["Snipbo-0.7.0-arm64.zip", "other.txt"]),
            runningVersion: "0.6.0"
        )
        #expect(picked?.zip.name == "Snipbo-0.7.0-arm64.zip")
    }

    @Test func noZipIsNil() {
        #expect(UpdatePackage.pick(from: release(["notes.md"]), runningVersion: "0.6.0") == nil)
    }

    @Test func sha256KnownVector() {
        // echo -n "abc" | shasum -a 256
        let hex = UpdatePackage.sha256Hex(of: Data("abc".utf8))
        #expect(hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(UpdatePackage.verifySHA256(
            of: Data("abc".utf8),
            digestText: "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD  abc.txt"
        ))
    }

    @Test func digestTextVariants() {
        let data = Data("abc".utf8)
        #expect(UpdatePackage.verifySHA256(of: data, digestText: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
        #expect(UpdatePackage.verifySHA256(of: data, digestText: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  Snipbo-0.6.0-arm64.zip"))
        #expect(!UpdatePackage.verifySHA256(of: data, digestText: "deadbeef  x.zip"))
        #expect(!UpdatePackage.verifySHA256(of: data, digestText: "no hex here"))
    }
}
