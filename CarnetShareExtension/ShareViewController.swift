import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The share sheet: what is being saved, and for an article a fold — « Why
/// keep this? » — holding the note (typed or dictated), closed unless the page
/// came with a highlighted passage. No tags: the household files the article
/// under one of the member's domains, and the last screen says which, with
/// *Change*. The view is SwiftUI (ShareSheetView); everything that sends lives
/// here.
class ShareViewController: UIViewController {
    private let model = ShareModel()
    private let dictation = ShareDictation()

    private var sharedURL: String?
    private var sharedPage: WebPage?
    /// The page's own title and picture, asked of the system while the member
    /// writes their note — only when the share brought an address and no page.
    private var linkCover: Task<LinkCover.Found, Never>?
    private var sharedFileData: Data?
    private var sharedFilename: String?

    private enum ShareMode { case url, file, book }
    private var mode: ShareMode = .url

    /// The saved article, for filing it elsewhere from the last screen.
    private var saved: CarnetAPI.SavedArticle?
    /// The sheet's closing, put off while the member chooses a domain.
    private var closing: DispatchWorkItem?

    override func viewDidLoad() {
        super.viewDidLoad()
        let sheet = ShareSheetView(
            model: model,
            dictation: dictation,
            onCancel: { [weak self] in self?.didTapCancel() },
            onSave: { [weak self] in self?.didTapSave() },
            onChoosing: { [weak self] in self?.closing?.cancel() },
            onChoose: { [weak self] choice in self?.choose(choice) },
            onDone: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        )
        let host = UIHostingController(rootView: sheet)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
        extractContent()
    }

    private func extractContent() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return }
        SharedContentLoader.load(from: items) { [weak self] content in
            guard let self else { return }
            switch content {
            case .webPage(let page):
                self.sharedPage = page
                self.model.fullPage = !page.html.isEmpty
                self.configureForURL(page.url, title: page.title, selection: page.selection)
                // Safari brings the page, not its picture: ask the link
                // preview for the thumbnail only.
                self.startLinkCover(page.url)
            case .url(let url):
                self.configureForURL(url)
                self.startLinkCover(url)
            case .file(let data, let filename):
                self.configureForFile(data: data, filename: filename)
            case nil:
                self.model.title = L("share.nothing")
                self.model.canSave = false
            }
        }
    }

    private func configureForURL(_ urlString: String, title: String = "", selection: String = "") {
        mode = .url
        sharedURL = urlString
        model.kind = .article
        model.title = title.isEmpty ? urlString : title
        model.detail = Self.host(of: urlString)
        model.allowsNote = true
        model.canSave = true
        // The passage you highlighted is usually the reason you are saving it —
        // and what is about to be sent as a note has to be in sight.
        if !selection.isEmpty, model.note.isEmpty {
            model.note = selection
            model.foldOpen = true
        }
    }

    private func configureForFile(data: Data, filename: String) {
        // An EPUB or a PDF goes to the household's library, where Carnet
        // reads books; anything else is kept as a document.
        mode = CarnetAPI.isLibraryBook(filename) ? .book : .file
        sharedFileData = data
        sharedFilename = filename
        model.kind = mode == .book ? .book : .document
        model.title = filename
        model.detail = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        model.allowsNote = false
        model.canSave = true
    }

    /// « lemonde.fr » for the card, from the address.
    private static func host(of urlString: String) -> String {
        guard let host = URL(string: urlString)?.host() else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Any app but Safari hands over an address and nothing else. Ask the
    /// system's link preview for the rest now, so it is ready by the save —
    /// and its picture for the card.
    private func startLinkCover(_ urlString: String) {
        guard let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else { return }
        let task = Task { await LinkCover.fetch(url) }
        linkCover = task
        Task { @MainActor [weak self] in
            let found = await task.value
            guard let self else { return }
            if let jpeg = found.jpeg { self.model.thumb = UIImage(data: jpeg) }
            if let title = found.title, !title.isEmpty, self.model.title == urlString { self.model.title = title }
        }
    }

    private func didTapCancel() {
        dictation.cancel()
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func didTapSave() {
        view.endEditing(true)
        model.canSave = false

        let comment: String? = {
            let raw = model.note.trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? nil : raw
        }()

        let queue = OfflineQueue.shared
        // Remember which item we queued: the immediate send below dequeues on
        // success, and dequeuing "the last pending item" instead would drop
        // somebody else's queued work whenever the queue was not empty.
        let queuedID = UUID()

        switch mode {
        case .url:
            guard let url = sharedURL else { return finish(message: L("share.nothing"), ok: false) }
            let page = sharedPage
            let htmlData = page?.html.isEmpty == false ? Data(page!.html.utf8) : nil
            let item = QueueItem(
                id: queuedID,
                type: .articleScrape,
                createdAt: Date(),
                payload: QueuePayload(
                    url: url,
                    comment: comment,
                    sourceClient: "ios-share",
                    title: page?.title,
                    selection: page?.selection,
                    hasHtml: htmlData != nil
                )
            )
            // The DOM goes to the file store, not the manifest: it is megabytes,
            // and without it a retry would fall back to a server-side fetch —
            // straight back into the paywall this whole path exists to get past.
            queue.enqueue(item, fileData: htmlData)

        case .file, .book:
            guard let data = sharedFileData, let filename = sharedFilename else {
                return finish(message: L("share.nothing"), ok: false)
            }
            let mimeType = filename.hasSuffix(".pdf") ? "application/pdf" : "application/octet-stream"
            let item = QueueItem(
                id: queuedID,
                type: mode == .book ? .libraryBook : .fileUpload,
                createdAt: Date(),
                payload: QueuePayload(
                    filename: filename,
                    mimeType: mimeType,
                    sourceClient: "ios-share"
                )
            )
            queue.enqueue(item, fileData: data)
            if mode == .book { return sendBook(data: data, filename: filename, queuedID: queuedID) }
        }

        // A file is queued for the main app to upload; nothing more happens here.
        guard mode == .url, let url = sharedURL else {
            return finish(message: L("share.queued"), ok: false)
        }

        model.phase = .working(L("share.saving"))

        // Wait for the send before dismissing.
        //
        // `completeRequest` tears this process down, so a fire-and-forget Task
        // is killed with it. That was survivable when the payload was a bare
        // URL and the request usually won the race against an 0.8s timer; with
        // megabytes of rendered DOM it never does — the item would stay queued,
        // the app would re-send the same megabytes, and the "bookmark" outcome
        // would never be seen. Bounded, because a share sheet must not hang on
        // a slow network: past the deadline the item simply stays queued, which
        // is exactly what the queue is for.
        let page = sharedPage
        let selection = selectionWorthSending(page?.selection, comment: comment)
        Task { [weak self] in
            let saved = await Self.withTimeout(seconds: 15) {
                try await CarnetAPI.saveArticle(
                    url: url,
                    comment: comment,
                    html: page?.html,
                    title: page?.title,
                    selection: selection
                )
            }
            guard let self else { return }
            guard let saved else {
                return await MainActor.run { self.finish(message: L("share.queued"), ok: false) }
            }
            queue.dequeue(queuedID)
            // Saved without a picture, and the link preview is at work or
            // done: bring the cover before leaving. Bounded like the save — a
            // share sheet must not hang on a slow page; without it the article
            // is simply as bare as it would have been.
            if (saved.image ?? "").isEmpty, let cover = self.linkCover {
                await MainActor.run { self.model.phase = .working(L("share.cover")) }
                let found = await Self.withTimeout(seconds: 10) { await cover.value }
                if let jpeg = found?.jpeg {
                    _ = await Self.withTimeout(seconds: 12) {
                        try await CarnetAPI.setCover(collection: "articles", locale: saved.locale ?? "fr", slug: saved.slug, jpeg: jpeg)
                    }
                }
            }
            await MainActor.run {
                let (message, ok) = Self.outcome(saved)
                self.saved = saved
                self.model.filed = saved.domain
                self.model.choices = saved.domain_choices ?? []
                // Where it was filed is worth a glance, and *Change* a moment.
                let filing = ok && !self.model.choices.isEmpty
                self.finish(message: message, ok: ok, hold: filing ? 3 : ok ? 1.2 : 2.4)
            }
        }
    }

    /// A book is sent at once, the sheet waiting on it: the library says
    /// whether it took it. Past the wait, or without a network, it stays
    /// queued and Carnet sends it; a refusal is said here, and not queued.
    private func sendBook(data: Data, filename: String, queuedID: UUID) {
        model.phase = .working(L("share.adding_book"))
        let queue = OfflineQueue.shared
        Task { [weak self] in
            let sent = await Self.withTimeout(seconds: 90) { () -> Result<CarnetAPI.CalibreAddResult, Error> in
                do { return .success(try await CarnetAPI.addBookToCalibre(data: data, filename: filename)) }
                catch { return .failure(error) }
            }
            guard let self else { return }
            await MainActor.run {
                switch sent {
                case .success(let added)?:
                    queue.dequeue(queuedID)
                    self.finish(message: L(added.alreadyThere ? "share.book_already" : "share.book_added"), ok: true, hold: 1.6)
                case .failure(CarnetAPI.APIError.serverError(let message))?:
                    queue.dequeue(queuedID)
                    self.finish(message: message, ok: false, hold: 3)
                case .failure?, nil:
                    self.finish(message: L("share.queued"), ok: false)
                }
            }
        }
    }

    private static func outcome(_ saved: CarnetAPI.SavedArticle) -> (String, ok: Bool) {
        if saved.needs_capture == true {
            // The site refused the server and this share carried no rendered
            // DOM — say so, rather than let a bookmark pass for a saved article.
            return (L("share.bookmark"), false)
        }
        if saved.duplicate == true { return (L("share.duplicate"), true) }
        return (L("share.saved"), true)
    }

    /// Run `op`, giving up on the wait (not the work) after `seconds`.
    private static func withTimeout<T: Sendable>(
        seconds: Double,
        _ op: @escaping @Sendable () async throws -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { try? await op() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// The highlighted passage, unless it is already the comment.
    ///
    /// It is pre-filled into the comment box, so sending it separately as well
    /// writes the same text into the fiche twice — once as the lead quote, once
    /// as the reader's note.
    private func selectionWorthSending(_ selection: String?, comment: String?) -> String? {
        guard let selection, !selection.isEmpty else { return nil }
        return selection == comment ? nil : selection
    }

    /// Bail out of a save that had nothing to send, without leaving the sheet
    /// spinning on a disabled button.
    private func finish(message: String, ok: Bool, hold: Double = 1.2) {
        withAnimation(.snappy) { model.phase = .done(message, ok: ok) }
        closeAfter(hold)
    }

    private func closeAfter(_ seconds: Double) {
        closing?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        closing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// File the saved article under another domain, or none, then close.
    private func choose(_ choice: CarnetAPI.DomainChoice?) {
        guard let saved else { return }
        model.filingError = nil
        Task { @MainActor [weak self] in
            do {
                let now = try await CarnetAPI.setArticleDomain(slug: saved.slug, locale: saved.locale, domainId: choice?.id)
                guard let self else { return }
                withAnimation(.snappy) {
                    self.model.filed = now
                    self.model.choosing = false
                }
                self.closeAfter(0.9)
            } catch {
                self?.model.filingError = L("share.change_failed")
            }
        }
    }
}
