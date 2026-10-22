import AppKit
import LightShotCore
import SwiftUI

/// The form shown in the Settings window. Every binding writes through
/// `SettingsModel`, which persists the change and applies it live.
@MainActor
struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Hotkey") {
                HotkeyRecorderView(hotkey: $model.settings.hotkey)
                Text("Current: \(model.settings.hotkey.displayString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Output") {
                Text(model.settings.saveDirectory)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose Folder…") { chooseFolder() }
                Picker("Format", selection: $model.settings.format) {
                    Text("PNG").tag(ImageFormat.png)
                    Text("JPEG").tag(ImageFormat.jpeg)
                }
                if model.settings.format == .jpeg {
                    LabeledContent("Quality") {
                        Slider(value: $model.settings.jpegQuality, in: 0.1...1)
                    }
                }
            }
            Section("Capture") {
                Toggle("Capture cursor", isOn: $model.settings.captureCursor)
                Toggle("Open editor after capture", isOn: $model.settings.openEditorAfterCapture)
                Stepper(
                    "Timed capture countdown: \(model.settings.captureDelaySeconds) s",
                    value: $model.settings.captureDelaySeconds,
                    in: 0...30
                )
            }
            Section("Recognition") {
                Toggle("Simplified Chinese", isOn: languageBinding("zh-Hans"))
                Toggle("English", isOn: languageBinding("en-US"))
                Text("Text and barcodes are recognized locally with Apple's Vision framework.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("History") {
                Toggle("Keep history", isOn: $model.settings.historyEnabled)
                Stepper(
                    "Max items: \(model.settings.historyMaxItems)",
                    value: $model.settings.historyMaxItems,
                    in: 1...1000
                )
            }
        }
        .padding(20)
        .frame(width: 520)
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
                    guard languages.count > 1 else { return }
                    languages.removeAll { $0 == code }
                }
                model.settings.ocrLanguages = languages
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
