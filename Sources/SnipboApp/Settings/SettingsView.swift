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
            ("timedWindow", L10n.tr("Timed window hotkey", "延时窗口热键")),
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
                case .actions: actionsTab
                case .advanced: advancedTab
                case .export: exportTab
                case .recording: recordingTab
                case .updates: updatesTab
                case .about: aboutTab
                }
            }
            // Fixed content height: switching tabs swaps rows in place instead
            // of resizing the window, which read as constant jumpy resizing.
            // 536 pt fits the tallest tab (General with appearance and quality).
            .padding(20)
            .frame(width: 560, height: 536, alignment: .top)
        }
        .frame(width: 560)
        .sheet(isPresented: $tabModel.showsStatusMenuItems) {
            StatusMenuItemsSheet(model: model, isPresented: $tabModel.showsStatusMenuItems)
        }
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
            .frame(width: 60, height: 48)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(selected ? 0.08 : (hovered ? 0.06 : 0)))
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

            SettingsRow(L10n.tr("Appearance", "外观"), labelWidth: labelWidth) {
                Picker("", selection: $model.settings.appearance) {
                    Text(L10n.tr("Follow System", "跟随系统")).tag(AppAppearance.system)
                    Text(L10n.tr("Light", "浅色")).tag(AppAppearance.light)
                    Text(L10n.tr("Dark", "深色")).tag(AppAppearance.dark)
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
                            .textSelection(.enabled)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(L10n.tr("Choose…", "选择…")) { chooseFolder() }
                            .controlSize(.small)
                    }
                }

                SettingsRow(L10n.tr("Save format", "保存格式"), labelWidth: labelWidth) {
                    Picker("", selection: $model.settings.format) {
                        Text("PNG").tag(ImageFormat.png)
                        Text("JPEG").tag(ImageFormat.jpeg)
                        Text("HEIC").tag(ImageFormat.heic)
                        Text("AVIF").tag(ImageFormat.avif)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 160)
                }

                if model.settings.format.isLossy {
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
                    Toggle(L10n.tr("Downscale captures to 1x", "截图缩至 1x"), isOn: $model.settings.retinaDownscale)
                        .toggleStyle(.checkbox)
                }
            }

            groupDivider

            VStack(spacing: 8) {
                SettingsRow(L10n.tr("Scroll height", "滚动高度"), labelWidth: labelWidth) {
                    SettingsNumberField(
                        value: $model.settings.scrollMaxHeight,
                        range: 1_000...100_000,
                        step: 1_000,
                        suffix: "px"
                    )
                }

                SettingsRow(L10n.tr("Scroll speed", "滚动速度"), labelWidth: labelWidth) {
                    SettingsNumberField(
                        value: $model.settings.scrollCaptureFPS,
                        range: 5...30,
                        step: 1,
                        suffix: "fps"
                    )
                }
            }

            groupDivider

            VStack(spacing: 8) {
                SettingsRow(L10n.tr("Launch", "启动"), labelWidth: labelWidth) {
                    Toggle(L10n.tr("Start at login", "登录时启动"), isOn: $model.settings.launchAtLogin)
                        .toggleStyle(.checkbox)
                }

                SettingsRow(L10n.tr("Menu bar", "菜单栏"), labelWidth: labelWidth) {
                    // The hint sits beside the checkbox so showing it never
                    // changes the row height or shifts the rows below.
                    HStack(spacing: 10) {
                        Toggle(L10n.tr("Hide menu bar icon", "隐藏菜单栏图标"), isOn: $model.settings.hideMenuBarIcon)
                            .toggleStyle(.checkbox)
                        if model.settings.hideMenuBarIcon {
                            Text(L10n.tr(
                                "Reopen from Spotlight or Finder",
                                "Spotlight/访达重开可回到设置"
                            ))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        }
                        Button(L10n.tr("Menu items…", "菜单项…")) {
                            tabModel.showsStatusMenuItems = true
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    }
                }

                SettingsRow(L10n.tr("Default after capture", "默认截图后"), labelWidth: labelWidth) {
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
                    SettingsNumberField(
                        value: $model.settings.captureDelaySeconds,
                        range: 0...30,
                        step: 1,
                        suffix: "s"
                    )
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

    // MARK: - Actions

    private var actionsTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.tr(
                "Choose what happens after each capture mode. Opening the editor takes precedence; copy, save, and pin run only when the editor is off.",
                "为每种截图模式指定截图后的动作。打开编辑器优先；只有在不打开编辑器时才执行复制、保存或贴图。"
            ))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            groupDivider

            HStack(spacing: 0) {
                Text(L10n.tr("Mode", "模式"))
                    .frame(width: 150, alignment: .leading)
                ForEach(actionColumnTitles, id: \.self) { title in
                    Text(title)
                        .frame(width: 50)
                }
                Spacer()
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)

            VStack(spacing: 2) {
                ForEach(AppSettings.hotkeyModeIDs, id: \.self) { mode in
                    HStack(spacing: 0) {
                        Text(modeName(mode))
                            .frame(width: 150, alignment: .leading)
                        actionToggle(mode, keyPath: \.openEditor)
                        actionToggle(mode, keyPath: \.copy)
                        actionToggle(mode, keyPath: \.save)
                        actionToggle(mode, keyPath: \.pin)
                        Spacer()
                        if model.settings.modeActions[mode] != nil {
                            Button {
                                model.settings.modeActions[mode] = nil
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .help(L10n.tr("Use the default actions", "恢复默认动作"))
                        } else {
                            Text(L10n.tr("Default", "默认"))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(height: 26)
                }
            }

            groupDivider

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("Selection constraints", "选区约束"))
                    .font(.system(size: 13, weight: .semibold))

                SettingsRow(L10n.tr("Snap", "吸附"), labelWidth: labelWidth) {
                    Toggle(
                        L10n.tr("Snap edges to windows", "边缘吸附窗口"),
                        isOn: $model.settings.selectionSnapToWindows
                    )
                    .toggleStyle(.checkbox)
                }

                SettingsRow(L10n.tr("Aspect ratio", "比例"), labelWidth: labelWidth) {
                    Picker("", selection: $model.settings.selectionAspectRatio) {
                        ForEach(SelectionAspectRatio.allCases, id: \.self) { ratio in
                            Text(aspectTitle(ratio)).tag(ratio)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 160)
                }

                SettingsRow(L10n.tr("Fixed size", "固定尺寸"), labelWidth: labelWidth) {
                    HStack(spacing: 8) {
                        SettingsNumberField(
                            value: $model.settings.selectionFixedWidth,
                            range: 0...20_000,
                            step: 10,
                            suffix: nil
                        )
                        Text("×").foregroundStyle(.secondary)
                        SettingsNumberField(
                            value: $model.settings.selectionFixedHeight,
                            range: 0...20_000,
                            step: 10,
                            suffix: "px"
                        )
                        if model.settings.selectionFixedWidth == 0 {
                            Text(L10n.tr("0 = off", "0 = 关闭"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            groupDivider

            HStack {
                Text(L10n.tr(
                    "A capture always keeps at least one destination: if every action is off, Copy is enabled.",
                    "截图始终保留至少一个去向：全部动作关闭时会自动启用复制。"
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.tr("Reset All", "全部恢复默认")) {
                    model.settings.modeActions = [:]
                }
                .controlSize(.small)
                .disabled(model.settings.modeActions.isEmpty)
            }
        }
    }

    private func aspectTitle(_ ratio: SelectionAspectRatio) -> String {
        switch ratio {
        case .free: return L10n.tr("Free", "自由")
        case .square: return "1:1"
        case .fourThree: return "4:3"
        case .sixteenNine: return "16:9"
        }
    }

    private var actionColumnTitles: [String] {
        [
            L10n.tr("Editor", "编辑器"),
            L10n.tr("Copy", "复制"),
            L10n.tr("Save", "保存"),
            L10n.tr("Pin", "贴图"),
        ]
    }

    private func actionToggle(
        _ mode: String,
        keyPath: WritableKeyPath<CaptureActions, Bool>
    ) -> some View {
        Toggle("", isOn: actionBinding(mode, keyPath: keyPath))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .frame(width: 50)
    }

    private func actionBinding(
        _ mode: String,
        keyPath: WritableKeyPath<CaptureActions, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { model.settings.actions(for: mode)[keyPath: keyPath] },
            set: { enabled in
                var actions = model.settings.actions(for: mode)
                actions[keyPath: keyPath] = enabled
                model.settings.modeActions[mode] = actions
            }
        )
    }

    private func modeName(_ mode: String) -> String {
        switch mode {
        case "region": return L10n.tr("Region", "区域")
        case "window": return L10n.tr("Window", "窗口")
        case "screen": return L10n.tr("Screen", "屏幕")
        case "allScreens": return L10n.tr("All screens", "全部屏幕")
        case "timedRegion": return L10n.tr("Timed region", "延时区域")
        case "timedScreen": return L10n.tr("Timed screen", "延时屏幕")
        case "timedWindow": return L10n.tr("Timed window", "延时窗口")
        case "lastRegion": return L10n.tr("Last region", "上次区域")
        case "scrolling": return L10n.tr("Scrolling", "滚动")
        default: return mode
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
                    SettingsNumberField(
                        value: $model.settings.historyMaxItems,
                        range: 1...1000,
                        step: 1,
                        suffix: nil
                    )
                }

                SettingsRow(L10n.tr("Search index", "搜索索引"), labelWidth: labelWidth) {
                    Toggle(
                        L10n.tr("Index screenshot text locally", "本地索引截图文字"),
                        isOn: $model.settings.historySearchEnabled
                    )
                    .toggleStyle(.checkbox)
                }

                SettingsRow(L10n.tr("On quit", "退出时"), labelWidth: labelWidth) {
                    Toggle(L10n.tr("Clear history", "清空历史"), isOn: $model.settings.clearHistoryOnQuit)
                        .toggleStyle(.checkbox)
                }
            }
        }
    }

    // MARK: - Export

    private var exportTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 8) {
                SettingsRow(L10n.tr("Target size", "目标大小"), labelWidth: labelWidth) {
                    HStack(spacing: 8) {
                        SettingsNumberField(
                            value: $model.settings.targetFileSizeKB,
                            range: 0...100_000,
                            step: 100,
                            suffix: "KB"
                        )
                        if model.settings.targetFileSizeKB == 0 {
                            Text(L10n.tr("0 = keep quality", "0 = 不限制"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                SettingsRow(L10n.tr("File name", "文件名"), labelWidth: labelWidth) {
                    TextField(
                        "",
                        text: $model.settings.fileNameTemplate,
                        prompt: Text("Snipbo-{datetime}")
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .help(L10n.tr(
                        "Tokens: {date} {time} {datetime} {source} {app} {window} {n}",
                        "可用变量：{date} {time} {datetime} {source} {app} {window} {n}"
                    ))
                }

                HStack(spacing: 0) {
                    Spacer().frame(width: labelWidth + 12)
                    Text(L10n.tr(
                        "Tokens: {date} {time} {datetime} {source} {app} {window} {n}",
                        "可用变量：{date} {time} {datetime} {source} {app} {window} {n}"
                    ))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            groupDivider

            VStack(spacing: 8) {
                SettingsRow(L10n.tr("Watermark", "水印"), labelWidth: labelWidth) {
                    HStack(spacing: 10) {
                        Toggle("", isOn: $model.settings.watermarkEnabled)
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                        TextField(
                            "",
                            text: $model.settings.watermarkText,
                            prompt: Text("Snipbo")
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .disabled(!model.settings.watermarkEnabled)
                    }
                }

                SettingsRow(L10n.tr("Position", "位置"), labelWidth: labelWidth) {
                    Picker("", selection: $model.settings.watermarkPosition) {
                        ForEach(WatermarkPosition.allCases, id: \.self) { position in
                            Text(watermarkTitle(position)).tag(position)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 160)
                    .disabled(!model.settings.watermarkEnabled)
                }

                SettingsRow(L10n.tr("Opacity", "不透明度"), labelWidth: labelWidth) {
                    HStack(spacing: 8) {
                        Slider(
                            value: $model.settings.watermarkOpacity,
                            in: 0.05...1
                        )
                        .disabled(!model.settings.watermarkEnabled)
                        Text("\(Int((model.settings.watermarkOpacity * 100).rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            }

            groupDivider

            VStack(spacing: 8) {
                SettingsRow(L10n.tr("Beautify", "美化"), labelWidth: labelWidth) {
                    Toggle(
                        L10n.tr("Add padding and background", "添加留白与背景"),
                        isOn: $model.settings.beautifyEnabled
                    )
                    .toggleStyle(.checkbox)
                }

                SettingsRow(L10n.tr("Padding", "留白"), labelWidth: labelWidth) {
                    SettingsNumberField(
                        value: $model.settings.beautifyPadding,
                        range: 0...200,
                        step: 4,
                        suffix: "px"
                    )
                    .disabled(!model.settings.beautifyEnabled)
                }

                SettingsRow(L10n.tr("Corner radius", "圆角"), labelWidth: labelWidth) {
                    SettingsNumberField(
                        value: $model.settings.beautifyCornerRadius,
                        range: 0...80,
                        step: 2,
                        suffix: "px"
                    )
                    .disabled(!model.settings.beautifyEnabled)
                }

                SettingsRow(L10n.tr("Background", "背景"), labelWidth: labelWidth) {
                    Picker("", selection: $model.settings.beautifyBackground) {
                        ForEach(BeautifyBackground.allCases, id: \.self) { background in
                            Text(backgroundTitle(background)).tag(background)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 160)
                    .disabled(!model.settings.beautifyEnabled)
                }

                SettingsRow(L10n.tr("Shadow", "阴影"), labelWidth: labelWidth) {
                    Toggle(
                        L10n.tr("Add a soft shadow", "添加柔和阴影"),
                        isOn: $model.settings.beautifyShadow
                    )
                    .toggleStyle(.checkbox)
                    .disabled(!model.settings.beautifyEnabled)
                }
            }
        }
    }

    private func watermarkTitle(_ position: WatermarkPosition) -> String {
        switch position {
        case .topLeft: return L10n.tr("Top left", "左上")
        case .topRight: return L10n.tr("Top right", "右上")
        case .bottomLeft: return L10n.tr("Bottom left", "左下")
        case .bottomRight: return L10n.tr("Bottom right", "右下")
        case .center: return L10n.tr("Center", "居中")
        }
    }

    private func backgroundTitle(_ background: BeautifyBackground) -> String {
        switch background {
        case .light: return L10n.tr("Light", "浅色")
        case .dark: return L10n.tr("Dark", "深色")
        case .blue: return L10n.tr("Blue", "蓝色")
        case .transparent: return L10n.tr("Transparent", "透明")
        }
    }

    // MARK: - Recording

    private var recordingTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 8) {
                SettingsRow(L10n.tr("Format", "格式"), labelWidth: labelWidth) {
                    Picker("", selection: $model.settings.recordingFormat) {
                        Text("MP4").tag(RecordingFormat.mp4)
                        Text("GIF").tag(RecordingFormat.gif)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 160)
                }

                SettingsRow(L10n.tr("Frame rate", "帧率"), labelWidth: labelWidth) {
                    SettingsNumberField(
                        value: $model.settings.recordingFPS,
                        range: 5...30,
                        step: 1,
                        suffix: "fps"
                    )
                }

                SettingsRow(L10n.tr("Max duration", "最长时长"), labelWidth: labelWidth) {
                    SettingsNumberField(
                        value: $model.settings.recordingMaxSeconds,
                        range: 5...600,
                        step: 5,
                        suffix: "s"
                    )
                }

                if model.settings.recordingFormat == .gif {
                    SettingsRow(L10n.tr("GIF width", "GIF 宽度"), labelWidth: labelWidth) {
                        SettingsNumberField(
                            value: $model.settings.recordingGIFMaxWidth,
                            range: 240...1_920,
                            step: 40,
                            suffix: "px"
                        )
                    }
                }
            }

            groupDivider

            Text(L10n.tr(
                "Recordings are saved to the screenshots folder. GIF is capped at 300 frames; use MP4 for longer clips.",
                "录制文件保存到截图文件夹。GIF 最多 300 帧，较长内容请用 MP4。"
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            Spacer()
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
                    "A fast, local-first screenshot and recording tool for macOS: region, window, app-window, fullscreen, horizontal and auto-scroll capture, MP4/GIF recording, an annotation editor with OCR and redaction, floating pins, and a local history.",
                    "一款快速、本地优先的 macOS 截图与录制工具：区域 / 窗口 / 应用窗口 / 全屏 / 横向与自动滚动截图、MP4/GIF 录制，带 OCR 与隐私打码的标注编辑器、贴图置顶和本地历史。"
                ))
                .font(.system(size: 12))
                Text(L10n.tr(
                    "Privacy: the app makes no network requests at all — no uploads, no telemetry, no crash reporting. Screenshots never leave your computer.",
                    "隐私：本应用不发起任何网络请求 —— 无上传、无遥测、无崩溃上报。截图永远留在你的电脑上。"
                ))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                Text(L10n.tr(
                    "History stores original captures locally as plain PNG files; enable Clear history on quit or delete them in the History browser.",
                    "历史记录以明文 PNG 保存在本地；可在设置中开启退出时清空，或在历史浏览中删除。"
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
            .padding(.vertical, 12)
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
    case general, hotkeys, actions, advanced, export, recording, updates, about

    var title: String {
        switch self {
        case .general: return L10n.tr("General", "通用")
        case .hotkeys: return L10n.tr("Hotkeys", "快捷键")
        case .actions: return L10n.tr("Actions", "动作")
        case .advanced: return L10n.tr("Advanced", "高级")
        case .export: return L10n.tr("Export", "导出")
        case .recording: return L10n.tr("Record", "录制")
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
        case .actions: return "bolt"
        case .advanced: return "slider.horizontal.3"
        case .export: return "square.and.arrow.up"
        case .recording: return "record.circle"
        case .updates: return "arrow.triangle.2.circlepath"
        case .about: return "info.circle"
        }
    }
}

/// Picks which entries the status-bar menu shows. Settings owns this choice;
/// the menu itself only reads it, so the dropdown stays uncluttered.
private struct StatusMenuItemsSheet: View {
    @ObservedObject var model: SettingsModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("Menu items", "菜单项"))
                .font(.system(size: 13, weight: .semibold))
            Text(L10n.tr(
                "Unchecked items are hidden from the menu bar menu. Settings and Quit always stay.",
                "取消勾选的条目会从菜单栏下拉菜单中隐藏；设置与退出始终保留。"
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(StatusMenuItem.allCases, id: \.self) { item in
                    Toggle(item.title, isOn: visibility(item))
                        .toggleStyle(.checkbox)
                }
            }

            HStack {
                Spacer()
                Button(L10n.tr("Done", "完成")) { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func visibility(_ item: StatusMenuItem) -> Binding<Bool> {
        Binding(
            get: { !model.settings.hiddenStatusItems.contains(item) },
            set: { visible in
                var hidden = model.settings.hiddenStatusItems
                if visible {
                    hidden.remove(item)
                } else {
                    hidden.insert(item)
                }
                model.settings.hiddenStatusItems = hidden
            }
        )
    }
}

/// Holds the tab selection and hover state; `@State` is unavailable on this
/// toolchain, and injecting the object keeps the selection across view
/// struct re-initializations.
@MainActor
final class SettingsTabSelection: ObservableObject {
    @Published var tab: SettingsTab = .general
    @Published var hovered: SettingsTab?
    /// Drives the sheet that picks which status-menu entries are shown.
    @Published var showsStatusMenuItems = false
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
        .frame(minHeight: 28)
    }
}

/// An editable number plus stepper arrows for the numeric settings.
///
/// Commit happens on Return or focus loss. Clamping lives in the binding so a
/// typed value outside `range` can never reach `AppSettings`, and the field
/// redraws with the clamped value. `@State` cannot be expanded on this
/// toolchain, so no draft string is kept.
private struct SettingsNumberField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let suffix: String?

    var body: some View {
        HStack(spacing: 8) {
            TextField(
                "",
                value: Binding(
                    get: { value },
                    set: { value = min(range.upperBound, max(range.lowerBound, $0)) }
                ),
                format: .number
            )
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: 78)

            if let suffix {
                Text(suffix)
                    .foregroundStyle(.secondary)
            }

            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
        }
    }
}
