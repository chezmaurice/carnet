#if DEBUG
import Foundation

/// Launch the app with `-carnet.previewReading` to walk the reading screens
/// on the samples below without a server or a member — how the chrome gets
/// checked on a simulator. DEBUG-only, like the samples.
enum ReadingPreview {
    static let active = ProcessInfo.processInfo.arguments.contains("-carnet.previewReading")
}

/// Sample reading data for SwiftUI previews and offline visual verification.
/// DEBUG-only — never compiled into release. Field names/values mirror the
/// live Maurice server data-api shapes.
extension Book {
    static let samples: [Book] = [
        Book(id: 29, title: "80,000 Hours: Find a fulfilling career that does good",
             authors: ["Benjamin Todd"], tags: ["Non-Fiction", "Self-Development"], formats: ["EPUB"],
             series: nil, description: nil, chapters: 12, summarized: 8, indexed: 8, added: "2026-01-12T09:00:00Z"),
        Book(id: 162, title: "Alien Information Theory", authors: ["Andrew R. Gallimore"],
             tags: [], formats: ["EPUB"], series: nil, description: nil,
             chapters: 14, summarized: 14, indexed: 14, added: "2026-03-04T09:00:00Z"),
        Book(id: 86, title: "Abduction: Human Encounters with Aliens", authors: ["John E. Mack"],
             tags: ["Non-Fiction"], formats: ["EPUB"], series: nil, description: nil,
             chapters: 9, summarized: 0, indexed: 0, added: "2026-02-20T09:00:00Z"),
        Book(id: 95, title: "Multiple Man", authors: ["Adam Crabtree"],
             tags: ["Esoteric/Hermetic"], formats: ["EPUB"], series: nil, description: nil,
             chapters: 0, summarized: 0, indexed: 0, added: "2025-11-02T09:00:00Z"),
    ]
    static let sample = samples[0]
}

extension Chapter {
    static let samples: [Chapter] = [
        Chapter(index: 1, slug: "c1", title: "Introduction", wordCount: 3200, summaryWordCount: 420, hasSummary: true),
        Chapter(index: 2, slug: "c2", title: "What makes for a dream job?", wordCount: 2800, summaryWordCount: 380, hasSummary: true),
        Chapter(index: 3, slug: "c3", title: "Don't follow your passion", wordCount: 4100, summaryWordCount: 510, hasSummary: true),
        Chapter(index: 4, slug: "c4", title: "Career capital", wordCount: 3600, summaryWordCount: nil, hasSummary: false),
        Chapter(index: 5, slug: "c5", title: "The best jobs to do good", wordCount: 2200, summaryWordCount: nil, hasSummary: false),
        Chapter(index: 6, slug: "c6", title: "How to find a job you love", wordCount: 3900, summaryWordCount: nil, hasSummary: false),
    ]
    static let sampleProgress = ReadingProgress(bookId: 29, chapterIndex: 2, chapterSlug: "c3", view: "full", enabled: 1, position: 0, updatedAt: nil)

    static let sampleText = """
    Most of us will spend about 80,000 hours in our careers: 40 hours a week, 50 weeks a year, for 40 years. This makes your choice of career one of the most important decisions you'll ever make.

    Yet most people don't approach it that way. They stumble into a field, follow the advice to "do what you're passionate about," and hope it works out. The evidence suggests there's a better way.

    In this book we set out what that better way looks like — grounded in the research on what actually makes for a fulfilling career, and on how you can use your working life to make a real difference.
    """

    static let sampleSummary = """
    Careers span roughly 80,000 working hours, making them among life's highest-stakes decisions — yet most people choose by default rather than design. This chapter argues for a research-led approach over "follow your passion."
    """

    /// A sample highlight anchored to a phrase in `sampleText`.
    static var sampleHighlights: [Highlight] {
        let ns = sampleText as NSString
        let r = ns.range(of: "one of the most important decisions you'll ever make")
        guard r.location != NSNotFound else { return [] }
        return [Highlight(id: 1, bookId: 29, chapterSlug: "c3", quote: ns.substring(with: r),
                          note: "The whole premise of the book.", color: "yellow",
                          startOffset: r.location, endOffset: r.location + r.length,
                          view: "full", createdAt: nil)]
    }
}
#endif
