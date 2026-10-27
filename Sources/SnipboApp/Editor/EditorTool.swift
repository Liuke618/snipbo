enum EditorTool: String, CaseIterable {
    case select, arrow, rectangle, ellipse, line, measure, polygon, freehand, highlight, text
    case pixelate, pixelateBrush, blur, spotlight, counter, magnifier
    case crop

    @MainActor
    var title: String {
        switch self {
        case .select: return L10n.tr("Select", "选择")
        case .arrow: return L10n.tr("Arrow", "箭头")
        case .rectangle: return L10n.tr("Rect", "矩形")
        case .ellipse: return L10n.tr("Ellipse", "椭圆")
        case .line: return L10n.tr("Line", "直线")
        case .measure: return L10n.tr("Measure", "测量")
        case .polygon: return L10n.tr("Polygon", "多边形")
        case .freehand: return L10n.tr("Draw", "画笔")
        case .highlight: return L10n.tr("Highlight", "荧光笔")
        case .text: return L10n.tr("Text", "文字")
        case .pixelate: return L10n.tr("Pixelate", "像素化")
        case .pixelateBrush: return L10n.tr("Pixelate Brush", "像素画笔")
        case .blur: return L10n.tr("Blur", "模糊")
        case .spotlight: return L10n.tr("Spotlight", "聚光灯")
        case .counter: return L10n.tr("Counter", "序号")
        case .magnifier: return L10n.tr("Magnifier", "放大镜")
        case .crop: return L10n.tr("Crop", "裁剪")
        }
    }

    /// Lucide icon file name (Resources/Icons) for the toolbar.
    var iconName: String {
        switch self {
        case .select: return "mouse-pointer-2"
        case .arrow: return "arrow-up-right"
        case .rectangle: return "square"
        case .ellipse: return "circle"
        case .line: return "slash"
        case .measure: return "ruler"
        case .polygon: return "pentagon"
        case .freehand: return "pencil"
        case .highlight: return "highlighter"
        case .text: return "type"
        case .pixelate: return "grid-3x3"
        case .pixelateBrush: return "paintbrush"
        case .blur: return "droplets"
        case .spotlight: return "flashlight"
        case .counter: return "list-ordered"
        case .magnifier: return "zoom-in"
        case .crop: return "crop"
        }
    }

    /// Single-key shortcut shown in the toolbar tooltip ("Arrow (A)") and
    /// handled by the canvas to switch tools without the mouse.
    var hotKeyLetter: String? {
        switch self {
        case .select: return "v"
        case .arrow: return "a"
        case .rectangle: return "r"
        case .ellipse: return "o"
        case .line: return "l"
        case .measure: return "u"
        case .polygon: return "g"
        case .freehand: return "d"
        case .highlight: return "h"
        case .text: return "t"
        case .pixelate: return "p"
        case .pixelateBrush: return "j"
        case .blur: return "b"
        case .spotlight: return "f"
        case .counter: return "c"
        case .magnifier: return "m"
        case .crop: return "k"
        }
    }

    static func tool(forHotKey letter: String) -> EditorTool? {
        allCases.first { $0.hotKeyLetter == letter }
    }
}
