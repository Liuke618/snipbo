import AppKit
import SnipboCore
import SwiftUI

/// The form shown in the Settings window, organized like Shottr's
/// Preferences: an icon tab bar (General / Hotkeys / Advanced) over
/// divider-separated groups of label + control rows. Every binding writes
/// through `SettingsModel`, which persists the change and applies it live.
@MainActor
struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    private let labelWidth: CGFloat = 190
    /// Injected from the window controller so the selection survives view
    /// struct re-initialization (and so probes can drive tab switches).
    @ObservedObject private var tabModel: SettingsTabSelection

    init(model: SettingsModel, tabSelection: SettingsTabSelection = SettingsTabSelection()) {
        self.model = model
        self.tabModel = tabSelection
    }

    /// Modes that can carry their own chord besides the base region hotkey.
    private var extraHotkeyModes: [(String, String)] {
        [
            ("window", L10n.tr("Window hotkey", "窗口热键")),
            ("screen", L10n.tr("Screen hotkey", "屏幕热键")),
            ("allScreens", L10n.tr("All screens hotkey", "全部屏幕热键")),
            ("timedRegion", L10n.tr("Timed region hotkey", "延时区域热键")),
            ("timedScreen", L10n.tr("Timed screen hotkey", "延时屏幕热键")),
            ("lastRegion", L10n.tr("Last region hotkey", "上次区域热键")),
            ("scrolling", L10n.tr("Scrolling hotkey", "滚动热键")),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            Group {
                switch tabModel.tab {
                case .general: generalTab
                case .hotkeys: hotkeysTab
                case .advanced: advancedTab
                case .updates: updatesTab
                case .about: aboutTab
                }
            }
            // Fixed content height: switching tabs swaps rows in place instead
            // of resizing the window, which read as constant jumpy resizing.
            // 470 pt fits the tallest tab (General with the JPEG quality row).
            .padding(20)
            .frame(width: 560, height: 510, alignment: .top)
        }
        .frame(width: 560)
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(SettingsTab.allCases, id: \.rawValue) { item in
                tabButton(item)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func tabButton(_ item: SettingsTab) -> some View {
        let selected = tabModel.tab == item
        let hovered = tabModel.hovered == item
        return Button {
            tabModel.tab = item
        } label: {
            VStack(spacing: 3) {
                Image(systemName: item.icon)
                    .font(.system(size: 17, weight: .medium))
                    .frame(height: 20)
                Text(item.title)
                    .font(.system(size: 11))
            }
            .frame(width: 86, height: 48)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.primary.opacity(selected ? 0.08 : (hovered ? 0.045 : 0)))
            )
            .foregroundColor(selected ? .accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            tabModel.hovered = hovering ? item : nil
        }
    }

    // MARK: - General

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(L10n.tr("Language", "语言"), labelWidth: labelWidth) {
                Picker("", selection: $model.settings.uiLanguage) {
                    Text(L10n.tr("Follow System", "跟随系统")).tag(AppLanguage.system)
                    Text("English").tag(AppLanguage.english)
                    Text("简体中文").tag(AppLanguage.chinese)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 160)
            }

            groupDivider

            VStack(spacing: 8) {
                SettingsRow(L10n.tr("Screenshots folder", "保存文件夹"), labelWidth: labelWidth) {
                    HStack(spacing: 8) {
                        Text(model.settings.saveDirectory)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                            )
                        Button(L10n.tr("Choose…", "选择…")) { chooseFolder() }
                    }
                }

                SettingsRow(L10n.tr("Save format", "保存格式"), labelWidth: labelWidth) {
                    Picker("", selection: $model.settings.format) {
                        Text("PNG").tag(ImageFormat.png)
                        Text("JPEG").tag(ImageFormat.jpeg)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 160)
                }

                if model.settings.format == .jpeg {
                    SettingsRow(L10n.tr("Quality", "质量"), labelWidth: labelWidth) {
                        HStack(spacing: 8) {
                            Slider(value: $model.settings.jpegQuality, in: 0.1...1)
                            Text("\(Int((model.settings.jpegQuality * 100).rounded()))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                }

                SettingsRow(L10n.tr("Retina screenshots", "Retina 截图"), labelWidth: labelWidth) {
                    Toggle(L10n.tr("Downscale to 1x when saving", "保存时缩至 1x"), isOn: $model.settings.retinaDownscale)
                        .toggleStyle(.checkbox)
                }
            }

            groupDivider

            VStack(spacing: 8) {
                SettingsRow(L10n.tr("Scroll height", "滚动高度"), labelWidth: labelWidth) {
                    Stepper(
                        "\(model.settings.scrollMaxHeight) px",
                        value: $model.settings.scrollMaxHeight,
                        in: 1_000...100_000,
                        step: 1_000
                    )
                }

                SettingsRow(L10n.tr("Scroll speed", "滚动速度"), labelWidth: labelWidth) {
                    Stepper(
                        "\(model.settings.scrollCaptureFPS) fps",
                        value: $model.settings.scrollCaptureFPS,
                        in: 5...30,
                        step: 1
                    )
                }
            }

            groupDivider

            VStack(spacing: 8) {
                SettingsRow(L10n.tr("Launch", "启动"), labelWidth: labelWidth) {
                    Toggle(L10n.tr("Start at login", "登录时启动"), isOn: $model.settings.launchAtLogin)
                        .toggleStyle(.checkbox)
                }

                SettingsRow(L10n.tr("After capture", "截图后"), labelWidth: labelWidth) {
                    HStack(spacing: 14) {
                        Toggle(L10n.tr("Show editor", "打开编辑器"), isOn: $model.settings.openEditorAfterCapture)
                            .toggleStyle(.checkbox)
                        Toggle(L10n.tr("Copy", "复制"), isOn: $model.settings.afterCaptureCopy)
                            .toggleStyle(.checkbox)
                        Toggle(L10n.tr("Save", "保存"), isOn: $model.settings.afterCaptureSave)
                            .toggleStyle(.checkbox)
                    }
                }

                SettingsRow(L10n.tr("Cursor", "光标"), labelWidth: labelWidth) {
                    Toggle(L10n.tr("Capture cursor", "捕捉鼠标指针"), isOn: $model.settings.captureCursor)
                        .toggleStyle(.checkbox)
                }

                SettingsRow(L10n.tr("Countdown", "倒计时"), labelWidth: labelWidth) {
                    Stepper(
                        "\(model.settings.captureDelaySeconds) s",
                        value: $model.settings.captureDelaySeconds,
                        in: 0...30
                    )
                }

                SettingsRow(L10n.tr("Window capture", "窗口截图"), labelWidth: labelWidth) {
                    Toggle(L10n.tr("Trim shadow", "裁掉阴影"), isOn: $model.settings.windowShadowTrim)
                        .toggleStyle(.checkbox)
                }
            }
        }
    }

    // MARK: - Hotkeys

    private var hotkeysTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("Shortcut conflicts with the system screenshot keys", "快捷键与系统截图键冲突时"))
                    .font(.system(size: 13, weight: .semibold))
                Text(L10n.tr(
                    "Open System Settings → Keyboard → Keyboard Shortcuts → Screenshots and uncheck the conflicting entries.",
                    "在 系统设置 → 键盘 → 键盘快捷键 → 截图 里取消勾选冲突的系统快捷键。"
                ))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

                Button(L10n.tr("Open System Settings", "打开系统设置")) {
                    openKeyboardShortcuts()
                }
                .controlSize(.small)
            }
            .padding(.bottom, 4)

            groupDivider

            SettingsRow(L10n.tr("Hotkey", "快捷键"), labelWidth: labelWidth) {
                HotkeyRecorderView(hotkey: $model.settings.hotkey)
                    .frame(width: 220, height: 32)
            }

            groupDivider

            VStack(spacing: 8) {
                ForEach(extraHotkeyModes, id: \.0) { mode, title in
                    SettingsRow(title, labelWidth: labelWidth) {
                        HStack(spacing: 8) {
                            ModeHotkeyRecorderView(
                                hotkey: model.settings.modeHotkeys[mode],
                                onChange: { model.settings.modeHotkeys[mode] = $0 }
                            )
                            .frame(width: 210, height: 32)
                            if model.settings.modeHotkeys[mode] != nil {
                                Button(L10n.tr("Clear", "清除")) {
                                    model.settings.modeHotkeys[mode] = nil
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Advanced

    private var advancedTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 8) {
                SettingsRow(L10n.tr("OCR languages", "OCR 语言"), labelWidth: labelWidth) {
                    HStack(spacing: 16) {
                        Toggle(L10n.tr("Simplified Chinese", "简体中文"), isOn: languageBinding("zh-Hans"))
                            .toggleStyle(.checkbox)
                        Toggle(L10n.tr("English", "英语"), isOn: languageBinding("en-US"))
                            .toggleStyle(.checkbox)
                    }
                }

                SettingsRow(L10n.tr("OCR text", "OCR 文本"), labelWidth: labelWidth) {
                    Toggle(L10n.tr("Remove line breaks", "去除换行"), isOn: $model.settings.ocrRemoveLineBreaks)
                        .toggleStyle(.checkbox)
                }
            }

            groupDivider

            SettingsRow(L10n.tr("Esc in editor", "编辑器 Esc 键"), labelWidth: labelWidth) {
                HStack(spacing: 14) {
                    Toggle(L10n.tr("Copy image", "复制图像"), isOn: $model.settings.copyOnEditorEscape)
                        .toggleStyle(.checkbox)
                    Toggle(L10n.tr("Save image", "保存图像"), isOn: $model.settings.saveOnEditorEscape)
                        .toggleStyle(.checkbox)
                }
            }

            groupDivider

            VStack(spacing: 8) {
                SettingsRow(L10n.tr("History", "历史记录"), labelWidth: labelWidth) {
                    Toggle(L10n.tr("Keep history", "保留历史"), isOn: $model.settings.historyEnabled)
                        .toggleStyle(.checkbox)
                }

                SettingsRow(L10n.tr("Max items", "条数上限"), labelWidth: labelWidth) {
                    Stepper(
                        "\(model.settings.historyMaxItems)",
                        value: $model.settings.historyMaxItems,
                        in: 1...1000
                    )
                }
            }
        }
    }

    // MARK: - Updates

    private var updatesTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 8) {
                SettingsRow(L10n.tr("Current version", "当前版本"), labelWidth: labelWidth) {
                    Text(versionText)
                        .monospacedDigit()
                }
            }

            groupDivider

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("Getting updates", "获取更新"))
                    .font(.system(size: 13, weight: .semibold))
                Text(L10n.tr(
                    "This app never contacts the network, so it cannot check for updates itself. Download the newest Snipbo.app from the GitHub Releases page and drag it into /Applications to replace the old copy — your settings and history are kept.",
                    "本应用完全不联网，因此无法自动检查更新。请到 GitHub Releases 页面下载最新的 Snipbo.app，拖入 /Applications 替换旧版本即可 —— 设置与历史记录会自动保留。"
                ))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

                Button(L10n.tr("Open GitHub Releases", "打开 GitHub Releases 页面")) {
                    if let url = URL(string: "https://github.com/Liuke618/snipbo/releases") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - About

    private var aboutTab: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                Text("Snipbo")
                    .font(.system(size: 17, weight: .semibold))
                Text(L10n.tr("Version", "版本") + " \(versionText)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr(
                    "A fast, local-first screenshot tool for macOS: region, window, fullscreen, and scrolling capture; an annotation editor with OCR; floating pins; and a local history.",
                    "一款快速、本地优先的 macOS 截图工具：区域 / 窗口 / 全屏 / 滚动截图，带 OCR 识别的标注编辑器、贴图置顶和本地历史。"
                ))
                .font(.system(size: 12))
                Text(L10n.tr(
                    "Privacy: the app makes no network requests at all — no uploads, no telemetry, no crash reporting. Screenshots never leave your computer.",
                    "隐私：本应用不发起任何网络请求 —— 无上传、无遥测、无崩溃上报。截图永远留在你的电脑上。"
                ))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                Text(L10n.tr(
                    "Built with Swift and Apple frameworks only. Toolbar and menu icons are Lucide (ISC license).",
                    "仅使用 Swift 与 Apple 框架构建。工具栏与菜单图标来自 Lucide（ISC 许可证）。"
                ))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(L10n.tr("Copy Version Info", "复制版本信息")) { copyVersionInfo() }
                .controlSize(.small)
        }
        .padding(.top, 8)
    }

    // MARK: - Helpers

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "v\(version) (\(build))"
    }

    private func copyVersionInfo() {
        let macOS = ProcessInfo.processInfo.operatingSystemVersionString
        #if arch(arm64)
        let chip = "arm64"
        #elseif arch(x86_64)
        let chip = "x86_64"
        #else
        let chip = "unknown"
        #endif
        let info = "Snipbo \(versionText)\n\(macOS)\n\(chip)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(info, forType: .string)
    }

    private var groupDivider: some View {
        Divider()
            .padding(.vertical, 10)
    }

    private func openKeyboardShortcuts() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Refuses to turn off the last enabled language; OCR needs at least one.
    private func languageBinding(_ code: String) -> Binding<Bool> {
        Binding(
            get: { model.settings.ocrLanguages.contains(code) },
            set: { enabled in
                var languages = model.settings.ocrLanguages
                if enabled {
                    if !languages.contains(code) { languages.append(code) }
                } else {
                    languages.removeAll { $0 == code }
                }
                if languages.isEmpty {
                    // Republish the unchanged value so the rejected toggle
                    // snaps back instead of staying visually off.
                    model.settings.ocrLanguages = AppSettings.supportedOCRLanguages.filter(
                        model.settings.ocrLanguages.contains
                    )
                    return
                }
                // Keep Vision's language priority in supported order rather
                // than toggle-click order.
                model.settings.ocrLanguages = AppSettings.supportedOCRLanguages.filter(
                    languages.contains
                )
            }
        )
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.saveDirectory = url.path
        }
    }
}

/// The Settings window's tabs. Uploading/License/Diagnostics tabs are
/// intentionally absent: the app makes no network requests, collects nothing,
/// and has no licensing. Updates is manual-only for the same reason.
@MainActor
enum SettingsTab: String, CaseIterable {
    case general, hotkeys, advanced, updates, about

    var title: String {
        switch self {
        case .general: return L10n.tr("General", "通用")
        case .hotkeys: return L10n.tr("Hotkeys", "快捷键")
        case .advanced: return L10n.tr("Advanced", "高级")
        case .updates: return L10n.tr("Updates", "更新")
        case .about: return L10n.tr("About", "关于")
        }
    }

    /// SF Symbols keep the tab bar consistent on every macOS version without
    /// extra assets.
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .hotkeys: return "keyboard"
        case .advanced: return "slider.horizontal.3"
        case .updates: return "arrow.triangle.2.circlepath"
        case .about: return "info.circle"
        }
    }
}

/// Holds the tab selection and hover state; `@State` is unavailable on this
/// toolchain, and injecting the object keeps the selection across view
/// struct re-initializations.
@MainActor
final class SettingsTabSelection: ObservableObject {
    @Published var tab: SettingsTab = .general
    @Published var hovered: SettingsTab?
}

private struct SettingsRow<Content: View>: View {
    let label: String
    let labelWidth: CGFloat
    let content: Content

    init(_ label: String, labelWidth: CGFloat, @ViewBuilder content: () -> Content) {
        self.label = label
        self.labelWidth = labelWidth
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .frame(width: labelWidth, alignment: .trailing)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 26)
    }
}
