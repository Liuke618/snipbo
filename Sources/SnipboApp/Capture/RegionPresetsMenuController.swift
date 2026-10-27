import AppKit

/// Builds the status item's named-region menu. Presets reuse the last-region
/// capture path, so they validate the display layout before capturing.
@MainActor
final class RegionPresetsMenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu(title: L10n.tr("Region Presets", "区域预设"))
    private let store: LastRegionStore
    private let capture: (NamedRegion) -> Void

    init(store: LastRegionStore, capture: @escaping (NamedRegion) -> Void) {
        self.store = store
        self.capture = capture
        super.init()
        menu.delegate = self
        rebuild()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuild()
    }

    private func rebuild() {
        menu.removeAllItems()
        let presets = store.presets()
        if presets.isEmpty {
            let empty = NSMenuItem(
                title: L10n.tr("No saved regions", "暂无区域预设"),
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for preset in presets {
                let parent = NSMenuItem(
                    title: preset.name,
                    action: nil,
                    keyEquivalent: ""
                )
                let submenu = NSMenu()
                let captureItem = NSMenuItem(
                    title: L10n.tr("Capture", "截图"),
                    action: #selector(captureAction(_:)),
                    keyEquivalent: ""
                )
                captureItem.target = self
                captureItem.representedObject = preset
                submenu.addItem(captureItem)
                let deleteItem = NSMenuItem(
                    title: L10n.tr("Delete", "删除"),
                    action: #selector(deleteAction(_:)),
                    keyEquivalent: ""
                )
                deleteItem.target = self
                deleteItem.representedObject = preset
                submenu.addItem(deleteItem)
                parent.submenu = submenu
                menu.addItem(parent)
            }
        }

        menu.addItem(.separator())
        let saveItem = NSMenuItem(
            title: L10n.tr("Save Last Region as Preset…", "把上次区域存为预设…"),
            action: #selector(saveAction),
            keyEquivalent: ""
        )
        saveItem.target = self
        menu.addItem(saveItem)
    }

    @objc private func captureAction(_ sender: NSMenuItem) {
        guard let preset = sender.representedObject as? NamedRegion else { return }
        capture(preset)
    }

    @objc private func deleteAction(_ sender: NSMenuItem) {
        guard let preset = sender.representedObject as? NamedRegion else { return }
        store.removePreset(id: preset.id)
    }

    @objc private func saveAction() {
        guard let region = store.load() else {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = L10n.tr("No region to save", "没有可保存的区域")
            alert.informativeText = L10n.tr(
                "Capture a region first, then save it as a preset.",
                "请先进行一次区域截图，再把它保存为预设。"
            )
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = L10n.tr("Save Region Preset", "保存区域预设")
        alert.informativeText = L10n.tr(
            "Enter a name for the last captured region.",
            "为上次截取的区域输入一个名称。"
        )
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = L10n.tr("Name", "名称")
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.tr("Save", "保存"))
        alert.addButton(withTitle: L10n.tr("Cancel", "取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        _ = store.savePreset(name: field.stringValue, region: region)
    }
}
