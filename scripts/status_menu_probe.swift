import AppKit
import Foundation
import SnipboCore

// Status-menu probe (compiled together with the app sources).
//
// The settings sheet lets the user uncheck status-menu entries, and the menu is
// only rebuilt when that set changes — so the one thing that silently rots is a
// new entry that bypasses the shared `add(_:as:to:)` filter. This asserts every
// `StatusMenuItem` really disappears when hidden, one at a time.

@MainActor var failures = 0

@MainActor
func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    let mark = condition ? "PASS" : "FAIL"
    if !condition { failures += 1 }
    print("\(mark)  \(label)\(condition ? "" : " (\(detail))")")
}

@main
struct StatusMenuProbe {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            run()
            print(failures == 0 ? "probe: all checks passed" : "probe: \(failures) check(s) failed")
            exit(failures == 0 ? 0 : 1)
        }
        while true {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    @MainActor
    static func run() {
        // Deterministic titles; the app normally follows the UI language.
        L10n.setLanguage(.english)
        SnipboCore.L10n.setLanguage(.english)

        var hidden: Set<StatusMenuItem> = []
        let controller = StatusItemController(
            onCapture: { _ in },
            onSettings: {},
            onHistoryBrowser: {},
            onCheckUpdates: {},
            hotkeyFor: { _ in nil },
            recentMenu: NSMenu(),
            pinsMenu: NSMenu(),
            presetsMenu: NSMenu(),
            lastRegionAvailable: { false },
            onQuit: {},
            hiddenStatusItems: { hidden },
            updateItemTitle: { nil }
        )

        func titles(hiding next: Set<StatusMenuItem>) -> [String] {
            hidden = next
            controller.refreshLocalization()
            return controller.statusMenu?.items.map {
                $0.isSeparatorItem ? "<sep>" : $0.title
            } ?? []
        }

        let all = StatusMenuItem.allCases
        let visible = titles(hiding: [])
        for item in all {
            check(
                "\(item.rawValue) shown when nothing is hidden",
                visible.contains(item.title),
                "menu=\(visible)"
            )
        }

        for item in all {
            let menu = titles(hiding: [item])
            check(
                "\(item.rawValue) disappears when hidden",
                !menu.contains(item.title),
                "menu=\(menu)"
            )
            let others = all.filter { $0 != item }
            let missing = others.filter { !menu.contains($0.title) }
            check(
                "\(item.rawValue) hiding leaves the other entries",
                missing.isEmpty,
                "missing=\(missing.map(\.rawValue))"
            )
        }

        // Settings and Quit are documented as always shown.
        let bare = titles(hiding: Set(all))
        check(
            "nothing from the customizable set remains",
            all.allSatisfy { !bare.contains($0.title) },
            "menu=\(bare)"
        )
        check(
            "Settings and Quit survive hiding everything",
            bare.contains(where: { $0.hasPrefix("Settings") })
                && bare.contains(where: { $0.hasPrefix("Quit") }),
            "menu=\(bare)"
        )
        let noLeadingSeparator = bare.first != "<sep>"
        let noDoubledSeparator = !zip(bare, bare.dropFirst()).contains {
            $0 == "<sep>" && $1 == "<sep>"
        }
        check(
            "hiding everything leaves no leading or doubled separator",
            noLeadingSeparator && noDoubledSeparator,
            "menu=\(bare)"
        )
    }
}
