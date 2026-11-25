import AppKit

/// A freshly downloaded app opened where it was unzipped doesn't really run from there: macOS
/// runs a hidden read-only copy ("translocation"). Permissions granted to that copy show up in
/// System Settings as a nameless "Fairy Cursor.app" with no icon, and don't stick. So before
/// asking for anything, offer to move into Applications and start again from there.
@MainActor
enum Relocation {
    private static let appName = "Fairy Cursor.app"

    /// True when the app is about to quit and reopen from Applications: do nothing else.
    static func moveToApplicationsIfNeeded() -> Bool {
        let running = Bundle.main.bundleURL
        guard needsMove(running) else { return false }

        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Move Fairy Cursor to Applications?"
        alert.informativeText = "It has to live in your Applications folder before macOS lets it ask for permissions."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Quit")
        guard alert.runModal() == .alertFirstButtonReturn else { NSApp.terminate(nil); return true }

        let destination = URL(fileURLWithPath: "/Applications").appendingPathComponent(appName)
        do {
            try install(from: running, to: destination)
        } catch {
            let failed = NSAlert()
            failed.messageText = "Couldn't move it"
            failed.informativeText = "Drag Fairy Cursor into your Applications folder yourself, then open it from there.\n\n\(error.localizedDescription)"
            failed.runModal()
            NSApp.terminate(nil)
            return true
        }
        // The copy that was downloaded is no use any more.
        try? FileManager.default.trashItem(at: original(of: running), resultingItemURL: nil)
        relaunch(destination)
        return true
    }

    /// Only a downloaded copy outside Applications: a build run from the project folder stays put.
    static func needsMove(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") { return false }
        return isTranslocated(url) || isQuarantined(url)
    }

    private static func isTranslocated(_ url: URL) -> Bool { url.path.contains("/AppTranslocation/") }

    private static func isQuarantined(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }

    private static func install(from source: URL, to destination: URL) throws {
        let files = FileManager.default
        if files.fileExists(atPath: destination.path) {
            try files.trashItem(at: destination, resultingItemURL: nil)
        }
        try files.copyItem(at: source, to: destination)
        // The copy keeps the download's quarantine mark, and macOS would hide it away again.
        let strip = Process()
        strip.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        strip.arguments = ["-dr", "com.apple.quarantine", destination.path]
        try strip.run()
        strip.waitUntilExit()
    }

    /// Where the download really is, when macOS is running a hidden copy of it.
    private static func original(of url: URL) -> URL {
        typealias Lookup = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard isTranslocated(url),
              let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return url }
        let lookup = unsafeBitCast(symbol, to: Lookup.self)
        return lookup(url as CFURL, nil).map { $0.takeRetainedValue() as URL } ?? url
    }

    /// Open the installed copy once this one has gone (two can't run at once).
    private static func relaunch(_ app: URL) {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/bin/sh")
        open.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", app.path]
        try? open.run()
        exit(0)
    }
}
