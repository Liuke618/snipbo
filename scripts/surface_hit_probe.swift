import AppKit
import Foundation
import SnipboCore

// Floating-surface hit-test probe (compiled together with the app sources).
//
// For every visible control in the editor toolbar and the floating style panel,
// this asks the window's content view who would receive a mouse-down at the
// control's centre. A control shadowed by another view — the panel itself, or a
// background plate that returns nil and so prunes its own subtree — is
// unclickable no matter how its target and action are wired.
//
// The toolbar keeps its plate as a sibling behind the buttons; the style panel
// hosts its controls inside the plate. Both layouts have to stay clickable.

@MainActor var failures = 0

@MainActor
func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    let mark = condition ? "PASS" : "FAIL"
    if !condition { failures += 1 }
    print("\(mark)  \(label)\(condition ? "" : " (\(detail))")")
}

@MainActor
func describeHit(_ view: NSView?) -> String {
    guard let view else { return "nil" }
    return String(describing: type(of: view))
}

@MainActor
func oid(_ view: NSView) -> String {
    String(describing: Unmanaged.passUnretained(view).toOpaque())
}

@MainActor
func collectControls(_ view: NSView, into out: inout [NSView]) {
    if view is NSControl { out.append(view) }
    for sub in view.subviews { collectControls(sub, into: &out) }
}

@MainActor
func fullyVisible(_ view: NSView) -> Bool {
    var current: NSView? = view
    while let node = current {
        if node.isHidden { return false }
        current = node.superview
    }
    return true
}

/// Who would AppKit deliver a mouse-down on the centre of `control` to?
@MainActor
func hitForControl(_ control: NSView, in content: NSView) -> NSView? {
    let point = control.convert(
        NSPoint(x: control.bounds.midX, y: control.bounds.midY),
        to: content
    )
    return content.hitTest(point)
}

/// Asserts every visible control in `container` is the view AppKit would send a
/// mouse-down on its centre to.
@MainActor
func probeClickable(
    _ container: NSView,
    named name: String,
    in content: NSView,
    atLeast minimum: Int
) {
    var controls: [NSView] = []
    collectControls(container, into: &controls)
    var probed = 0
    for control in controls {
        let cls = String(describing: type(of: control))
        // Static labels never take clicks by design.
        if let label = control as? NSTextField, !label.isEditable { continue }
        guard fullyVisible(control) else { continue }
        // This probe has no app bundle, so the toolbar's SVG-only buttons get no
        // image and collapse to zero size. A control with no area has no centre
        // to click; the real bundle gives it 16x16.
        guard control.bounds.width > 1, control.bounds.height > 1 else { continue }
        probed += 1
        let hit = hitForControl(control, in: content)
        check(
            "\(oid(control)) \(cls) receives its own click",
            hit === control,
            "hit=\(oid(hit ?? container)) \(describeHit(hit))"
        )
    }
    check("probed every \(name) control", probed >= minimum, "probed \(probed)")
}

@MainActor
func run() {
    var lastLineStyle: AnnotationLineStyle?
    var lastFillColor: Bool?
    let panel = EditorStylePanelView(
        onColor: { _ in },
        onWidth: { _ in },
        onFontSize: { _ in },
        onFontName: { _ in },
        onBold: { _ in },
        onAlignment: { _ in },
        onTextBackground: { _ in },
        onLineStyle: { lastLineStyle = $0 },
        onFill: { lastFillColor = $0 },
        onArrowStyle: { _ in }
    )
    let toolbar = EditorToolbarView(
        onTool: { _ in },
        onUndo: {},
        onRedo: {},
        onRedact: { _ in },
        onRecognize: {},
        onPin: {},
        onCopy: {},
        onSave: {},
        onShowOptions: {}
    )

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    window.contentView = content
    content.addSubview(panel)
    content.addSubview(toolbar)
    panel.translatesAutoresizingMaskIntoConstraints = false
    toolbar.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
        toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        toolbar.topAnchor.constraint(equalTo: content.topAnchor),
        panel.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
        panel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
    ])
    // Show every row: shape options on, so the line-style/fill/arrow row is live.
    panel.syncStyleControls(
        style: AnnotationStyle(),
        isText: false,
        showsShapeOptions: true,
        showsArrowStyle: true
    )
    window.layoutIfNeeded()

    // The toolbar keeps its plate as a sibling behind the buttons; the style
    // panel hosts its controls inside the plate. Both must stay clickable.
    probeClickable(toolbar, named: "toolbar", in: content, atLeast: 10)
    var panelControls: [NSView] = []
    collectControls(panel, into: &panelControls)
    probeClickable(panel, named: "style panel", in: content, atLeast: 14)

    // The click has to reach the control *and* change the style it edits.
    if let lineStyle = panelControls.first(where: {
        $0 is NSSegmentedControl && fullyVisible($0)
    }) as? NSSegmentedControl {
        lineStyle.selectedSegment = 1
        lineStyle.performClick(nil)
        check(
            "clicking the dashed segment reports .dashed",
            lastLineStyle == .dashed,
            "got \(String(describing: lastLineStyle))"
        )
    } else {
        check("found the line-style control", false)
    }
    // The fill checkbox is the panel's only visible button carrying a title: the
    // text row's bold/background buttons are hidden, and a pop-up reports its
    // item title through its NSButton inheritance.
    if let fill = panelControls.first(where: {
        guard let button = $0 as? NSButton, !($0 is NSPopUpButton) else { return false }
        return !button.title.isEmpty && fullyVisible($0)
    }) as? NSButton {
        fill.performClick(nil)
        check(
            "clicking fill reports on",
            lastFillColor == true,
            "got \(String(describing: lastFillColor))"
        )
    } else {
        check("found the fill checkbox", false)
    }
}

@main
struct SurfaceHitProbe {
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
}
