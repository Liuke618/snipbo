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
                Toggle("Capture cursor", isOn: $model.settings.captureCursor)
                Toggle("Open editor after capture", isOn: $model.settings.openEditorAfterCapture)
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
