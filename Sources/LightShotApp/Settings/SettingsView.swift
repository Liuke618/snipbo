import AppKit
import LightShotCore
import SwiftUI

/// The form shown in the Settings window. Every binding writes through
/// `SettingsModel`, which persists the change and applies it live.
@MainActor
struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    private let labelWidth: CGFloat = 190

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
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(L10n.tr("Hotkey", "快捷键"), labelWidth: labelWidth) {
                HotkeyRecorderView(hotkey: $model.settings.hotkey)
                    .frame(width: 220, height: 32)
            }

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

            DisclosureGroup(L10n.tr("Per-mode shortcuts", "分模式快捷键")) {
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
                .padding(.vertical, 4)
            }
            .padding(.vertical, 4)

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
            }

            groupDivider

            VStack(spacing: 8) {
                SettingsRow(L10n.tr("Cursor", "光标"), labelWidth: labelWidth) {
                    Toggle(L10n.tr("Capture cursor", "捕捉鼠标指针"), isOn: $model.settings.captureCursor)
                        .toggleStyle(.checkbox)
                }

                SettingsRow(L10n.tr("After capture", "截图后"), labelWidth: labelWidth) {
                    HStack(spacing: 14) {
                        Toggle(L10n.tr("Open editor", "打开编辑器"), isOn: $model.settings.openEditorAfterCapture)
                            .toggleStyle(.checkbox)
                        Toggle(L10n.tr("Copy", "复制"), isOn: $model.settings.afterCaptureCopy)
                            .toggleStyle(.checkbox)
                        Toggle(L10n.tr("Save", "保存"), isOn: $model.settings.afterCaptureSave)
                            .toggleStyle(.checkbox)
                    }
                }

                SettingsRow(L10n.tr("Launch", "启动"), labelWidth: labelWidth) {
                    Toggle(L10n.tr("Start at login", "登录时启动"), isOn: $model.settings.launchAtLogin)
                        .toggleStyle(.checkbox)
                }

                SettingsRow(L10n.tr("Export", "导出"), labelWidth: labelWidth) {
                    Toggle(L10n.tr("Downscale retina captures to 1x", "Retina 截图缩至 1x"), isOn: $model.settings.retinaDownscale)
                        .toggleStyle(.checkbox)
                }

                SettingsRow(L10n.tr("Esc in editor", "编辑器 Esc 键"), labelWidth: labelWidth) {
                    Toggle(L10n.tr("Copy image before closing", "关闭前复制图像"), isOn: $model.settings.copyOnEditorEscape)
                        .toggleStyle(.checkbox)
                }

                SettingsRow(L10n.tr("Countdown", "倒计时"), labelWidth: labelWidth) {
                    Stepper(
                        "\(model.settings.captureDelaySeconds) s",
                        value: $model.settings.captureDelaySeconds,
                        in: 0...30
                    )
                }

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

                SettingsRow(L10n.tr("Window capture", "窗口截图"), labelWidth: labelWidth) {
                    Toggle(L10n.tr("Trim shadow", "裁掉阴影"), isOn: $model.settings.windowShadowTrim)
                        .toggleStyle(.checkbox)
                }

            }

            groupDivider

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
        .padding(20)
        .frame(width: 560)
    }

    private var groupDivider: some View {
        Divider()
            .padding(.vertical, 10)
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
