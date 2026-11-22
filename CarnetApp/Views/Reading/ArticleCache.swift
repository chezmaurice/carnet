import Foundation

/// On-device store for saved articles — the list for offline browsing, plus
/// each article's full text and summary, cached as they're read (an article is
/// one screenful of text, so there is no separate "download" gesture: opening
/// it once makes it available offline). Saved articles are a member's own, so
/// they live in that member's folder (MemberStore), never shown to whoever
/// signs in next. Nothing is read or written while no one is signed in.
enum ArticleCache {
    private static func listURL() -> URL? { MemberStore.file("articles.json") }

    private static func textURL(_ article: Article) -> URL? {
        guard let dir = MemberStore.file("articles") else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The text's revision is part of the name: when the server's text
        // changes, the copy here is simply not found and is fetched again.
        let name = MemberStore.hash("\(article.id)\(article.textRev.map { "#\($0)" } ?? "")")
        return dir.appendingPathComponent(name).appendingPathExtension("full")
    }

    // MARK: - List (offline browsing)

    static func cacheList(_ articles: [Article]) {
        guard let url = listURL() else { return }
        try? JSONEncoder().encode(articles).write(to: url, options: .atomic)
    }
    static func cachedList() -> [Article]? {
        guard let url = listURL(), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([Article].self, from: data)
    }

    // MARK: - Full text (summaries travel in the list's `summary` field)

    static func text(_ article: Article) -> String? {
        guard let url = textURL(article) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
    static func cacheText(_ article: Article, text: String, styles: [TextStyle] = []) {
        guard let url = textURL(article) else { return }
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
        try? JSONEncoder().encode(styles).write(to: stylesURL(url), options: .atomic)
    }
    /// The styles kept with the cached text — none for a copy made before
    /// there were any.
    static func styles(_ article: Article) -> [TextStyle] {
        guard let url = textURL(article), let data = try? Data(contentsOf: stylesURL(url)) else { return [] }
        return (try? JSONDecoder().decode([TextStyle].self, from: data)) ?? []
    }
    private static func stylesURL(_ text: URL) -> URL {
        text.deletingPathExtension().appendingPathExtension("styles")
    }
    static func hasText(_ article: Article) -> Bool {
        guard let url = textURL(article) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}
