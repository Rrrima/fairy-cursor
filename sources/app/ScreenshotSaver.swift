import AppKit

/// Writes kept screenshots into the chosen folder, named the way macOS names its own
/// ("Screenshot 2026-11-11 at 14.32.05.png"). Encoding happens off the main thread.
enum ScreenshotSaver {
    private static let queue = DispatchQueue(label: "fairy.screenshot-saver", qos: .utility)

    static func save(_ image: CGImage, scale: CGFloat, takenAt date: Date, in folder: URL) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stem = "Screenshot \(formatter.string(from: date))"
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var url = folder.appendingPathComponent("\(stem).png")
            var n = 2
            while fm.fileExists(atPath: url.path) {
                url = folder.appendingPathComponent("\(stem) \(n).png")
                n += 1
            }
            // Embed the display's DPI so Preview and Finder show it at the size it was on screen.
            let rep = NSBitmapImageRep(cgImage: image)
            rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            guard let data = rep.representation(using: .png, properties: [:]) else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("[FairyCursor] screenshot save failed: \(error)")
            }
        }
    }
}
