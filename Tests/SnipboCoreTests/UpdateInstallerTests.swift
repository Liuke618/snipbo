import Foundation
import Testing
@testable import SnipboCore

/// Preflight ruling: Swift 6 rejects mutation of captured vars in
/// `@Sendable` closures, so the relaunch spy is a small recorder class.
final class RelaunchRecorder: @unchecked Sendable {
    var url: URL?
}

@Suite("UpdateInstallerTests")
struct UpdateInstallerTests {
    private var tmp: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("update-installer-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @Test func makeFakeAppBundleWritesExecutableAndVersion() throws {
        let root = tmp
        try makeDir(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try UpdateInstaller.makeFakeAppBundle(version: "0.6.0", at: root)
            .appendingPathComponent("Snipbo.app", isDirectory: true)
        #expect(UpdateInstaller.stagedVersion(of: bundle) == "0.6.0")
    }

    // @MainActor: relaunch() is MainActor-isolated (it forwards to a
    // @MainActor closure), so the synchronous call must happen on the main actor.
    @MainActor
    @Test func installReplacesAndRelaunches() throws {
        let root = tmp
        try makeDir(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let appsDir = root.appendingPathComponent("apps", isDirectory: true)
        try makeDir(workspace)
        try makeDir(appsDir)
        let current = try UpdateInstaller.makeFakeAppBundle(version: "0.5.0", at: appsDir)
            .appendingPathComponent("Snipbo.app", isDirectory: true)
        let stagedRoot = try UpdateInstaller.makeFakeAppBundle(version: "0.6.0", at: root)
        let staged = stagedRoot.appendingPathComponent("Snipbo.app", isDirectory: true)
        let recorder = RelaunchRecorder()
        let installer = UpdateInstaller(relaunch: { recorder.url = $0 })
        let newBundle = try installer.install(
            stagedApp: staged,
            currentBundle: current,
            workspace: workspace,
            newVersion: "0.6.0"
        )
        #expect(UpdateInstaller.stagedVersion(of: newBundle) == "0.6.0")
        #expect(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("backup/Snipbo.app").path
        ))
        try installer.relaunch(newBundle: newBundle)
        #expect(recorder.url == newBundle)
    }

    @Test func installRollsBackWhenMoveFails() throws {
        let root = tmp
        try makeDir(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let appsDir = root.appendingPathComponent("apps", isDirectory: true)
        try makeDir(workspace)
        try makeDir(appsDir)
        let current = try UpdateInstaller.makeFakeAppBundle(version: "0.5.0", at: appsDir)
            .appendingPathComponent("Snipbo.app", isDirectory: true)
        // 目标位置预置同名目录,让「移动新包」这一步必然失败。
        let blocked = current.deletingLastPathComponent()
            .appendingPathComponent("Snipbo.app-blocked", isDirectory: true)
        try makeDir(blocked)
        // staged 版本不符:在 install 内部的重命名步骤失败前抛错,旧包必须完好。
        let stagedRoot = try UpdateInstaller.makeFakeAppBundle(version: "9.9.9", at: root)
        let staged = stagedRoot.appendingPathComponent("Snipbo.app", isDirectory: true)
        let installer = UpdateInstaller(relaunch: { _ in })
        do {
            _ = try installer.install(
                stagedApp: staged,
                currentBundle: current,
                workspace: workspace,
                newVersion: "0.6.0"
            )
            Issue.record("expected failure")
        } catch {
            // 旧包必须原样还在,且仍能读出旧版本。
            #expect(UpdateInstaller.stagedVersion(of: current) == "0.5.0")
        }
    }

    @Test func applicationsDirectoryCheck() {
        #expect(UpdateInstaller.isInstalledInApplications(
            URL(fileURLWithPath: "/Applications/Snipbo.app")
        ))
        #expect(!UpdateInstaller.isInstalledInApplications(
            URL(fileURLWithPath: "/Users/x/dev/dist/Snipbo.app")
        ))
    }
}
