import Foundation

/// 把校验过的更新包替换到位:解压、验证、备份旧包、替换、(由调用方)重启。
/// 全部文件系统操作可注入 relaunch,因此可脱离真实应用测试。
public struct UpdateInstaller: Sendable {
    private let relaunchAction: @MainActor @Sendable (URL) -> Void

    public init(relaunch: @escaping @MainActor @Sendable (URL) -> Void = UpdateInstaller.defaultRelaunch) {
        self.relaunchAction = relaunch
    }

    public static func defaultRelaunch(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.path]
        try? process.run()
    }

    // MARK: 包构造(测试与流水线共用)

    @discardableResult
    public static func makeFakeAppBundle(version: String, at directory: URL) throws -> URL {
        let bundle = directory.appendingPathComponent("Snipbo.app", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(
            at: bundle.appendingPathComponent("Contents/MacOS", isDirectory: true),
            withIntermediateDirectories: true
        )
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleShortVersionString</key><string>\(version)</string>
        <key>CFBundleExecutable</key><string>Snipbo</string>
        </dict></plist>
        """
        try plist.write(
            to: bundle.appendingPathComponent("Contents/Info.plist"),
            atomically: true,
            encoding: .utf8
        )
        let executable = bundle.appendingPathComponent("Contents/MacOS/Snipbo")
        let stub = "#!/bin/sh\n"
        try stub.write(to: executable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return directory
    }

    /// 读取包的 CFBundleShortVersionString;包不完整返回 nil。
    public static func stagedVersion(of bundle: URL) -> String? {
        guard let info = Bundle(url: bundle)?.infoDictionary,
              let version = info["CFBundleShortVersionString"] as? String else {
            return nil
        }
        return version
    }

    // MARK: 流水线步骤

    public func unzip(zip: URL, into directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.requestFailed("ditto exit \(process.terminationStatus)")
        }
    }

    /// 在解压目录里定位 Snipbo.app,验证可执行文件与目标版本,失败抛错。
    public func findStagedApp(in directory: URL, expectedVersion: String) throws -> URL {
        let fm = FileManager.default
        let bundle = directory.appendingPathComponent("Snipbo.app", isDirectory: true)
        guard fm.fileExists(atPath: bundle.path) else {
            throw UpdateError.installFailed("staged bundle missing")
        }
        let executable = bundle.appendingPathComponent("Contents/MacOS/Snipbo")
        guard fm.isExecutableFile(atPath: executable.path) else {
            throw UpdateError.installFailed("staged executable missing")
        }
        guard Self.stagedVersion(of: bundle) == expectedVersion else {
            throw UpdateError.installFailed("staged version mismatch")
        }
        return bundle
    }

    /// 备份当前包 → 移入新包;新包移动失败时把备份移回原位再抛错。
    @discardableResult
    public func install(
        stagedApp: URL,
        currentBundle: URL,
        workspace: URL,
        newVersion: String
    ) throws -> URL {
        let fm = FileManager.default
        guard Self.stagedVersion(of: stagedApp) == newVersion else {
            throw UpdateError.installFailed("staged version mismatch")
        }
        let backup = workspace.appendingPathComponent("backup", isDirectory: true)
        try? fm.removeItem(at: backup)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        let backupItem = backup.appendingPathComponent(currentBundle.lastPathComponent, isDirectory: true)
        try fm.moveItem(at: currentBundle, to: backupItem)
        do {
            let target = currentBundle.deletingLastPathComponent()
                .appendingPathComponent(stagedApp.lastPathComponent, isDirectory: true)
            try fm.moveItem(at: stagedApp, to: target)
            return target
        } catch {
            try? fm.moveItem(at: backupItem, to: currentBundle)
            throw UpdateError.installFailed(error.localizedDescription)
        }
    }

    /// 调用注入的 relaunch 闭包。MainActor 隔离:Swift 6 下非隔离同步方法
    /// 无法调用 @MainActor 闭包,而测试与 Task 6 的调用方都在主线程上下文。
    @MainActor
    public func relaunch(newBundle: URL) throws {
        relaunchAction(newBundle)
    }

    /// 仅当运行包位于 /Applications 或 ~/Applications 时才允许原位替换。
    public static func isInstalledInApplications(_ bundle: URL) -> Bool {
        let path = bundle.standardizedFileURL.path
        let candidates = [
            "/Applications",
            ("~/Applications" as NSString).expandingTildeInPath,
        ]
        return candidates.contains { path.hasPrefix($0 + "/") || path == $0 + "/Snipbo.app" }
    }
}
