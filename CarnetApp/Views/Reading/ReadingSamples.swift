#if DEBUG
import Foundation

/// Launch the app with `-carnet.previewReading` to walk the reading screens
/// on the samples below without a server or a member — how the chrome gets
/// checked on a simulator. DEBUG-only, like the samples.
enum ReadingPreview {
    static let active = ProcessInfo.processInfo.arguments.contains("-carnet.previewReading")
}

/// Sample reading data for SwiftUI previews and offline visual verification.
/// DEBUG-only — never compiled into release. Field names mirror the Maurice
/// server data-api shapes; the values are invented.
extension Book {
    // Invented titles and authors: nobody's library.
    static let samples: [Book] = [
        Book(id: 1, title: "The Slow Page: Notes on Reading with Attention",
             authors: ["A. Sample"], tags: ["Non-Fiction", "Essays"], formats: ["EPUB"],
             series: nil, description: nil, chapters: 12, summarized: 8, indexed: 8, added: "2026-01-12T09:00:00Z"),
        Book(id: 2, title: "A Field Guide to Margins", authors: ["B. Example"],
             tags: [], formats: ["EPUB"], series: nil, description: nil,
             chapters: 14, summarized: 14, indexed: 14, added: "2026-03-04T09:00:00Z"),
        Book(id: 3, title: "Letters from the Reading Room", authors: ["C. Placeholder"],
             tags: ["Non-Fiction"], formats: ["EPUB"], series: nil, description: nil,
             chapters: 9, summarized: 0, indexed: 0, added: "2026-02-20T09:00:00Z"),
        Book(id: 4, title: "The Unfinished Shelf", authors: ["D. Specimen"],
             tags: ["Fiction"], formats: ["EPUB"], series: nil, description: nil,
             chapters: 0, summarized: 0, indexed: 0, added: "2025-11-02T09:00:00Z"),
    ]
    static let sample = samples[0]
}

extension Chapter {
    static let samples: [Chapter] = [
        Chapter(index: 1, slug: "c1", title: "Introduction", wordCount: 3200, summaryWordCount: 420, hasSummary: true),
        Chapter(index: 2, slug: "c2", title: "What a page asks of us", wordCount: 2800, summaryWordCount: 380, hasSummary: true),
        Chapter(index: 3, slug: "c3", title: "Reading once, reading twice", wordCount: 4100, summaryWordCount: 510, hasSummary: true),
        Chapter(index: 4, slug: "c4", title: "The pencil", wordCount: 3600, summaryWordCount: nil, hasSummary: false),
        Chapter(index: 5, slug: "c5", title: "What we keep", wordCount: 2200, summaryWordCount: nil, hasSummary: false),
        Chapter(index: 6, slug: "c6", title: "Coming back to a book", wordCount: 3900, summaryWordCount: nil, hasSummary: false),
    ]
    static let sampleProgress = ReadingProgress(bookId: 1, chapterIndex: 2, chapterSlug: "c3", view: "full", enabled: 1, position: 0, updatedAt: nil)

    static let sampleText = """
    Most of what we read leaves no trace. We finish the page, turn it, and a week later only the outline of an idea remains. This is not a failure of memory; it is what happens when reading is a single pass.

    A second pass changes the page. The sentence that seemed plain the first time turns out to carry the argument, and we remember only what we have put into our own words.

    This book sets out a slower way of reading: fewer pages, read twice, with a pencil in hand, and a line written at the end of each chapter to say what it was for.
    """

    static let sampleSummary = """
    A single pass leaves little behind. The chapter argues for reading less and reading twice, and for writing one line per chapter in one's own words.
    """

    /// A sample highlight anchored to a phrase in `sampleText`.
    static var sampleHighlights: [Highlight] {
        let ns = sampleText as NSString
        let r = ns.range(of: "we remember only what we have put into our own words")
        guard r.location != NSNotFound else { return [] }
        return [Highlight(id: 1, bookId: 1, chapterSlug: "c3", quote: ns.substring(with: r),
                          note: "The whole premise of the book.", color: "yellow",
                          startOffset: r.location, endOffset: r.location + r.length,
                          view: "full", createdAt: nil)]
    }
}
#endif
