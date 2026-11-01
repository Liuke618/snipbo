import AppKit
import CryptoKit
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
            // 网络等待期间状态可能已被交互检查/下载/安装流程改写;
            // 不再是 idle 就整体放弃,绝不能把进行中的状态冲掉。
            guard case .idle = self.state else { return }
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
        // 非交互路径兜底:检查/下载/安装进行中时一律不回写,
        // 防止未来的调用方重新引入"静默结果覆盖进行中状态"的问题。
        if !interactive, isBusy { return }
        // 发布资产按新版本命名(Snipbo-<新版本>-arm64.zip),挑选必须用
        // tag 推导的目标版本(v0.6.0 → 0.6.0),而不是正在运行的版本;
        // 与 downloadAndInstall 的推导保持一致。
        let targetVersion = String(
            release.tagName.dropFirst(release.tagName.hasPrefix("v") ? 1 : 0)
        )
        switch SemVer.compare(release.tagName, currentVersion) {
        case .orderedDescending:
            state = UpdatePackage.pick(from: release, runningVersion: targetVersion) != nil
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
        guard case .available(let release) = state else { return }
        // 资产按新版本命名,挑选用 tag 推导的目标版本(v0.6.0 → 0.6.0),
        // 与 assess 保持一致;传当前运行版本会让精确名匹配永远落空。
        let expectedVersion = String(
            release.tagName.dropFirst(release.tagName.hasPrefix("v") ? 1 : 0)
        )
        guard let picked = UpdatePackage.pick(from: release, runningVersion: expectedVersion)
        else { return }
        // 绝不安装未经完整性校验的包:release 缺 .sha256 资产即放弃安装。
        guard let shaAsset = picked.sha256 else {
            state = .failed(.noMatchingAsset)
            return
        }
        guard Self.canInstallInPlace else {
            state = .failed(.notInstalledInApplications)
            return
        }
        state = .installing
        let zipAsset = picked.zip
        let workspace = workspace
        let installer = installer
        Task { [weak self] in
            guard let self else { return }
            do {
                let fm = FileManager.default
                try? fm.removeItem(at: workspace)
                try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
                let zipURL = workspace.appendingPathComponent(zipAsset.name)
                try await Self.download(zipAsset, to: zipURL, progress: { fraction in
                    Task { @MainActor in self.state = .downloading(fraction) }
                })
                let (shaData, _) = try await Self.downloadRaw(shaAsset.url)
                guard try await Self.verifySHA256(
                    of: zipURL,
                    digestText: String(decoding: shaData, as: UTF8.self)
                ) else {
                    throw UpdateError.checksumMismatch
                }
                let extractDir = workspace.appendingPathComponent("staged", isDirectory: true)
                try installer.unzip(zip: zipURL, into: extractDir)
                let stagedApp = try installer.findStagedApp(
                    in: extractDir,
                    expectedVersion: expectedVersion
                )
                self.state = .installing
                let newBundle = try installer.install(
                    stagedApp: stagedApp,
                    currentBundle: Bundle.main.bundleURL,
                    workspace: workspace,
                    newVersion: expectedVersion
                )
                try installer.relaunch(newBundle: newBundle)
                NSApp.terminate(nil)
            } catch {
                // 失败即清理下载物:zip 与 staged 解压目录。backup 绝不删除——
                // install() 一旦开始,里面可能已是旧版的唯一副本。
                let fm = FileManager.default
                try? fm.removeItem(at: workspace.appendingPathComponent(zipAsset.name))
                try? fm.removeItem(at: workspace.appendingPathComponent("staged", isDirectory: true))
                if let error = error as? UpdateError {
                    self.state = .failed(error)
                } else {
                    // 走到这里时安装流水线早已启动(下载/校验/解压/替换),
                    // 非 UpdateError 的系统错误按 installFailed 上报,而不是
                    // 误导性的 requestFailed;检查阶段 checkInteractively
                    // 自己的 catch 仍保持 requestFailed 映射。
                    self.state = .failed(.installFailed(error.localizedDescription))
                }
            }
        }
    }

    // MARK: 下载

    /// nonisolated:下载跑在 URLSession 自己的 delegate queue 上,不占主
    /// 线程;进度经 @Sendable 闭包跳回主线程发布。zip 直接落盘(先落在系
    /// 统临时目录,完成后搬到 destination),不再整包驻留内存。
    private nonisolated static func download(
        _ asset: UpdateAsset,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let delegate = UpdateDownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(
            configuration: .ephemeral,
            delegate: delegate,
            delegateQueue: nil
        )
        do {
            _ = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    delegate.begin(continuation, session: session, remote: asset.url)
                }
            } onCancel: {
                delegate.cancelDownload()
            }
            // 下载已结束:主动失效,断开 session 对 delegate 的强引用。
            session.finishTasksAndInvalidate()
        } catch {
            session.invalidateAndCancel()
            throw error
        }
    }

    private nonisolated static func downloadRaw(_ url: URL) async throws -> (Data, URLResponse) {
        let (data, response) = try await URLSession.shared.data(from: url)
        return (data, response)
    }

    /// 流式校验下载文件的 SHA-256:zip 可达上百 MB,整包读进 Data 会顶出
    /// 驻留峰值,按 1MB 分块喂给 CryptoKit。token 解析与
    /// UpdatePackage.verifySHA256 保持一致(shasum 输出格式,大小写不敏感)。
    private nonisolated static func verifySHA256(
        of fileURL: URL,
        digestText: String
    ) async throws -> Bool {
        guard let token = digestText.split(whereSeparator: \.isWhitespace).first,
              token.count == 64,
              token.allSatisfy(\.isHexDigit) else {
            return false
        }
        return try await Task.detached(priority: .userInitiated) { () -> Bool in
            let fileHandle = try FileHandle(forReadingFrom: fileURL)
            defer { try? fileHandle.close() }
            var hasher = SHA256()
            while let chunk = try fileHandle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return hex == token.lowercased()
        }.value
    }
}

/// URLSessionDownloadDelegate 专属代理:didWriteData 节流发布进度,
/// didFinishDownloadingTo 把临时文件搬到目标位置后带回路径,
/// didCompleteWithError 负责失败。可变状态全部由 NSLock 保护——委托回调
/// 跑在 session 的串行 delegate queue 上,而任务取消可能从任意线程触发。
/// 顶层声明而不是嵌套在 UpdateCoordinator 里,避免继承其 @MainActor 隔离
/// (委托回调不在主线程上)。
private final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var finished = false
    /// 上次发布进度时的累计字节数;只在 delegate queue 上访问。
    private var lastReportedBytes: Int64 = 0

    init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
        super.init()
    }

    /// 注册 continuation 并启动下载;先于任何委托回调发生,不会丢事件。
    func begin(_ continuation: CheckedContinuation<Void, Error>, session: URLSession, remote: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else {
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        self.session = session
        session.downloadTask(with: remote).resume()
    }

    /// 任务级取消:可能从任意线程调用;只在尚未结束时起作用。
    func cancelDownload() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation?.resume(throwing: CancellationError())
        continuation = nil
        session?.invalidateAndCancel()
        session = nil
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // 与旧的字节循环一致:每 ~1MB 发布一次,总长未知时不发布。
        guard totalBytesExpectedToWrite > 0,
              totalBytesWritten - lastReportedBytes >= (1 << 20) else { return }
        lastReportedBytes = totalBytesWritten
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // 临时文件在本方法返回后即被系统删除,必须在这里搬到目标位置。
        if FileManager.default.fileExists(atPath: destination.path) {
            do {
                try FileManager.default.removeItem(at: destination)
            } catch {
                fail(error)
                return
            }
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            fail(error)
            return
        }
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation?.resume()
        continuation = nil
        self.session = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // 成功路径由 didFinishDownloadingTo 收尾;这里只处理失败。
        guard let error else { return }
        fail(error)
    }

    private func fail(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation?.resume(throwing: error)
        continuation = nil
        session = nil
    }
}
