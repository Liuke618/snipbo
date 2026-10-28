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

    @Test func installThrowsWhenStagedVersionMismatchesWithoutTouchingCurrentBundle() throws {
        let root = tmp
        try makeDir(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let appsDir = root.appendingPathComponent("apps", isDirectory: true)
        try makeDir(workspace)
        try makeDir(appsDir)
        let current = try UpdateInstaller.makeFakeAppBundle(version: "0.5.0", at: appsDir)
            .appendingPathComponent("Snipbo.app", isDirectory: true)
        // staged 版本与 newVersion 不符:install 在版本守卫处抛错,
        // 不做任何文件系统改动,旧包必须原样还在且仍能读出旧版本。
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
            Issue.record("expected version-mismatch failure")
        } catch {
            #expect(UpdateInstaller.stagedVersion(of: current) == "0.5.0")
        }
    }

    @Test func installRestoresBackupWhenTargetMoveFails() throws {
        let root = tmp
        try makeDir(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let appsDir = root.appendingPathComponent("apps", isDirectory: true)
        try makeDir(workspace)
        try makeDir(appsDir)
        let current = try UpdateInstaller.makeFakeAppBundle(version: "0.5.0", at: appsDir)
            .appendingPathComponent("Snipbo.app", isDirectory: true)
        // staged 版本必须与 newVersion 匹配,否则会先在版本守卫处抛错、走不到回滚分支。
        // install 用 stagedApp.lastPathComponent 作为目标名,所以把 staged 包改名为
        // MySnip.app,再在目标位置 apps/MySnip.app 预置一个非空目录——moveItem 到
        // 已存在的非空目录必然失败(NSFileWriteFileExistsError),触发「把备份移回原位」。
        let stagedDir = root.appendingPathComponent("staged", isDirectory: true)
        try makeDir(stagedDir)
        try UpdateInstaller.makeFakeAppBundle(version: "0.6.0", at: stagedDir)
        let staged = stagedDir.appendingPathComponent("Snipbo.app", isDirectory: true)
        let renamedStaged = stagedDir.appendingPathComponent("MySnip.app", isDirectory: true)
        try FileManager.default.moveItem(at: staged, to: renamedStaged)
        let blockedTarget = appsDir.appendingPathComponent("MySnip.app", isDirectory: true)
        try makeDir(blockedTarget)
        try Data("blocked".utf8).write(to: blockedTarget.appendingPathComponent("blocked.txt"))
        let installer = UpdateInstaller(relaunch: { _ in })
        do {
            _ = try installer.install(
                stagedApp: renamedStaged,
                currentBundle: current,
                workspace: workspace,
                newVersion: "0.6.0"
            )
            Issue.record("expected installFailed")
        } catch {
            if case .installFailed = error as? UpdateError {
                // 回滚:旧包被移回原位,仍能读出旧版本;备份位置不再残留。
                #expect(UpdateInstaller.stagedVersion(of: current) == "0.5.0")
                #expect(!FileManager.default.fileExists(
                    atPath: workspace.appendingPathComponent("backup/Snipbo.app").path
                ))
            } else {
                Issue.record("expected installFailed, got \(error)")
            }
        }
    }

    @Test func unzipThrowsInstallFailedOnCorruptZip() throws {
        let root = tmp
        try makeDir(root)
        defer { try? FileManager.default.removeItem(at: root) }
        // 解压失败属于安装阶段:必须报 installFailed,而不是 requestFailed。
        let zip = root.appendingPathComponent("broken.zip")
        try Data("not a zip archive".utf8).write(to: zip)
        let into = root.appendingPathComponent("staged", isDirectory: true)
        let installer = UpdateInstaller(relaunch: { _ in })
        do {
            try installer.unzip(zip: zip, into: into)
            Issue.record("expected installFailed")
        } catch {
            if case .installFailed = error as? UpdateError {
                // 预期的安装阶段错误分类,无需断言具体退出码。
            } else {
                Issue.record("expected installFailed, got \(error)")
            }
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
