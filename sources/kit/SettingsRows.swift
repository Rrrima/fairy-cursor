import AppKit
import SwiftUI

// The rows Settings is made of, shared so a capability's section looks like the rest of the
// window. A capability returns rows from `settingsView()`; the host puts them in its section.

/// The website's ink: near-black in three strengths, one pale fill, and a blue kept for what is
/// live. Switches that are on are ink, not blue.
public enum SettingsInk {
    /// #1d1d1f
    public static let primary = Color(red: 0x1d / 255, green: 0x1d / 255, blue: 0x1f / 255)
    /// #6e6e73
    public static let secondary = Color(red: 0x6e / 255, green: 0x6e / 255, blue: 0x73 / 255)
    /// #a1a1a6
    public static let faint = Color(red: 0xa1 / 255, green: 0xa1 / 255, blue: 0xa6 / 255)
    /// #f2f2f5: keys, buttons, and the patch a capability's own options sit on.
    public static let fill = Color(red: 0xf2 / 255, green: 0xf2 / 255, blue: 0xf5 / 255)
    /// hsl(212, 72%, 56%), the recording blue.
    public static let accent = Color(red: 0.243, green: 0.539, blue: 0.877)
}

/// A title, an optional explanation under it, and a switch on the right.
public struct ToggleRow: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    public init(title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self._isOn = isOn
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(SettingsInk.primary)
                if let detail = detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .lineSpacing(1.5)
                        .foregroundStyle(SettingsInk.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .animation(.easeOut(duration: 0.2), value: detail)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(SettingsInk.primary)
        }
    }
}

/// A title, an explanation under it, and a few choices on the right of which one is picked.
/// The picked one is ink, like a switch that's on, and the ink slides between them.
public struct ChoiceRow<Value: Hashable>: View {
    let title: String
    let detail: String?
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    @Namespace private var thumb

    public init(title: String, detail: String? = nil, options: [(Value, String)], selection: Binding<Value>) {
        self.title = title
        self.detail = detail
        self.options = options.map { (value: $0.0, label: $0.1) }
        self._selection = selection
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 14) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(SettingsInk.primary)
                Spacer(minLength: 8)
                HStack(spacing: 0) {
                    ForEach(options, id: \.value) { option in
                        let picked = option.value == selection
                        Text(option.label)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(picked ? Color.white : SettingsInk.secondary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 4.5)
                            .background {
                                if picked {
                                    Capsule().fill(SettingsInk.primary).matchedGeometryEffect(id: "picked", in: thumb)
                                }
                            }
                            .contentShape(Capsule())
                            .onTapGesture { selection = option.value }
                            .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(2)
                .background(Capsule().fill(SettingsInk.fill))
                .animation(.spring(response: 0.28, dampingFraction: 0.82), value: selection)
            }
            if let detail = detail {
                Text(detail)
                    .font(.system(size: 12))
                    .lineSpacing(1.5)
                    .foregroundStyle(SettingsInk.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A folder the user picks: its title and path, with Change… and Open beside them.
public struct FolderRow: View {
    let title: String
    let folder: URL
    let detail: String?
    let choose: () -> Void

    public init(title: String, folder: URL, detail: String? = nil, choose: @escaping () -> Void) {
        self.title = title
        self.folder = folder
        self.detail = detail
        self.choose = choose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(SettingsInk.primary)
                    Text(Folders.displayPath(folder))
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsInk.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(folder.path)
                }
                Spacer(minLength: 8)
                QuietButton(title: "Change…", action: choose)
                QuietButton(title: "Open", action: { Folders.open(folder) })
            }
            if let detail = detail {
                Text(detail).font(.system(size: 12)).foregroundStyle(SettingsInk.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A small pale pill: quiet at rest, a shade darker under the pointer.
public struct QuietButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    public init(title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SettingsInk.primary)
                .padding(.horizontal, 11)
                .padding(.vertical, 4.5)
                .background(Capsule().fill(hovering ? Color(white: 0.89) : SettingsInk.fill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Folder helpers for settings and menus.
@MainActor
public enum Folders {
    /// "~/Documents/Fairy Notes" rather than the full path.
    public static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Ask for a folder; nil when cancelled.
    public static func choose(startingAt url: URL, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = url
        panel.prompt = prompt
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url : nil
    }

    public static func open(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    /// "Screenshot 2026-11-11 at 14.32.05.png" in `folder`, like macOS names its own, with " 2",
    /// " 3"… added if that name is taken.
    public nonisolated static func captureURL(_ kind: String, ext: String, at date: Date = Date(), in folder: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stem = "\(kind) \(formatter.string(from: date))"
        var url = folder.appendingPathComponent("\(stem).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(stem) \(n).\(ext)")
            n += 1
        }
        return url
    }
}
