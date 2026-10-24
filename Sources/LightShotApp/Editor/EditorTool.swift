enum EditorTool: String, CaseIterable {
    case select, arrow, rectangle, ellipse, line, freehand, highlight, text, pixelate
    case blur, spotlight, counter, magnifier
    case crop

    var title: String {
        switch self {
        case .select: return "Select"
        case .arrow: return "Arrow"
        case .rectangle: return "Rect"
        case .ellipse: return "Ellipse"
        case .line: return "Line"
        case .freehand: return "Draw"
        case .highlight: return "Highlight"
        case .text: return "Text"
        case .pixelate: return "Pixelate"
        case .blur: return "Blur"
        case .spotlight: return "Spotlight"
        case .counter: return "Counter"
        case .magnifier: return "Magnifier"
        case .crop: return "Crop"
        }
    }
}
