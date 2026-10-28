import AppKit
import Foundation
import SnipboCore

/// 更新流程的状态机:检查 → 提示 → 下载校验 → 安装 → 重启。
/// 所有耗时步骤在后台 Task 执行,状态回主线程发布;失败一律映射为
/// UpdateError,静默路径直接吞掉,交互路径交给 UI 展示。
@MainActor
final class UpdateCoordinator: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateRelease)
        case downloading(Double)
        case installing
        case failed(UpdateError)
    }

    /// 从 UserDefaults 读取持久化设置,读取失败回退默认值。存储方式与
    /// SettingsModel 一致:settings.v1 键下的 JSON 编码 AppSettings。
    private static func loadSettings() -> AppSettings {
        if let data = UserDefaults.standard.data(forKey: "settings.v1"),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            return decoded
        }
        return AppSettings.default
    }

    static let shared = UpdateCoordinator(settingsProvider: { UpdateCoordinator.loadSettings() })

    @Published private(set) var state: State = .idle

    private let settingsProvider: () -> AppSettings
    private let checker: UpdateChecker
    private let installer: UpdateInstaller
    private let workspace: URL

    /// 当前安装位置是否允许原位替换(开发构建不允许)。
    static var canInstallInPlace: Bool {
        guard let bundle = Bundle.main.bundleURL as URL? else { return false }
        return UpdateInstaller.isInstalledInApplications(bundle)
    }

    init(
        settingsProvider: @escaping () -> AppSettings,
        checker: UpdateChecker = UpdateChecker(),
        installer: UpdateInstaller = UpdateInstaller()
    ) {
        self.settingsProvider = settingsProvider
        self.checker = checker
        self.installer = installer
        self.workspace = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Snipbo/updates", isDirectory: true)
    }

    var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? snipboVersion
    }

    /// 启动静默检查:失败、无新版本、渠道不可用都完全无声。
    func checkSilently() {
        guard settingsProvider().autoCheckUpdates else { return }
        guard case .idle = state else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let release = try? await self.checker.check() else { return }
            await self.assess(release: release, interactive: false)
        }
    }

    /// 手动检查:结果(含失败原因)写进 state,由 Updates 页展示。
    func checkInteractively() {
        guard !isBusy else { return }
        state = .checking
        Task { [weak self] in
            guard let self else { return }
            do {
                let release = try await self.checker.check()
                await self.assess(release: release, interactive: true)
            } catch let error as UpdateError {
                self.state = .failed(error)
            } catch {
                self.state = .failed(.requestFailed(error.localizedDescription))
            }
        }
    }

    private var isBusy: Bool {
        switch state {
        case .idle, .upToDate, .available, .failed: return false
        case .checking, .downloading, .installing: return true
        }
    }

    private func assess(release: UpdateRelease, interactive: Bool) async {
        switch SemVer.compare(release.tagName, currentVersion) {
        case .orderedDescending:
            state = UpdatePackage.pick(from: release, runningVersion: currentVersion) != nil
                ? .available(release)
                : (interactive ? .failed(.noMatchingAsset) : .idle)
        case .orderedSame, .orderedAscending:
            state = interactive ? .upToDate : .idle
        case nil:
            // 版本无法比较(如预发布 tag):保守起见不提示更新。
            state = interactive ? .upToDate : .idle
        }
    }

    /// 下载校验安装重启的完整流水线。每一步失败都清理下载物。
    func downloadAndInstall() {
        guard case .available(let release) = state,
              let picked = UpdatePackage.pick(from: release, runningVersion: currentVersion)
        else { return }
        guard Self.canInstallInPlace else {
            state = .failed(.notInstalledInApplications)
            return
        }
        state = .installing
        let zipAsset = picked.zip
        let shaAsset = picked.sha256
        let expectedVersion = release.tagName.dropFirst(release.tagName.hasPrefix("v") ? 1 : 0)
        let workspace = workspace
        let installer = installer
        Task { [weak self] in
            guard let self else { return }
            do {
                let fm = FileManager.default
                try? fm.removeItem(at: workspace)
                try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
                let zipData = try await Self.download(zipAsset, progress: { fraction in
                    Task { @MainActor in self.state = .downloading(fraction) }
                })
                if let shaAsset {
                    let (shaData, _) = try await Self.downloadRaw(shaAsset.url)
                    guard UpdatePackage.verifySHA256(of: zipData, digestText: String(decoding: shaData, as: UTF8.self)) else {
                        throw UpdateError.checksumMismatch
                    }
                }
                let zipURL = workspace.appendingPathComponent(zipAsset.name)
                try zipData.write(to: zipURL)
                let extractDir = workspace.appendingPathComponent("staged", isDirectory: true)
                try installer.unzip(zip: zipURL, into: extractDir)
                let stagedApp = try installer.findStagedApp(
                    in: extractDir,
                    expectedVersion: String(expectedVersion)
                )
                self.state = .installing
                let newBundle = try installer.install(
                    stagedApp: stagedApp,
                    currentBundle: Bundle.main.bundleURL,
                    workspace: workspace,
                    newVersion: String(expectedVersion)
                )
                try installer.relaunch(newBundle: newBundle)
                NSApp.terminate(nil)
            } catch let error as UpdateError {
                self.state = .failed(error)
            } catch {
                self.state = .failed(.requestFailed(error.localizedDescription))
            }
        }
    }

    // MARK: 下载

    /// nonisolated:字节循环跑在并发执行器上,不占主线程;进度经
    /// @Sendable 闭包跳回主线程发布。
    private nonisolated static func download(
        _ asset: UpdateAsset,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data {
        let (bytes, response) = try await URLSession.shared.bytes(from: asset.url)
        let total = Int(response.expectedContentLength)
        var data = Data(capacity: max(asset.size, 0))
        var received = 0
        for try await byte in bytes {
            data.append(byte)
            received += 1
            if total > 0, received % (1 << 20) == 0 {
                progress(Double(received) / Double(total))
            }
        }
        _ = response
        return data
    }

    private nonisolated static func downloadRaw(_ url: URL) async throws -> (Data, URLResponse) {
        let (data, response) = try await URLSession.shared.data(from: url)
        return (data, response)
    }
}
