import SwiftUI

// The quiet look Settings and the welcome guide share with the website: a white page, near-black
// ink in three strengths, one pale fill for anything you can press or read as a key, and the
// system font. Blue is kept for what is live (a recording).

/// One key, or a word that stands for a gesture ("click", "shake"), on a small pale tile.
public struct KeyChip: View {
    let label: String
    var pressed: Bool

    public init(_ label: String, pressed: Bool = false) {
        self.label = label
        self.pressed = pressed
    }

    public var body: some View {
        Text(label)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(pressed ? Color.white : SettingsInk.secondary)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 22)
            .background(RoundedRectangle(cornerRadius: 6.5, style: .continuous).fill(pressed ? SettingsInk.primary : SettingsInk.fill))
            .offset(y: pressed ? 1 : 0)
            .fixedSize()
    }
}

/// A shortcut as a row of chips: "⌘⇧6" becomes ⌘ ⇧ 6, "hold ⌥" becomes hold ⌥.
public struct KeyChips: View {
    let keys: [String]

    public init(_ shortcut: String) {
        keys = Self.split(shortcut)
    }

    public init(keys: [String]) {
        self.keys = keys
    }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(keys.indices, id: \.self) { KeyChip(keys[$0]) }
        }
    }

    private static let modifiers: Set<Character> = ["⌘", "⇧", "⌥", "⌃", "⌫", "⎋"]

    /// Words stay whole; a run that contains a modifier symbol is one key per character.
    static func split(_ shortcut: String) -> [String] {
        shortcut.split(separator: " ").flatMap { token -> [String] in
            token.contains(where: modifiers.contains) ? token.map(String.init) : [String(token)]
        }
    }
}
