import Foundation
import Testing
@testable import SnipboCore

@Suite("ReleaseNotesTests")
struct ReleaseNotesTests {
    @Test func parsesHeadings() {
        #expect(ReleaseNotes.parse("## What's new") == [.heading("What's new")])
        #expect(ReleaseNotes.parse("### Fixed") == [.heading("Fixed")])
        // A `#` without a following space is not a heading marker.
        #expect(ReleaseNotes.parse("#hashtag") == [.paragraph("#hashtag")])
    }

    @Test func parsesBullets() {
        #expect(ReleaseNotes.parse("- first\n- second") == [
            .bullet("first"),
            .bullet("second"),
        ])
        #expect(ReleaseNotes.parse("* star") == [.bullet("star")])
        #expect(ReleaseNotes.parse("+ plus") == [.bullet("plus")])
    }

    @Test func mergesConsecutiveParagraphLines() {
        #expect(ReleaseNotes.parse("line one\nline two") == [.paragraph("line one line two")])
    }

    @Test func blankLineSplitsParagraphs() {
        #expect(ReleaseNotes.parse("first\n\nsecond") == [
            .paragraph("first"),
            .paragraph("second"),
        ])
    }

    @Test func blockChangesFlushTheOpenParagraph() {
        #expect(ReleaseNotes.parse("intro\n- item") == [.paragraph("intro"), .bullet("item")])
        #expect(ReleaseNotes.parse("intro\n## Next") == [.paragraph("intro"), .heading("Next")])
    }

    @Test func keepsInlineMarkdownForTheViewLayer() {
        #expect(ReleaseNotes.parse("- **bold** text") == [.bullet("**bold** text")])
    }

    @Test func ignoresBlankAndWhitespaceOnlyInput() {
        #expect(ReleaseNotes.parse("") == [])
        #expect(ReleaseNotes.parse("   \n\n\t\n") == [])
    }

    @Test func toleratesCRLF() {
        #expect(ReleaseNotes.parse("## Title\r\n- item\r\n") == [
            .heading("Title"),
            .bullet("item"),
        ])
    }

    @Test func truncatesToTheCharacterLimit() {
        let long = String(repeating: "x", count: 5_000)
        let parsed = ReleaseNotes.parse(long, limit: 100)
        let rendered = parsed.reduce(0) { total, block in
            switch block {
            case .heading(let text), .bullet(let text), .paragraph(let text):
                return total + text.count
            }
        }
        #expect(rendered <= 100)
    }

    @Test func realReleaseBody() {
        let body = """
        ## What is new

        - Scroll capture stitches long pages with a live height readout.
        - The editor gained a polygon tool and a floating style panel.

        See the release page for the full list.
        """
        #expect(ReleaseNotes.parse(body) == [
            .heading("What is new"),
            .bullet("Scroll capture stitches long pages with a live height readout."),
            .bullet("The editor gained a polygon tool and a floating style panel."),
            .paragraph("See the release page for the full list."),
        ])
    }
}
