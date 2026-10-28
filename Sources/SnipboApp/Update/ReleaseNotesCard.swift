import SnipboCore
import SwiftUI

/// Release notes as a scrollable card that fills the height its parent
/// proposes. Overlay scrollers stay hidden until a scroll, so a bottom fade
/// signals that longer notes continue below the fold.
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
            .padding(.top, 10)
            // At the end of the scroll the last line sits above the fade.
            .padding(.bottom, 32)
        }
        .scrollIndicators(.visible)
        .frame(minHeight: 120, maxHeight: .infinity)
        .background(Color(nsColor: DesignTokens.Color.raised))
        .overlay(alignment: .bottom) {
            // Softens the clipped line at the fold and signals that the notes
            // continue below; overlay scrollers stay hidden until a scroll.
            LinearGradient(
                colors: [
                    Color(nsColor: DesignTokens.Color.raised).opacity(0),
                    Color(nsColor: DesignTokens.Color.raised),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 24)
            .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
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
