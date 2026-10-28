import SnipboCore
import SwiftUI

/// Release notes as a fixed-height, scrollable card.
///
/// `ReleaseNotes` does the block splitting; this view only typesets. Inline
/// Markdown (bold, links) is left in the text on purpose and resolved here by
/// Foundation, so the parser stays free of presentation concerns.
struct ReleaseNotesCard: View {
    let notes: String

    private var blocks: [ReleaseNotesBlock] { ReleaseNotes.parse(notes) }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    row(block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(height: 210)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                .fill(Color(nsColor: DesignTokens.Color.raised))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                .strokeBorder(Color(nsColor: DesignTokens.Color.stroke), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func row(_ block: ReleaseNotesBlock) -> some View {
        switch block {
        case .heading(let text):
            inline(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: DesignTokens.Color.textPrimary))
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: DesignTokens.Color.textTertiary))
                inline(text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(nsColor: DesignTokens.Color.textSecondary))
            }
        case .paragraph(let text):
            inline(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Color(nsColor: DesignTokens.Color.textSecondary))
        }
    }

    /// Bold and links render; anything the inline parser rejects falls back to
    /// the literal text rather than dropping the line.
    private func inline(_ text: String) -> Text {
        guard let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return Text(text)
        }
        return Text(attributed)
    }
}
