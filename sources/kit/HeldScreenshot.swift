import AppKit

/// One screenshot the fairy is carrying.
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

    public init(image: CGImage, scale: CGFloat, capturedAt: Date = Date(), kept: Bool = false, tilt: Double = 0) {
        self.image = image
        self.scale = scale
        self.capturedAt = capturedAt
        self.kept = kept
        self.tilt = tilt
        self.nsImage = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
    }

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
