import SwiftUI
import UIKit

// MARK: - Highlight palette
//
// The default highlight is a wash of ink, not a colour — the theme has no
// accent. It is stored under the key "yellow", the default the server and the
// highlights already made carry. The three tints stay for a member who wants
// to tell passages apart; they are the one place a hue appears on the page.

enum HighlightPalette {
    /// Background tint for a highlight colour key.
    static func uiColor(_ key: String) -> UIColor {
        switch key {
        case "green": return UIColor(red: 0.60, green: 0.80, blue: 0.52, alpha: 0.40)
        case "pink":  return UIColor(red: 0.93, green: 0.60, blue: 0.70, alpha: 0.38)
        case "blue":  return UIColor(red: 0.55, green: 0.68, blue: 0.90, alpha: 0.36)
        default:      return CarnetTheme.uiInk(0.11, dark: 0.16) // "yellow": the ink wash
        }
    }
    static func color(_ key: String) -> Color { Color(uiColor(key)) }
    static let keys = HighlightColor.allCases.map(\.rawValue)
}

// MARK: - Highlightable chapter text (UIScrollView + UITextView bridge)

/// A UIKit-owned scroll view holding the chapter's (non-scrolling) text view.
/// Owning the UIScrollView directly — instead of nesting the text in a SwiftUI
/// ScrollView — gives us full control of contentOffset, which is what makes
/// exact save/restore of the reading position possible.
final class ChapterScrollView: UIScrollView {
    let textView = UITextView()
    /// Character index to bring to the top on the next layout pass.
    var pendingRestoreChar: Int? = nil
    var onRestored: (() -> Void)? = nil
    private var lastLayoutWidth: CGFloat = 0
    /// What scrolls above the text, in the same flow: an article's heading.
    private var headerHost: UIHostingController<AnyView>?
    private var headerHeight: CGFloat = 0
    /// The margin on each side of the text, kept inside the scroll view: the
    /// view itself runs edge to edge, so its scroll indicator is at the edge
    /// of the screen and not against the last letters of each line.
    var sideInset: CGFloat = 0 {
        didSet { if sideInset != oldValue { setNeedsTextLayout() } }
    }
    /// Go back to the very top on the next layout — once the insets are known.
    var pendingTop = false

    init() {
        super.init(frame: .zero)
        alwaysBounceVertical = false
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 2, left: 0, bottom: 28, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.dataDetectorTypes = []
        addSubview(textView)
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    /// Put a view above the text, scrolling with it — or take it away.
    func setHeader(_ view: AnyView?) {
        if let view {
            if let host = headerHost {
                host.rootView = view
            } else {
                let host = UIHostingController(rootView: view)
                host.view.backgroundColor = .clear
                host.safeAreaRegions = []
                addSubview(host.view)
                headerHost = host
            }
        } else {
            headerHost?.view.removeFromSuperview()
            headerHost = nil
        }
        setNeedsTextLayout()
    }

    /// The room the reader's floating chrome takes at the top and the bottom,
    /// when the text runs under it: it starts below the one, ends above the
    /// other, and scrolls beneath both. Given by the reader rather than left
    /// to the safe area, which does not reach a view that ignores it.
    func setChromeInsets(_ insets: UIEdgeInsets) {
        guard contentInset != insets || contentInsetAdjustmentBehavior != .never else { return }
        // Still at the very top: stay there, under the new top bar.
        let atTop = contentOffset.y <= -contentInset.top + 1
        contentInsetAdjustmentBehavior = .never
        contentInset = insets
        verticalScrollIndicatorInsets = insets
        if atTop, pendingRestoreChar == nil {
            setContentOffset(CGPoint(x: 0, y: -insets.top), animated: false)
        }
    }

    /// Re-measure the text on the next layout (text/width/font changed).
    func setNeedsTextLayout() {
        lastLayoutWidth = 0
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Size the text view to fit its content at our width; that becomes the
        // scrollable content.
        if bounds.width > 0, bounds.width != lastLayoutWidth {
            lastLayoutWidth = bounds.width
            let width = max(0, bounds.width - 2 * sideInset)
            if let host = headerHost {
                let size = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
                headerHeight = ceil(size.height)
                host.view.frame = CGRect(x: sideInset, y: 0, width: width, height: headerHeight)
            } else {
                headerHeight = 0
            }
            let fit = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            textView.frame = CGRect(x: sideInset, y: headerHeight, width: width, height: ceil(fit.height))
            contentSize = CGSize(width: bounds.width, height: textView.frame.maxY)
        }
        if pendingTop, bounds.height > 0 {
            pendingTop = false
            if pendingRestoreChar == nil {
                setContentOffset(CGPoint(x: 0, y: -adjustedContentInset.top), animated: false)
            }
        }
        // Apply a pending restore once we have real geometry. A character index is
        // exact regardless of layout timing (a fraction of contentSize is not).
        if let char = pendingRestoreChar, bounds.height > 0, textView.textStorage.length > 0 {
            let loc = min(max(0, char), textView.textStorage.length - 1)
            textView.layoutManager.ensureLayout(for: textView.textContainer)
            let glyphs = textView.layoutManager.glyphRange(forCharacterRange: NSRange(location: loc, length: 1),
                                                           actualCharacterRange: nil)
            let rect = textView.layoutManager.boundingRect(forGlyphRange: glyphs, in: textView.textContainer)
            // The line lands just under the top bar, when there is one.
            let top = adjustedContentInset.top
            let target = headerHeight + rect.minY + textView.textContainerInset.top - top
            let maxY = max(-top, contentSize.height - bounds.height + adjustedContentInset.bottom)
            setContentOffset(CGPoint(x: 0, y: min(max(-top, target), maxY)), animated: false)
            pendingRestoreChar = nil
            onRestored?()
        }
    }

    /// The character index at the top of the visible area — what we save.
    var topVisibleCharacter: Int {
        let y = max(0, contentOffset.y + adjustedContentInset.top - headerHeight - textView.textContainerInset.top)
        let glyph = textView.layoutManager.glyphIndex(for: CGPoint(x: 4, y: y), in: textView.textContainer)
        return textView.layoutManager.characterIndexForGlyph(at: glyph)
    }
}

/// Read-only chapter text with passage highlights rendered inline, a custom
/// "Highlight" action on selection, and exact scroll save/restore (by top
/// visible character index). SwiftUI `Text` exposes neither the selected range
/// nor custom menu actions, so this bridges UIKit.
struct HighlightableText: UIViewRepresentable {
    let text: String
    var fontSize: CGFloat
    var highlights: [Highlight]
    /// What the page set apart — headings, bold, italic — as ranges in `text`.
    var styles: [TextStyle] = []
    /// A view that scrolls above the text, in its flow. Rebuilt only when
    /// `headerKey` changes: this view re-renders on every scroll report.
    var header: AnyView? = nil
    var headerKey: String = ""
    /// The height of the reader's chrome over the text, top and bottom, when
    /// the text runs the whole screen beneath it. Nil: the text keeps to its frame.
    var chromeInsets: UIEdgeInsets? = nil
    /// The margin on each side of the text, inside the scroll view.
    var sideInset: CGFloat = 0
    /// Character index to bring to the top when this chapter first lays out.
    var initialCharIndex: Int = 0
    /// Reports the top visible character index as the user scrolls.
    var onTopChar: ((Int) -> Void)? = nil
    /// Whether the reader's chrome should show: false once the reader scrolls
    /// on into the text, true when they scroll back, at the top, at the end.
    var onChromeVisible: ((Bool) -> Void)? = nil
    var onCreate: (_ range: NSRange, _ quote: String) -> Void
    var onTapHighlight: (_ highlight: Highlight) -> Void

    func makeUIView(context: Context) -> ChapterScrollView {
        let sv = ChapterScrollView()
        sv.delegate = context.coordinator            // scroll reporting
        sv.textView.delegate = context.coordinator   // selection menu
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        sv.textView.addGestureRecognizer(tap)
        context.coordinator.scrollView = sv
        return sv
    }

    func updateUIView(_ sv: ChapterScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        let hlKey = highlights.map { "\($0.id):\($0.startOffset ?? -1):\($0.endOffset ?? -1):\($0.color)" }
            .joined(separator: ",") + "|styles:\(styles.count)"
        sv.sideInset = sideInset
        if let chromeInsets { sv.setChromeInsets(chromeInsets) }
        if c.lastHeaderKey != headerKey {
            c.lastHeaderKey = headerKey
            sv.setHeader(header)
        }
        if c.lastText != text {
            // New chapter: reset to the top and arm the saved-position restore.
            c.lastText = text
            c.lastHighlightKey = hlKey
            c.lastFontSize = fontSize
            c.didRestore = false
            c.chromeShown = true
            sv.textView.attributedText = c.makeAttributed()
            sv.pendingTop = true
            sv.setNeedsTextLayout()
        } else if c.lastHighlightKey != hlKey || c.lastFontSize != fontSize {
            // Same chapter, new attributes (highlight added / font size changed):
            // refresh and re-anchor to the character the reader is looking at.
            let keep = sv.topVisibleCharacter
            c.lastHighlightKey = hlKey
            c.lastFontSize = fontSize
            sv.textView.attributedText = c.makeAttributed()
            sv.setNeedsTextLayout()
            if c.didRestore, keep > 0 { sv.pendingRestoreChar = keep }
        }
        // else: unrelated re-render — leave the scroll view alone.

        if !c.didRestore {
            sv.pendingRestoreChar = initialCharIndex > 0 ? initialCharIndex : nil
            // Nothing to restore → scroll reporting can start immediately.
            if sv.pendingRestoreChar == nil { c.didRestore = true }
        }
        sv.onRestored = { c.didRestore = true }
    }

    static func dismantleUIView(_ sv: ChapterScrollView, coordinator: Coordinator) {
        coordinator.stopWatchingTaps()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: HighlightableText
        weak var scrollView: ChapterScrollView?
        var textView: UITextView? { scrollView?.textView }
        var lastText: String? = nil
        var lastHighlightKey = ""
        var lastHeaderKey: String? = nil
        var lastFontSize: CGFloat = 0
        var didRestore = false
        /// The last offset seen, and how far the reader has gone one way since
        /// the chrome last changed: a jitter of a few points does not count.
        private var lastY: CGFloat? = nil
        private var travel: CGFloat = 0
        /// As the reader last heard it. A new text starts with the chrome
        /// shown: the reader shows it again on a chapter or a view changed.
        var chromeShown = true
        /// While a passage is selected, a tap anywhere in the window lets it go.
        /// A read-only text view keeps its selection when the tap lands outside
        /// it — in the margins, on the heading, on the chrome — and even inside
        /// it, where our own tap recognizer takes the tap from its own.
        private var outsideTap: UITapGestureRecognizer?
        /// The selection as it was when the tap began: a menu action the tap
        /// lands on (Select All) may change it, and that one is kept.
        private var selectionAtTap: NSRange?
        init(_ p: HighlightableText) { parent = p }

        func scrollViewDidScroll(_ sv: UIScrollView) {
            followChrome(sv)
            // Only genuine user scrolls — not the initial zero or the restore jump
            // (both happen before didRestore flips), and not the text view itself.
            guard didRestore, sv === scrollView, let report = parent.onTopChar,
                  let top = scrollView?.topVisibleCharacter else { return }
            report(top)
        }

        /// Down into the text hides the chrome, back up shows it; the top and
        /// the end of the text always show it.
        private func followChrome(_ sv: UIScrollView) {
            guard sv === scrollView, let report = parent.onChromeVisible else { return }
            let y = sv.contentOffset.y
            defer { lastY = y }
            guard didRestore, sv.isDragging || sv.isDecelerating, let last = lastY else { return }
            let top = -sv.adjustedContentInset.top
            let end = sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom
            var show: Bool? = nil
            if y <= top + 24 || y >= end - 24 {
                show = true
            } else {
                let dy = y - last
                travel = (dy > 0) == (travel > 0) ? travel + dy : dy
                if travel > 28 { show = false } else if travel < -28 { show = true }
            }
            if let show, show != chromeShown {
                chromeShown = show
                travel = 0
                report(show)
            }
        }

        func makeAttributed() -> NSAttributedString {
            // Reading text: the system font at a 1.55 line height (the system's
            // own leading is about 1.2, the rest is added here).
            let font = UIFont.systemFont(ofSize: parent.fontSize)
            let para = NSMutableParagraphStyle()
            para.lineSpacing = parent.fontSize * 0.35
            para.paragraphSpacing = parent.fontSize * 0.88
            para.hyphenationFactor = 1
            let s = NSMutableAttributedString(
                string: parent.text,
                attributes: [.font: font, .foregroundColor: CarnetTheme.uiInk(),
                             .paragraphStyle: para, .kern: -0.2]
            )
            let ns = parent.text as NSString
            let n = ns.length
            // Blank lines between paragraphs would each add a full line plus
            // the paragraph spacing, on top of the spacing the paragraphs
            // already carry. They are flattened rather than removed: every
            // offset (highlights, reading position) counts them.
            let flat = NSMutableParagraphStyle()
            flat.maximumLineHeight = 0.01
            flat.paragraphSpacing = 0
            ns.enumerateSubstrings(in: NSRange(location: 0, length: n), options: .byLines) { line, _, enclosing, _ in
                if (line ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                    s.addAttribute(.paragraphStyle, value: flat, range: enclosing)
                }
            }
            // What the page set apart. A heading is a little larger and heavier;
            // bold and italic are added to whatever font the stretch has, so a
            // bold word inside an italic sentence is both.
            for st in parent.styles {
                guard st.start >= 0, st.end <= n, st.start < st.end else { continue }
                let range = NSRange(location: st.start, length: st.end - st.start)
                switch st.kind {
                case "heading":
                    s.addAttribute(.font, value: UIFont.systemFont(ofSize: parent.fontSize * 1.12, weight: .semibold),
                                   range: range)
                case "strong": Self.addTrait(.traitBold, to: s, in: range, base: font)
                case "em": Self.addTrait(.traitItalic, to: s, in: range, base: font)
                default: break
                }
            }
            for h in parent.highlights {
                guard let start = h.startOffset, let end = h.endOffset,
                      start >= 0, end <= n, start < end else { continue }
                s.addAttribute(.backgroundColor, value: HighlightPalette.uiColor(h.color),
                               range: NSRange(location: start, length: end - start))
            }
            return s
        }

        private static func addTrait(_ trait: UIFontDescriptor.SymbolicTraits, to s: NSMutableAttributedString,
                                     in range: NSRange, base: UIFont) {
            var runs: [(UIFont, NSRange)] = []
            s.enumerateAttribute(.font, in: range) { value, sub, _ in
                runs.append(((value as? UIFont) ?? base, sub))
            }
            for (f, sub) in runs {
                let traits = f.fontDescriptor.symbolicTraits.union(trait)
                guard let d = f.fontDescriptor.withSymbolicTraits(traits) else { continue }
                s.addAttribute(.font, value: UIFont(descriptor: d, size: f.pointSize), range: sub)
            }
        }

        /// Inject a "Highlight" action into the selection menu (iOS 16+).
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0 else { return nil }
            let quote = (textView.text as NSString).substring(with: range)
            let highlight = UIAction(title: "Highlight",
                                     image: UIImage(systemName: "highlighter")) { [weak self, weak textView] _ in
                self?.parent.onCreate(range, quote)
                textView?.selectedTextRange = nil
            }
            return UIMenu(children: [highlight] + suggestedActions)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            if textView.selectedRange.length > 0 { watchTaps(in: textView.window) } else { stopWatchingTaps() }
        }

        private func watchTaps(in window: UIWindow?) {
            guard let window, outsideTap?.view !== window else { return }
            stopWatchingTaps()
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleOutsideTap(_:)))
            tap.cancelsTouchesInView = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
            outsideTap = tap
        }

        func stopWatchingTaps() {
            if let tap = outsideTap { tap.view?.removeGestureRecognizer(tap) }
            outsideTap = nil
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard g === outsideTap, let tv = textView else { return true }
            // A tap on the selection itself brings its menu back, as elsewhere.
            if let range = tv.selectedTextRange, !range.isEmpty,
               tv.selectionRects(for: range).contains(where: { $0.rect.contains(touch.location(in: tv)) }) {
                return false
            }
            selectionAtTap = tv.selectedRange
            return true
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc private func handleOutsideTap(_ g: UITapGestureRecognizer) {
            let before = selectionAtTap
            // After the tap has done what it does — a menu action, a button —
            // so that an action on the selection still finds it.
            DispatchQueue.main.async { [weak self] in
                guard let tv = self?.textView, tv.selectedRange.length > 0, tv.selectedRange == before else { return }
                tv.selectedTextRange = nil
            }
        }

        /// Tap on an existing highlight → open it — unless the tap is letting a
        /// selection go.
        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let tv = textView, tv.selectedRange.length == 0,
                  let pos = tv.closestPosition(to: g.location(in: tv)) else { return }
            let idx = tv.offset(from: tv.beginningOfDocument, to: pos)
            for h in parent.highlights {
                if let s = h.startOffset, let e = h.endOffset, idx >= s, idx < e {
                    parent.onTapHighlight(h)
                    return
                }
            }
        }
    }
}

// MARK: - Highlight editor sheet (new + existing)

/// Where a highlight was made — lets the editor offer "link to the garden"
/// (a resonance: the quote + note land on the target fiche with a [[wiki-link]]
/// back to this source).
struct ResonanceSource {
    let label: String
    /// [[basename]] when the source lives in the garden (an article fiche).
    var basename: String? = nil
    /// Calibre-side source: the server matches the title to a garden book fiche.
    var bookTitle: String? = nil
}

/// Create or edit a highlight — choose a colour, add an optional note, or delete.
struct HighlightEditorSheet: View {
    let quote: String
    @State var color: String
    @State var note: String
    /// Present a Delete button when editing an existing highlight.
    var isEditing: Bool
    /// When set (and creating), the sheet offers linking the passage to a
    /// garden entry; the resonance is sent alongside the save.
    var resonance: ResonanceSource? = nil
    var onSave: (_ color: String, _ note: String) -> Void
    var onDelete: (() -> Void)? = nil
    /// The passage's conversation with Maurice, when it has one: what it came
    /// to is shown here, and the conversation opens from here.
    var conversation: HighlightConversation? = nil
    /// When set, the sheet offers talking the passage over with Maurice: the
    /// highlight is saved as it stands, then the conversation opens.
    var onTalk: ((_ color: String, _ note: String) -> Void)? = nil

    @State private var linkTarget: LinkTarget?
    @State private var picking = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GridLabel("Highlight")

            // Quoted passage
            Text(quote)
                .font(CarnetTheme.sans(14))
                .foregroundStyle(CarnetTheme.ink)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HighlightPalette.color(color),
                            in: RoundedRectangle(cornerRadius: CarnetTheme.innerCornerRadius, style: .continuous))

            // Colour swatches
            HStack(spacing: 12) {
                ForEach(HighlightColor.allCases) { c in
                    Button { color = c.rawValue } label: {
                        Circle()
                            .fill(HighlightPalette.color(c.rawValue))
                            .frame(width: 26, height: 26)
                            .overlay(Circle().strokeBorder(CarnetTheme.ink,
                                                           lineWidth: color == c.rawValue ? 2 : 0))
                    }.buttonStyle(.plain)
                }
                Spacer()
            }

            GridLabel("Note · optional", size: 9)
            TextEditor(text: $note)
                .font(CarnetTheme.sans(15))
                .frame(minHeight: 80)
                .carnetField()

            // Resonance — file this passage on another entry's fiche, as a
            // literal [[wiki-link]] block. Creation only: an edited highlight's
            // resonance already lives in the markdown.
            if resonance != nil, !isEditing {
                Button { picking = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "leaf").font(.system(size: 13))
                        if let t = linkTarget {
                            Text(t.title).font(CarnetTheme.sans(13.5, weight: .semibold))
                            GridLabel("[[\(t.linkBasename)]]", size: 8.5, color: CarnetTheme.inkMute)
                            Spacer()
                            Button { linkTarget = nil } label: {
                                Image(systemName: "xmark").font(.system(size: 11))
                                    .foregroundStyle(CarnetTheme.inkMute)
                            }.buttonStyle(.plain)
                        } else {
                            Text("Link to…").font(CarnetTheme.sans(13.5, weight: .medium))
                                .foregroundStyle(CarnetTheme.inkSoft)
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(CarnetTheme.inkMute)
                        }
                    }
                    .foregroundStyle(CarnetTheme.ink)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .overlay(RoundedRectangle(cornerRadius: CarnetTheme.fieldCornerRadius, style: .continuous)
                        .strokeBorder(CarnetTheme.ruleHard, lineWidth: CarnetTheme.hairline))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if let conversation { talkedOver(conversation) }
            if conversation == nil, let onTalk, MauriceApp.installed {
                Button {
                    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                    onTalk(color, trimmed)
                    sendResonanceIfLinked(note: trimmed)
                    dismiss()
                } label: {
                    HStack(spacing: 9) {
                        MauriceMark(size: 22)
                        Text("Talk it over with Maurice").font(CarnetTheme.sans(13.5, weight: .medium))
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(CarnetTheme.inkMute)
                    }
                    .foregroundStyle(CarnetTheme.ink)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .overlay(RoundedRectangle(cornerRadius: CarnetTheme.fieldCornerRadius, style: .continuous)
                        .strokeBorder(CarnetTheme.ruleHard, lineWidth: CarnetTheme.hairline))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            HStack {
                if isEditing, let onDelete {
                    GridButton(title: "Delete", small: true) { onDelete(); dismiss() }
                }
                Spacer()
                GridButton(title: "Cancel", small: true) { dismiss() }
                GridButton(title: "Save", primary: true, small: true) {
                    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(color, trimmed)
                    sendResonanceIfLinked(note: trimmed)
                    dismiss()
                }
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassSheetBackground()
        .presentationDetents(detents)
        .sheet(isPresented: $picking) {
            LinkTargetPicker { linkTarget = $0 }
        }
    }

    private var detents: Set<PresentationDetent> {
        if conversation != nil { return [.medium, .large] }
        let talk = onTalk != nil && MauriceApp.installed ? 56.0 : 0
        return [.height((resonance != nil && !isEditing ? 380 : 320) + talk), .medium]
    }

    /// What the conversation opened from this passage came to, and the way
    /// back to it. The summary is the one on the book's fiche, written once
    /// the conversation has settled.
    private func talkedOver(_ c: HighlightConversation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                MauriceMark(size: 18)
                GridLabel("Talked over with Maurice", size: 9)
                Spacer(minLength: 0)
                if MauriceApp.installed {
                    Button { MauriceApp.open(conversation: c.id) } label: {
                        Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(CarnetTheme.inkSoft)
                            .frame(width: 32, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open in Maurice")
                }
            }
            if let summary = c.summary {
                ScrollView {
                    ReplyText(markdown: summary, style: ReplyStyle(bodySize: 14, lineSpacing: 2.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            } else {
                Text("Maurice writes what came of it once the conversation has settled.")
                    .font(CarnetTheme.sans(12.5)).foregroundStyle(CarnetTheme.inkMute)
            }
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(CarnetTheme.ruleHard, lineWidth: CarnetTheme.hairline))
    }

    /// The linked half of the save. Fire-and-forget alongside the highlight —
    /// the quote and the note land on the target fiche with the source link.
    private func sendResonanceIfLinked(note: String) {
        guard let target = linkTarget, let src = resonance else { return }
        let quote = self.quote
        Task {
            do {
                try await GardenAPI.createResonance(
                    to: target, comment: note, quote: quote,
                    sourceLabel: src.bookTitle == nil ? src.label : nil,
                    sourceBasename: src.basename,
                    sourceBookTitle: src.bookTitle)
            } catch {
                print("[resonance] failed to write to \(target.slug): \(error)")
            }
        }
    }
}
