import Foundation

/// 一条 release 说明的块级结构。行内 Markdown(加粗、链接)在文本里原样保留,
/// 由视图层用 `AttributedString` 解析;这里只负责分块,不碰行内语法。
public enum ReleaseNotesBlock: Equatable, Sendable {
    case heading(String)
    case bullet(String)
    case paragraph(String)
}

/// GitHub release body 的最小 Markdown 分块器。
///
/// 只认三种块:ATX 标题(`#`…`######`)、项目符号(`-`/`*`/`+`)和段落。
/// 连续的非空文本行合并成一段,空行分段。没有列表嵌套、引用块或代码围栏 ——
/// 说明区的用途是让人三十秒读完"这版改了什么",多出来的语法一律按段落显示。
public enum ReleaseNotes {
    /// 防止异常大的 body 拖慢首帧;截断在字符边界上。
    public static let defaultLimit = 2_000

    public static func parse(
        _ markdown: String,
        limit: Int = defaultLimit
    ) -> [ReleaseNotesBlock] {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var blocks: [ReleaseNotesBlock] = []
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }

        for rawLine in normalized.prefix(limit).split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            switch classify(String(rawLine)) {
            case .empty:
                flushParagraph()
            case .heading(let text):
                flushParagraph()
                blocks.append(.heading(text))
            case .bullet(let text):
                flushParagraph()
                blocks.append(.bullet(text))
            case .text(let text):
                paragraph.append(text)
            }
        }
        flushParagraph()
        return blocks
    }

    private enum LineKind {
        case empty
        case heading(String)
        case bullet(String)
        case text(String)
    }

    private static func classify(_ rawLine: String) -> LineKind {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return .empty }

        let hashes = line.prefix { $0 == "#" }
        if (1...6).contains(hashes.count) {
            let rest = line.dropFirst(hashes.count)
            // `#foo` is a hashtag, not a heading; ATX requires the space.
            if rest.isEmpty || rest.first == " " {
                let text = rest.trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? .empty : .heading(text)
            }
        }

        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            let text = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? .empty : .bullet(text)
        }

        return .text(line)
    }
}
