import SwiftUI
import CryptoKit

// MARK: - Cover cache (memory + disk)

/// Persistent cache for cover art — a book's Calibre cover, an article's lead
/// image. Memory (NSCache) for the session, disk for across restarts, keyed by
/// server + an identity so different households don't collide. Covers are
/// effectively immutable, so entries never expire.
///
/// A book's identity is its bare id, unchanged from when this only held book
/// covers: changing it would orphan every cover already on disk for no gain.
enum CoverCache {
    private static let mem = NSCache<NSString, UIImage>()
    private static let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("BookCovers", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// Stable filename/key — hash of server + identity (String.hashValue is not
    /// stable across launches, so use SHA256).
    private static func key(_ identity: String) -> NSString {
        let s = "\(CarnetAPI.baseURL)#\(identity)"
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() as NSString
    }

    /// Fast, main-safe memory lookup only (no disk).
    static func memoryImage(_ identity: String) -> UIImage? {
        mem.object(forKey: key(identity))
    }

    /// Memory, then disk (read + decode off the main thread). Nil if uncached.
    static func image(_ identity: String) async -> UIImage? {
        let k = key(identity)
        if let img = mem.object(forKey: k) { return img }
        let dir = dir
        let img = await Task.detached(priority: .utility) { () -> UIImage? in
            let file = dir.appendingPathComponent(k as String).appendingPathExtension("jpg")
            guard let data = try? Data(contentsOf: file) else { return nil }
            return UIImage(data: data)
        }.value
        if let img { mem.setObject(img, forKey: k) }
        return img
    }

    static func store(data: Data, image: UIImage, identity: String) {
        let k = key(identity)
        mem.setObject(image, forKey: k)
        let file = dir.appendingPathComponent(k as String).appendingPathExtension("jpg")
        Task.detached(priority: .utility) { try? data.write(to: file, options: .atomic) }
    }
}

// MARK: - Fetch limiter

/// At most a few covers in flight at once.
///
/// A shelf hands every visible row a CoverImage the moment it is built, and a
/// library of a hundred and twenty-seven books used to fire that many requests
/// together. URLSession opens about six connections per host, so the rest sat
/// in a queue with no timeout — a handful of covers arrived and the others kept
/// their placeholder long enough to read as broken. Queueing them here instead
/// means each one waits on the server rather than on a socket.
actor CoverFetchLimiter {
    static let shared = CoverFetchLimiter(limit: 4)

    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    private func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
        // Resumed by release(), which handed its slot over without decrementing.
    }

    private func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }

    /// Run `body` holding one of the slots. Non-throwing on purpose: the caller
    /// turns every failure into a placeholder, and a slot must always come back.
    static func run<T>(_ body: () async -> T) async -> T {
        await shared.acquire()
        let result = await body()
        await shared.release()
        return result
    }
}

// MARK: - Cover image view

/// Cover art for a row: a book's Calibre cover, or an article's lead image.
/// Served from the cache when possible and otherwise fetched, falling back to
/// the lettered placeholder while loading, when there is no cover, and offline.
struct CoverImage: View {
    private let identity: String
    private let url: URL?
    /// Book covers come from the authed API; garden cover art is served open
    /// (see the server's /api/garden-images note) and needs no token.
    private let authed: Bool
    let letter: String
    var width: CGFloat = 46
    var height: CGFloat = 64

    @State private var image: UIImage?
    @State private var failed = false
    @State private var didStart = false

    private init(identity: String, url: URL?, authed: Bool, letter: String, width: CGFloat, height: CGFloat) {
        self.identity = identity
        self.url = url
        self.authed = authed
        self.letter = letter
        self.width = width
        self.height = height
        // Show instantly if it's already in memory (e.g. scrolling back).
        _image = State(initialValue: CoverCache.memoryImage(identity))
    }

    init(bookId: Int, letter: String, width: CGFloat = 46, height: CGFloat = 64) {
        self.init(identity: "\(bookId)",
                  url: URL(string: "\(CarnetAPI.baseURL)/api/v1/calibre/books/\(bookId)/cover"),
                  authed: true, letter: letter, width: width, height: height)
    }

    /// An article's lead image, when the save captured one. Identity carries the
    /// locale: two locales of the same slug are two articles.
    init(article: Article, width: CGFloat = 46, height: CGFloat = 64) {
        self.init(identity: "article:\(article.locale)/\(article.slug)",
                  url: article.coverURL, authed: false,
                  letter: article.coverLetter, width: width, height: height)
    }

    /// A shelf entry's cover: the garden's own art when it has some, else the
    /// library's cover of the book behind it, else the lettered placeholder.
    init(shelf entry: ShelfEntry, width: CGFloat = 46, height: CGFloat = 64) {
        let (identity, url, authed) = Self.source(shelf: entry)
        self.init(identity: identity, url: url, authed: authed,
                  letter: entry.coverLetter, width: width, height: height)
    }

    private static func source(shelf entry: ShelfEntry) -> (identity: String, url: URL?, authed: Bool) {
        if entry.coverURL == nil, let bookId = entry.source?.bookId {
            return ("\(bookId)", URL(string: "\(CarnetAPI.baseURL)/api/v1/calibre/books/\(bookId)/cover"), true)
        }
        return ("shelf:\(entry.id)", entry.coverURL, false)
    }

    /// A shelf entry's cover as a picture, outside a view — for the card
    /// rendered to be shared. The cache first, then the network; nil when
    /// there is none.
    static func uiImage(shelf entry: ShelfEntry) async -> UIImage? {
        let (identity, url, authed) = source(shelf: entry)
        if let cached = await CoverCache.image(identity) { return cached }
        guard let url else { return nil }
        if case .loaded(let img) = await CoverFetchLimiter.run({ await fetch(url, authed: authed, identity: identity) }) {
            return img
        }
        return nil
    }

    /// A garden entry's cover art. Identity carries the collection too: a book
    /// and an article can share a slug.
    init(entry: GardenEntry, width: CGFloat = 46, height: CGFloat = 64) {
        self.init(identity: "garden:\(entry.collection)/\(entry.locale)/\(entry.slug)",
                  url: entry.coverURL, authed: false,
                  letter: entry.coverLetter, width: width, height: height)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height)
                    .clipped()
                    .overlay(Rectangle().strokeBorder(CarnetTheme.rule, lineWidth: 1))
            } else {
                GridCover(letter: letter, width: width, height: height)
            }
        }
        // Plain Task (not `.task`) so view churn can't cancel the fetch.
        .onAppear {
            guard image == nil, !didStart else { return }
            didStart = true
            Task { await load() }
        }
        // A row keeps its state while its entry changes under it: one that
        // first showed with no cover had given up for good, and stayed on its
        // letter after the entry was given one. A new address is a new try.
        .onChange(of: url) { _, _ in
            guard image == nil else { return }
            failed = false
            didStart = true
            Task { await load() }
        }
    }

    private enum Outcome {
        case loaded(UIImage)
        case none        // no cover, or the request failed — keep the letter
        case churn       // cancelled: the view moved, let the next appear retry
    }

    private func load() async {
        guard image == nil, !failed else { return }
        // Cache (memory → disk) before hitting the network, and before taking a
        // fetch slot — a cached cover should never wait behind a download.
        if let cached = await CoverCache.image(identity) {
            image = cached
            return
        }
        guard let url else { failed = true; return }

        switch await CoverFetchLimiter.run({ await fetch(url) }) {
        case .loaded(let img): image = img
        case .none: failed = true
        case .churn: didStart = false
        }
    }

    private func fetch(_ url: URL) async -> Outcome {
        await Self.fetch(url, authed: authed, identity: identity)
    }

    private static func fetch(_ url: URL, authed: Bool, identity: String) async -> Outcome {
        var request = authed ? CarnetAPI.authorizedRequest(url: url) : URLRequest(url: url)
        // Same 15s as the API client: fail fast rather than hold a slot for the
        // default minute when the server is unreachable.
        request.timeoutInterval = 15
        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if code == 200, let img = UIImage(data: data) {
                CoverCache.store(data: data, image: img, identity: identity)
                return .loaded(img)
            }
            // 404 = no cover / endpoint not deployed; keep the placeholder.
            print("[CoverImage] \(identity): HTTP \(code) from \(url.absoluteString)")
            return .none
        } catch {
            if error.isCancellation { return .churn }
            print("[CoverImage] \(identity): \(error.localizedDescription)")
            return .none
        }
    }
}
