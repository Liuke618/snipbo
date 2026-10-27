import Foundation
import SnipboCore

/// Display names for the status-menu entries. Shared by the menu itself and
/// the Settings sheet that decides which entries are shown.
extension StatusMenuItem {
    var title: String {
        switch self {
        case .region: return L10n.tr("Capture Region", "区域截图")
        case .window: return L10n.tr("Capture Window", "窗口截图")
        case .appWindows: return L10n.tr("Capture App Windows", "应用全部窗口")
        case .screen: return L10n.tr("Capture Screen", "屏幕截图")
        case .allScreens: return L10n.tr("Capture All Screens", "全部屏幕")
        case .timed: return L10n.tr("Timed Capture", "延时截图")
        case .lastRegion: return L10n.tr("Capture Last Region", "上次区域截图")
        case .presets: return L10n.tr("Region Presets", "区域预设")
        case .scrolling: return L10n.tr("Scrolling Capture", "滚动截图")
        case .record: return L10n.tr("Record", "录制")
        case .recent: return L10n.tr("Recent", "最近截图")
        case .history: return L10n.tr("History Browser…", "历史浏览…")
        case .pins: return L10n.tr("Pins", "贴图")
        }
    }
}
