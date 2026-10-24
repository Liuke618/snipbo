enum EditorTool: String, CaseIterable {
    case select, arrow, rectangle, ellipse, line, freehand, highlight, text, pixelate
    case blur, spotlight, counter, magnifier
    case crop

    @MainActor
    var title: String {
        switch self {
        case .select: return L10n.tr("Select", "选择")
        case .arrow: return L10n.tr("Arrow", "箭头")
        case .rectangle: return L10n.tr("Rect", "矩形")
        case .ellipse: return L10n.tr("Ellipse", "椭圆")
        case .line: return L10n.tr("Line", "直线")
        case .freehand: return L10n.tr("Draw", "画笔")
        case .highlight: return L10n.tr("Highlight", "荧光笔")
        case .text: return L10n.tr("Text", "文字")
        case .pixelate: return L10n.tr("Pixelate", "像素化")
        case .blur: return L10n.tr("Blur", "模糊")
        case .spotlight: return L10n.tr("Spotlight", "聚光灯")
        case .counter: return L10n.tr("Counter", "序号")
        case .magnifier: return L10n.tr("Magnifier", "放大镜")
        case .crop: return L10n.tr("Crop", "裁剪")
        }
    }
}
