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
    private static let extraHotkeyModes: [(String, String)] = [
        ("window", "Window hotkey"),
        ("screen", "Screen hotkey"),
        ("allScreens", "All screens hotkey"),
        ("timedRegion", "Timed region hotkey"),
        ("timedScreen", "Timed screen hotkey"),
        ("lastRegion", "Last region hotkey"),
        ("scrolling", "Scrolling hotkey"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow("Hotkey", labelWidth: labelWidth) {
                HotkeyRecorderView(hotkey: $model.settings.hotkey)
                    .frame(width: 220, height: 32)
            }

            groupDivider

            DisclosureGroup("Per-mode shortcuts") {
                VStack(spacing: 8) {
                    ForEach(Self.extraHotkeyModes, id: \.0) { mode, title in
                        SettingsRow(title, labelWidth: labelWidth) {
                            HStack(spacing: 8) {
                                ModeHotkeyRecorderView(
                                    hotkey: model.settings.modeHotkeys[mode],
                                    onChange: { model.settings.modeHotkeys[mode] = $0 }
                                )
                                .frame(width: 210, height: 32)
                                if model.settings.modeHotkeys[mode] != nil {
                                    Button("Clear") {
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
                SettingsRow("Screenshots folder", labelWidth: labelWidth) {
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
                        Button("Choose…") { chooseFolder() }
                    }
                }

                SettingsRow("Save format", labelWidth: labelWidth) {
                    Picker("", selection: $model.settings.format) {
                        Text("PNG").tag(ImageFormat.png)
                        Text("JPEG").tag(ImageFormat.jpeg)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 160)
                }

                if model.settings.format == .jpeg {
                    SettingsRow("Quality", labelWidth: labelWidth) {
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
                SettingsRow("Cursor", labelWidth: labelWidth) {
                    Toggle("Capture cursor", isOn: $model.settings.captureCursor)
                        .toggleStyle(.checkbox)
                }

                SettingsRow("After capture", labelWidth: labelWidth) {
                    HStack(spacing: 14) {
                        Toggle("Open editor", isOn: $model.settings.openEditorAfterCapture)
                            .toggleStyle(.checkbox)
                        Toggle("Copy", isOn: $model.settings.afterCaptureCopy)
                            .toggleStyle(.checkbox)
                        Toggle("Save", isOn: $model.settings.afterCaptureSave)
                            .toggleStyle(.checkbox)
                    }
                }

                SettingsRow("Launch", labelWidth: labelWidth) {
                    Toggle("Start at login", isOn: $model.settings.launchAtLogin)
                        .toggleStyle(.checkbox)
                }

                SettingsRow("Export", labelWidth: labelWidth) {
                    Toggle("Downscale retina captures to 1x", isOn: $model.settings.retinaDownscale)
                        .toggleStyle(.checkbox)
                }

                SettingsRow("Esc in editor", labelWidth: labelWidth) {
                    Toggle("Copy image before closing", isOn: $model.settings.copyOnEditorEscape)
                        .toggleStyle(.checkbox)
                }

                SettingsRow("Countdown", labelWidth: labelWidth) {
                    Stepper(
                        "\(model.settings.captureDelaySeconds) s",
                        value: $model.settings.captureDelaySeconds,
                        in: 0...30
                    )
                }

                SettingsRow("Scroll height", labelWidth: labelWidth) {
                    Stepper(
                        "\(model.settings.scrollMaxHeight) px",
                        value: $model.settings.scrollMaxHeight,
                        in: 1_000...100_000,
                        step: 1_000
                    )
                }

                SettingsRow("Scroll speed", labelWidth: labelWidth) {
                    Stepper(
                        "\(model.settings.scrollCaptureFPS) fps",
                        value: $model.settings.scrollCaptureFPS,
                        in: 5...30,
                        step: 1
                    )
                }

                SettingsRow("Window capture", labelWidth: labelWidth) {
                    Toggle("Trim shadow", isOn: $model.settings.windowShadowTrim)
                        .toggleStyle(.checkbox)
                }

            }

            groupDivider

            SettingsRow("OCR languages", labelWidth: labelWidth) {
                HStack(spacing: 16) {
                    Toggle("Simplified Chinese", isOn: languageBinding("zh-Hans"))
                        .toggleStyle(.checkbox)
                    Toggle("English", isOn: languageBinding("en-US"))
                        .toggleStyle(.checkbox)
                }
            }

            SettingsRow("OCR text", labelWidth: labelWidth) {
                Toggle("Remove line breaks", isOn: $model.settings.ocrRemoveLineBreaks)
                    .toggleStyle(.checkbox)
            }

            groupDivider

            VStack(spacing: 8) {
                SettingsRow("History", labelWidth: labelWidth) {
                    Toggle("Keep history", isOn: $model.settings.historyEnabled)
                        .toggleStyle(.checkbox)
                }

                SettingsRow("Max items", labelWidth: labelWidth) {
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
