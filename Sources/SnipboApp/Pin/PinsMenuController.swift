import AppKit

/// Builds the status item's "Pins" submenu from the live pin board. The menu
/// is rebuilt each time it opens, so a pin opened or closed elsewhere is never
/// stale.
@MainActor
final class PinsMenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu(title: L10n.tr("Pins", "贴图"))
    private let pins: () -> [PinBoard.ManagedPin]
    private let showPin: (UUID) -> Void
    private let closePin: (UUID) -> Void
    private let closeAll: () -> Void
    /// Only written during init and read in deinit, where exclusive access is
    /// guaranteed; the notification block itself captures `self` weakly.
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init(
        pins: @escaping () -> [PinBoard.ManagedPin],
        showPin: @escaping (UUID) -> Void,
        closePin: @escaping (UUID) -> Void,
        closeAll: @escaping () -> Void
    ) {
        self.pins = pins
        self.showPin = showPin
        self.closePin = closePin
        self.closeAll = closeAll
        super.init()
        menu.delegate = self
        rebuild()
        observer = NotificationCenter.default.addObserver(
            forName: .snipboPinsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rebuild()
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuild()
    }

    private func rebuild() {
        menu.removeAllItems()
        let items = pins()
        guard !items.isEmpty else {
            let empty = NSMenuItem(
                title: L10n.tr("No pins", "暂无贴图"),
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        for pin in items {
            let parent = NSMenuItem(
                title: "\(L10n.tr("Pin", "贴图")) \(pin.title)",
                action: nil,
                keyEquivalent: ""
            )
            let submenu = NSMenu()
            let show = NSMenuItem(
                title: L10n.tr("Bring to Front", "显示"),
                action: #selector(showAction(_:)),
                keyEquivalent: ""
            )
            show.target = self
            show.representedObject = pin.id
            submenu.addItem(show)
            let close = NSMenuItem(
                title: L10n.tr("Close", "关闭"),
                action: #selector(closeAction(_:)),
                keyEquivalent: ""
            )
            close.target = self
            close.representedObject = pin.id
            submenu.addItem(close)
            parent.submenu = submenu
            menu.addItem(parent)
        }

        menu.addItem(.separator())
        let closeAllItem = NSMenuItem(
            title: L10n.tr("Close All Pins", "关闭全部贴图"),
            action: #selector(closeAllAction),
            keyEquivalent: ""
        )
        closeAllItem.target = self
        menu.addItem(closeAllItem)
    }

    @objc private func showAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        showPin(id)
    }

    @objc private func closeAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        closePin(id)
    }

    @objc private func closeAllAction() {
        closeAll()
    }
}
