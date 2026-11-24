import Foundation

/// Timing and decision rules for pasting a screenshot into another app: write the pasteboard,
/// press ⌘V, learn whether it was taken, put the user's clipboard back. Pure; `PasteTarget` in
/// the app runs it against the real pasteboard and event system.
public enum PastePolicy {
    // MARK: Sequencing

    /// The double-click event arrives on the second mouse-*down*. Wait for the release (so focus
    /// and the word selection are final) but never forever.
    public static let mouseUpPollInterval: TimeInterval = 0.02
    public static let mouseUpTimeout: TimeInterval = 1.0
    /// Settle after the release before typing into the field.
    public static let afterMouseUpDelay: TimeInterval = 0.08
    /// After asking the target app to activate, how long to wait for it to become frontmost.
    public static let activationTimeout: TimeInterval = 0.6
    /// Between collapsing the selection (→) and pressing ⌘V.
    public static let collapseToPasteDelay: TimeInterval = 0.06
    /// Between closing a whiteboard's fresh text box (esc) and pressing ⌘V.
    public static let dismissToPasteDelay: TimeInterval = 0.18

    public enum MouseUpStep: Equatable { case wait, proceed }

    // MARK: Terminals: wait out copy-on-select

    /// Terminals (iTerm, and TUIs like Claude Code through it) copy the selection to the
    /// clipboard on every mouse-up: the double-clicked word, or the whole wrapped line when a
    /// third click follows. A copy that lands after our write replaces the screenshot, and the
    /// ⌘V then pastes that text. So for terminals the keystroke waits until the clicking is over
    /// and the clipboard has been quiet for a moment.
    public struct TerminalSettle {
        /// Since the last mouse-up (a third click restarts it).
        public var afterMouseUp: TimeInterval = 0.14
        /// Since the last time anyone wrote the clipboard.
        public var clipboardQuiet: TimeInterval = 0.09
        /// Never hold the paste longer than this.
        public var timeout: TimeInterval = 1.5

        public init() {}

        public func step(elapsed: TimeInterval, buttonsDown: Bool, sinceMouseUp: TimeInterval,
                         sinceClipboardChange: TimeInterval?) -> MouseUpStep {
            if elapsed >= timeout { return .proceed }
            if buttonsDown || sinceMouseUp < afterMouseUp { return .wait }
            if let quiet = sinceClipboardChange, quiet < clipboardQuiet { return .wait }
            return .proceed
        }
    }

    // MARK: Someone else wrote the clipboard after us

    public enum OverwriteStep: Equatable {
        /// Put the screenshot back: the ⌘V has not been served yet and would paste their text.
        case rewrite
        /// The paste was already served; treat the write as selection noise and still restore
        /// the user's clipboard afterwards.
        case adopt
        /// A real copy by the user: leave it alone and never restore over it.
        case leave
    }

    /// How long after ⌘V a foreign clipboard write is taken for the click's own side effect
    /// rather than the user copying something.
    public static let overwriteWindow: TimeInterval = 1.0
    public static let maxRewrites = 3

    public static func overwriteStep(sinceSend: TimeInterval, reads: Int, rewrites: Int, isTerminal: Bool) -> OverwriteStep {
        guard sinceSend < overwriteWindow else { return .leave }
        if reads == 0 { return rewrites < maxRewrites ? .rewrite : .leave }
        return isTerminal ? .adopt : .leave
    }

    // MARK: The user's clipboard, as it was before the click

    /// Which copy of the clipboard to put back after the paste. `remembered` was taken at the
    /// first mouse-down of the double-click; if the clipboard changed between then and now, that
    /// change is the terminal's copy-on-select, not something the user copied.
    public static func useRememberedClipboard(rememberedCount: Int?, currentCount: Int, age: TimeInterval?) -> Bool {
        guard let remembered = rememberedCount, let age = age else { return false }
        if remembered == currentCount { return true }
        return age <= 2.0
    }

    public static func mouseUpStep(elapsed: TimeInterval, buttonsDown: Bool) -> MouseUpStep {
        if !buttonsDown || elapsed >= mouseUpTimeout { return .proceed }
        return .wait
    }

    // MARK: Key delivery

    public enum KeyRoute: Equatable {
        /// Post into the session event stream: the frontmost app receives it exactly like real
        /// typing (menu key equivalents, modifier state and all). Preferred.
        case session
        /// Post straight to a process. Only a fallback: many native apps (SwiftUI/AppKit text
        /// views that consult the global modifier state, Catalyst apps) ignore a ⌘V delivered
        /// this way, which is why pasting into e.g. the ChatGPT app silently did nothing.
        case process(Int32)
    }

    public static func needsActivation(target: Int32?, frontmost: Int32?) -> Bool {
        guard let target = target, target > 0 else { return false }
        return target != frontmost
    }

    public static func keyRoute(target: Int32?, frontmost: Int32?) -> KeyRoute {
        guard let target = target, target > 0, let frontmost = frontmost, target != frontmost else { return .session }
        return .process(target)
    }

    // MARK: Outcome

    public enum Outcome: Equatable { case pending, accepted, rejected, failed }

    /// Decides whether the paste was taken from two signals:
    ///  - `reads`: how many times another process asked for the pasteboard data we promised.
    ///    No read at all means the ⌘V never reached a paste handler (or the field only takes
    ///    text and saw no text) — the screenshot must stay in the fairy's hands.
    ///  - `probeChanged`: the accessibility fingerprint of a single-line field changed.
    public struct OutcomeRules {
        /// Single-line fields (search/address bars) are verified with the probe.
        public var hasProbe: Bool
        /// With no read by then, give up: the paste did not happen.
        public var noReadTimeout: TimeInterval = 1.6
        /// A drop onto a canvas is a guess (nothing says it takes images until it reads one),
        /// so give up sooner.
        public var isCanvas = false
        /// Probe-verified fields: unchanged by then → the field refused the image.
        public var probeTimeout: TimeInterval = 3.0
        /// A read counts once the reader had a moment to finish.
        public var readSettle: TimeInterval = 0.1

        public init(hasProbe: Bool, isCanvas: Bool = false) {
            self.hasProbe = hasProbe
            self.isCanvas = isCanvas
            if isCanvas { noReadTimeout = 1.0 }
        }

        public func evaluate(elapsed: TimeInterval, reads: Int, probeChanged: Bool) -> Outcome {
            if probeChanged { return .accepted }
            if hasProbe {
                if reads == 0 && elapsed >= noReadTimeout { return .failed }
                if elapsed >= probeTimeout { return reads > 0 ? .rejected : .failed }
                return .pending
            }
            if reads > 0 && elapsed >= readSettle { return .accepted }
            if elapsed >= noReadTimeout { return .failed }
            return .pending
        }
    }

    // MARK: Clipboard restore

    public enum RestoreStep: Equatable { case wait, restore, abandon }

    public struct RestoreRules {
        /// Never restore earlier than this after ⌘V (apps may read late, e.g. after an await).
        public var minDelay: TimeInterval = 2.0
        /// Restore once the last read is this old…
        public var quietAfterRead: TimeInterval = 0.6
        /// …and in any case by this time.
        public var maxDelay: TimeInterval = 6.0
        /// Nobody has read the screenshot yet: the ⌘V may still be waiting in a busy app's queue
        /// (Chromium apps can be frozen for seconds). Putting the user's clipboard back now would
        /// make that late ⌘V paste their text instead, so hold the screenshot there much longer.
        public var noReadDelay: TimeInterval = 8.0

        public init() {}

        /// - pasteboardUnchanged: nobody wrote the pasteboard since our write (if the user copied
        ///   something meanwhile, or a later paste of the same pile wrote it, leave it alone).
        public func step(sinceSend: TimeInterval, sinceLastRead: TimeInterval?, pasteboardUnchanged: Bool) -> RestoreStep {
            guard pasteboardUnchanged else { return .abandon }
            guard let quiet = sinceLastRead else { return sinceSend >= noReadDelay ? .restore : .wait }
            if sinceSend >= maxDelay { return .restore }
            guard sinceSend >= minDelay else { return .wait }
            return quiet < quietAfterRead ? .wait : .restore
        }
    }

    /// The pasteboard types written for an image paste. Image types are promised lazily (so
    /// reads can be observed); terminals also get a shell-quoted path as text.
    public static func imageTypes(forTerminal: Bool) -> [String] {
        var types = ["public.png", "public.tiff"]
        if forTerminal { types = ["public.utf8-plain-text", "public.file-url"] + types }
        return types
    }

    /// Markers that ask clipboard managers (nspasteboard.org convention) not to record the
    /// screenshot as the user's clipboard — and not to read it, which would look like a paste.
    public static let transientMarkerTypes = ["org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]

    /// Shell-safe path followed by a space, so the command line can continue.
    public static func shellQuoted(_ path: String) -> String {
        let needsQuotes = path.contains { " '\"\\$`!&;|<>()*?[]{}#~".contains($0) }
        guard needsQuotes else { return path + " " }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "' "
    }
}
