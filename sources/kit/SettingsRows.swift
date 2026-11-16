import AppKit
import SwiftUI

// The rows Settings is made of, shared so a capability's section looks like the rest of the
// window. A capability returns rows from `settingsView()`; the host puts them in its section.

/// Quiet ink, one soft blue for switches that are on.
public enum SettingsInk {
    public static let primary = Theme.text
    public static let secondary = Theme.muted
    public static let faint = Theme.muted.opacity(0.7)
    public static let accent = Color(hue: 212 / 360, saturation: 0.60, brightness: 0.80)
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
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.font(13.5, weight: .medium)).foregroundStyle(SettingsInk.primary)
                if let detail = detail {
                    Text(detail)
                        .font(Theme.font(12))
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
                .tint(SettingsInk.accent)
        }
    }
}

/// A folder the user picks: its title, Change… and Open, then the path.
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(title).font(Theme.font(13.5, weight: .medium)).foregroundStyle(SettingsInk.primary)
                Spacer(minLength: 8)
                QuietButton(title: "Change…", action: choose)
                QuietButton(title: "Open", action: { Folders.open(folder) })
            }
            Text(Folders.displayPath(folder))
                .font(Theme.font(12))
                .foregroundStyle(SettingsInk.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(folder.path)
            if let detail = detail {
                Text(detail).font(Theme.font(12)).foregroundStyle(SettingsInk.faint)
            }
        }
    }
}

/// A small glass pill: quiet at rest, it lifts and denses a little on hover.
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
                .font(Theme.font(12, weight: .medium))
                .foregroundStyle(hovering ? SettingsInk.primary : SettingsInk.secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .glassEffect(.regular.tint(.white.opacity(hovering ? 0.45 : 0.25)).interactive(), in: Capsule())
                .offset(y: hovering ? -1 : 0)
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
