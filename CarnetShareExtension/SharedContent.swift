import Foundation
import UniformTypeIdentifiers

/// What the share sheet handed over, once the attachments have been read.
///
/// Deliberately free of UIKit and of `extensionContext`, so the parsing can be
/// exercised on its own: the share sheet is the one surface no test harness can
/// drive, and the reading of its payload is where the mistakes live.
enum SharedContent {
    /// Safari, with the rendered DOM from the JavaScript preprocessing file.
    case webPage(WebPage)
    /// A bare URL — every other app, and Safari before the DOM capture existed.
    case url(String)
    case file(data: Data, filename: String)
}

struct WebPage {
    var url: String
    var title: String
    /// The DOM as Safari rendered it. Empty when the page was too large to send,
    /// in which case the server falls back to fetching the URL itself.
    var html: String
    var selection: String
}

enum SharedContentLoader {
    /// The key Apple puts the JavaScript file's results under.
    static let jsResultsKey = NSExtensionJavaScriptPreprocessingResultsKey

    /// Parse the dictionary `ShareExtensionPreprocessor.js` sent back.
    static func webPage(fromPropertyList item: Any?) -> WebPage? {
        guard let outer = item as? [String: Any] else { return nil }
        // Safari nests the JS results under its own key; be tolerant of a flat
        // dictionary too, since that is what a hand-rolled caller would send.
        let results = (outer[jsResultsKey] as? [String: Any]) ?? outer
        guard let url = results["url"] as? String, !url.isEmpty else { return nil }
        return WebPage(
            url: url,
            title: results["title"] as? String ?? "",
            html: results["html"] as? String ?? "",
            selection: results["selection"] as? String ?? ""
        )
    }

    /// Read the best available content out of the share sheet's items.
    ///
    /// Every representation of every provider is inspected before deciding,
    /// rather than committing to the first type that matches: Safari sends the
    /// rendered DOM *and* a plain URL, and taking whichever came first would
    /// have thrown away the DOM half the time.
    ///
    /// A provider is not skipped once one of its types has been tried, either.
    /// One attachment often conforms to several — and when Safari's JavaScript
    /// results come back unusable (the script threw, the host is not Safari but
    /// the attachment still conforms to a property list), stopping there would
    /// discard the URL representation sitting on the same provider and report
    /// "nothing shareable" for a share the old code would have saved.
    ///
    /// Preference is webPage > url > file, arbitrated by `rank`.
    static func load(from items: [NSExtensionItem], completion: @escaping (SharedContent?) -> Void) {
        var providers: [NSItemProvider] = []
        for item in items { providers.append(contentsOf: item.attachments ?? []) }
        guard !providers.isEmpty else { return completion(nil) }

        var best: SharedContent?
        let group = DispatchGroup()
        let lock = NSLock()

        func offer(_ candidate: SharedContent?) {
            guard let candidate else { return }
            lock.lock()
            defer { lock.unlock() }
            if rank(candidate) > rank(best) { best = candidate }
        }

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier) { item, _ in
                    if let page = webPage(fromPropertyList: item) { offer(.webPage(page)) }
                    group.leave()
                }
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                    if let url = asURL(item) {
                        offer(url.isFileURL ? file(at: url) : .url(url.absoluteString))
                    }
                    group.leave()
                }
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    if let url = asURL(item), url.isFileURL { offer(file(at: url)) }
                    group.leave()
                }
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
                group.enter()
                // The suggested name often comes without its extension, and
                // the extension is how a book is told from another file.
                var suggested = provider.suggestedName ?? "shared-file"
                if (suggested as NSString).pathExtension.isEmpty {
                    if provider.hasItemConformingToTypeIdentifier(UTType.epub.identifier) { suggested += ".epub" }
                    else if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) { suggested += ".pdf" }
                }
                provider.loadItem(forTypeIdentifier: UTType.data.identifier) { item, _ in
                    if let url = item as? URL, url.isFileURL {
                        offer(file(at: url))
                    } else if let data = item as? Data {
                        offer(.file(data: data, filename: suggested))
                    }
                    group.leave()
                }
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                    if let text = item as? String, text.hasPrefix("http") { offer(.url(text)) }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) { completion(best) }
    }

    /// Coerce whatever came back for a URL type into a URL.
    ///
    /// `loadItem` is not obliged to hand back an `NSURL`: depending on how the
    /// sharing app registered the item, the same type identifier yields an
    /// `NSURL`, the URL's bytes, or a string. A share extension takes items
    /// from arbitrary third-party apps, so it has to accept all three — casting
    /// to `URL` alone silently drops the share.
    static func asURL(_ item: Any?) -> URL? {
        if let url = item as? URL { return url }
        if let url = item as? NSURL { return url as URL }
        if let string = item as? String { return URL(string: string) }
        if let data = item as? Data, let string = String(data: data, encoding: .utf8) {
            return URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    /// A rendered page beats a bare URL beats a file.
    private static func rank(_ content: SharedContent?) -> Int {
        switch content {
        case .webPage: return 3
        case .url: return 2
        case .file: return 1
        case nil: return 0
        }
    }

    private static func file(at url: URL) -> SharedContent? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return .file(data: data, filename: url.lastPathComponent)
    }
}
