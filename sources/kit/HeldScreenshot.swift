import AppKit

/// One card the fairy is carrying: a screenshot, or a screen recording (then `image` is its
/// poster frame and `movie` the file it stands for).
public struct HeldScreenshot: Identifiable {
    public let id = UUID()
    public let image: CGImage
    public let scale: CGFloat
    public let capturedAt: Date
    public let nsImage: NSImage
    /// Already saved to disk, so letting go of it loses nothing.
    public let kept: Bool
    /// Small random tilt so stacked cards read as separate sheets.
    public let tilt: Double
    /// A recording: the saved video file. Delivering the card delivers this file.
    public let movie: URL?
    /// How long the recording runs, for the card's badge.
    public let duration: TimeInterval?

    public init(image: CGImage, scale: CGFloat, capturedAt: Date = Date(), kept: Bool = false, tilt: Double = 0,
                movie: URL? = nil, duration: TimeInterval? = nil) {
        self.movie = movie
        self.duration = duration
        self.image = image
        self.scale = scale
        self.capturedAt = capturedAt
        self.kept = kept
        self.tilt = tilt
        self.nsImage = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
    }

    public var isMovie: Bool { movie != nil }

    public var pointSize: CGSize { CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale) }

    /// PNG with the display's DPI embedded so Preview/Finder show it at the right size.
    public func pngData() -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = pointSize
        return rep.representation(using: .png, properties: [:])
    }

    public func tiffData() -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = pointSize
        return rep.tiffRepresentation
    }
}
