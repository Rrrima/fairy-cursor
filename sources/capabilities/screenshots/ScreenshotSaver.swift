import AppKit
import FairyKit

/// Writes kept screenshots into the chosen folder, named the way macOS names its own
/// ("Screenshot 2026-11-11 at 14.32.05.png"). Encoding happens off the main thread.
enum ScreenshotSaver {
    private static let queue = DispatchQueue(label: "fairy.screenshot-saver", qos: .utility)

    static func save(_ image: CGImage, scale: CGFloat, takenAt date: Date, in folder: URL) {
        queue.async {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = Folders.captureURL("Screenshot", ext: "png", at: date, in: folder)
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
