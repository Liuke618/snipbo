enum EditorTool: String, CaseIterable {
    case select, arrow, rectangle, ellipse, line, freehand, highlight, text, pixelate, crop

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
        case .crop: return "Crop"
        }
    }
}
