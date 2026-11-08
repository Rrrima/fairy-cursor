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

    public enum MouseUpStep: Equatable { case wait, proceed }

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
        /// Probe-verified fields: unchanged by then → the field refused the image.
        public var probeTimeout: TimeInterval = 3.0
        /// A read counts once the reader had a moment to finish.
        public var readSettle: TimeInterval = 0.1

        public init(hasProbe: Bool) { self.hasProbe = hasProbe }

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

        public init() {}

        /// - pasteboardUnchanged: nobody wrote the pasteboard since our write (if the user copied
        ///   something meanwhile, or a later paste of the same pile wrote it, leave it alone).
        public func step(sinceSend: TimeInterval, sinceLastRead: TimeInterval?, pasteboardUnchanged: Bool) -> RestoreStep {
            guard pasteboardUnchanged else { return .abandon }
            if sinceSend >= maxDelay { return .restore }
            guard sinceSend >= minDelay else { return .wait }
            if let quiet = sinceLastRead, quiet < quietAfterRead { return .wait }
            return .restore
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
