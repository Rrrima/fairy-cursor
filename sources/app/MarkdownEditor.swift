import AppKit
import SwiftUI

/// Plain-text editor that styles Markdown as you type (markers stay visible, dimmed), the way
/// Bear or iA Writer do. Return continues lists; Return on an empty item ends the list.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var focusOnAppear = false
    /// Double-click while the fairy is carrying screenshots: returns the Markdown to insert at
    /// the click (the screenshots, saved as files), or nil to let the click select a word.
    var onDoubleClick: (() -> String?)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentView.drawsBackground = false

        let textView = NoteTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        textView.onDoubleClick = onDoubleClick
        scroll.documentView = textView
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.lineFragmentPadding = 0
        textView.insertionPointColor = MarkdownStyler.accent
        textView.linkTextAttributes = [
            .foregroundColor: MarkdownStyler.accent,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        textView.typingAttributes = MarkdownStyler.base
        textView.string = text
        MarkdownStyler.apply(to: textView)

        if focusOnAppear {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        (scroll.documentView as? NoteTextView)?.onDoubleClick = onDoubleClick
        guard let textView = scroll.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
        MarkdownStyler.apply(to: textView)
    }

    /// Text view that lets the fairy drop screenshots in with a double-click.
    final class NoteTextView: NSTextView {
        var onDoubleClick: (() -> String?)?

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2, let markdown = onDoubleClick?() {
                let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
                let string = self.string as NSString
                // Images go on their own lines.
                let before = index > 0 && string.character(at: index - 1) != 10 ? "\n" : ""
                let after = index < string.length && string.character(at: index) != 10 ? "\n" : ""
                insertText(before + markdown + after, replacementRange: NSRange(location: index, length: 0))
                return
            }
            super.mouseDown(with: event)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            MarkdownStyler.apply(to: textView)
            text.wrappedValue = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            return continueList(in: textView)
        }

        private static let listItem = try! NSRegularExpression(
            pattern: #"^([ \t]*)(?:([-*+])[ \t]+\[[ xX]\]|([-*+])|(\d+)([.)]))[ \t]+(.*)$"#
        )

        /// Return inside a list item starts the next item; on an empty item it ends the list.
        private func continueList(in textView: NSTextView) -> Bool {
            let string = textView.string as NSString
            let selection = textView.selectedRange()
            guard selection.length == 0 else { return false }
            let lineStart = string.lineRange(for: NSRange(location: selection.location, length: 0)).location
            let head = string.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
            let ns = head as NSString
            guard let m = Self.listItem.firstMatch(in: head, range: NSRange(location: 0, length: ns.length)) else { return false }

            func group(_ i: Int) -> String? {
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            if (group(6) ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                // Empty item: drop the marker instead of adding another one.
                textView.insertText("", replacementRange: NSRange(location: lineStart, length: selection.location - lineStart))
                return true
            }
            let indent = group(1) ?? ""
            let marker: String
            if let bullet = group(2) {
                marker = "\(bullet) [ ] "
            } else if let bullet = group(3) {
                marker = "\(bullet) "
            } else {
                marker = "\((Int(group(4) ?? "") ?? 0) + 1)\(group(5) ?? ".") "
            }
            textView.insertText("\n" + indent + marker, replacementRange: selection)
            return true
        }
    }
}

/// Applies Markdown styling to a text view's storage (notes are short, so all of it each time).
enum MarkdownStyler {
    static let accent = NSColor(Theme.accent)
    private static let textColor = NSColor(Theme.text)
    private static let mutedColor = NSColor(Theme.muted)
    private static let markColor = NSColor(Theme.muted).withAlphaComponent(0.5)

    static let bodySize: CGFloat = 14

    static func font(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let name = weight == .semibold ? "Barlow-SemiBold" : (weight == .medium ? "Barlow-Medium" : "Barlow-Regular")
        return NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    private static let paragraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2
        p.paragraphSpacing = 3
        return p
    }()

    static let base: [NSAttributedString.Key: Any] = [
        .font: font(bodySize),
        .foregroundColor: textColor,
        .paragraphStyle: paragraph,
    ]

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    private static let heading = regex(#"^(#{1,3}[ \t]+)(.+)$"#)
    private static let quote = regex(#"^(>[ \t]?)(.*)$"#)
    private static let task = regex(#"^([ \t]*[-*+][ \t]+\[([ xX])\])[ \t]+(.*)$"#)
    private static let bullet = regex(#"^[ \t]*([-*+]|\d+[.)])[ \t]+"#)
    private static let rule = regex(#"^[ \t]*(?:-{3,}|\*{3,})[ \t]*$"#)
    private static let code = regex(#"(`)([^`\n]+)(`)"#)
    private static let bold = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)(\1)"#)
    private static let italic = regex(#"(?<![*\w])([*_])(?=[^\s*_])([^*_\n]+?)(?<=\S)(\1)(?![*\w])"#)
    private static let strike = regex(#"(~~)(?=\S)(.+?)(?<=\S)(~~)"#)
    private static let link = regex(#"(\[)([^\]\n]+)(\]\(([^)\s]+)\))"#)
    static let image = regex(#"!\[[^\]\n]*\]\(([^)\n]+)\)"#)
    private static let bareURL = regex(#"(?<![(\[<])\bhttps?://[^\s)>\]]+"#)

    static func apply(to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let string = storage.string
        let full = NSRange(location: 0, length: (string as NSString).length)

        storage.beginEditing()
        storage.setAttributes(base, range: full)

        each(heading, in: string) { m in
            let level = (string as NSString).substring(with: m.range(at: 1)).filter { $0 == "#" }.count
            let size: CGFloat = [20, 17, 15.5][level - 1]
            storage.addAttribute(.font, value: font(size, weight: .semibold), range: m.range(at: 2))
            mark(storage, m.range(at: 1))
        }
        each(quote, in: string) { m in
            storage.addAttributes([.foregroundColor: mutedColor, .obliqueness: 0.12], range: m.range(at: 2))
            mark(storage, m.range(at: 1))
        }
        each(bullet, in: string) { m in
            storage.addAttributes([.foregroundColor: mutedColor, .font: font(bodySize, weight: .semibold)], range: m.range(at: 1))
        }
        each(task, in: string) { m in
            let done = (string as NSString).substring(with: m.range(at: 2)) != " "
            storage.addAttributes([.foregroundColor: done ? accent : mutedColor, .font: font(bodySize, weight: .medium)], range: m.range(at: 1))
            if done {
                storage.addAttributes([.foregroundColor: mutedColor, .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: m.range(at: 3))
            }
        }
        each(rule, in: string) { m in mark(storage, m.range) }

        each(bold, in: string) { m in
            embolden(storage, m.range(at: 2))
            mark(storage, m.range(at: 1)); mark(storage, m.range(at: 3))
        }
        each(italic, in: string) { m in
            storage.addAttribute(.obliqueness, value: 0.14, range: m.range(at: 2))
            mark(storage, m.range(at: 1)); mark(storage, m.range(at: 3))
        }
        each(strike, in: string) { m in
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 2))
            mark(storage, m.range(at: 1)); mark(storage, m.range(at: 3))
        }
        each(code, in: string) { m in
            let size = (storage.attribute(.font, at: m.range(at: 2).location, effectiveRange: nil) as? NSFont)?.pointSize ?? bodySize
            storage.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: size - 1.5, weight: .regular),
                .backgroundColor: NSColor(Theme.slate).withAlphaComponent(0.07),
            ], range: m.range(at: 2))
            mark(storage, m.range(at: 1)); mark(storage, m.range(at: 3))
        }
        each(link, in: string) { m in
            let target = (string as NSString).substring(with: m.range(at: 4))
            if let url = URL(string: target) { storage.addAttribute(.link, value: url, range: m.range(at: 2)) }
            mark(storage, m.range(at: 1)); mark(storage, m.range(at: 3))
        }
        each(image, in: string) { m in
            storage.removeAttribute(.link, range: m.range)
            // The thumbnails below the text show the picture; keep the markup out of the way.
            storage.addAttributes([.foregroundColor: markColor.withAlphaComponent(0.3), .font: font(9)], range: m.range)
        }
        each(bareURL, in: string) { m in
            if let url = URL(string: (string as NSString).substring(with: m.range)) {
                storage.addAttribute(.link, value: url, range: m.range)
            }
        }
        storage.endEditing()
        textView.typingAttributes = base
    }

    private static func each(_ regex: NSRegularExpression, in string: String, _ body: (NSTextCheckingResult) -> Void) {
        regex.enumerateMatches(in: string, range: NSRange(location: 0, length: (string as NSString).length)) { m, _, _ in
            if let m = m { body(m) }
        }
    }

    private static func mark(_ storage: NSTextStorage, _ range: NSRange) {
        guard range.location != NSNotFound, range.length > 0 else { return }
        storage.addAttribute(.foregroundColor, value: markColor, range: range)
    }

    /// Semibold at whatever size the run already has (so **bold** inside a heading stays big).
    private static func embolden(_ storage: NSTextStorage, _ range: NSRange) {
        storage.enumerateAttribute(.font, in: range) { value, run, _ in
            let size = (value as? NSFont)?.pointSize ?? bodySize
            storage.addAttribute(.font, value: font(size, weight: .semibold), range: run)
        }
    }
}
