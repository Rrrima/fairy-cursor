import AVFoundation
import CoreImage
import FairyCore
import Foundation
import ScreenCaptureKit

/// Records one display to a .mov, showing only the `RecordingViewport` area of each frame: the
/// output is that area scaled to fill the video, so shrinking it with ⌥ + scroll zooms in.
///
/// ScreenCaptureKit delivers frames only when the screen changes, so a still screen would freeze
/// the zoom mid-animation. Instead the latest captured frame is kept and a steady 60 Hz clock
/// renders the output from it, stepping the viewport each tick.
///
/// All state lives on `queue`; public methods may be called from any thread.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum Failure: Error { case noDisplay, writer(String) }

    private let queue = DispatchQueue(label: "fairy.recorder", qos: .userInteractive)
    private let fps: Double = 60

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var clock: DispatchSourceTimer?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    private var latestFrame: CVPixelBuffer?
    private var viewport: RecordingViewport?
    private var displayScale: CGFloat = 2
    private var outputSize = CGSize.zero
    private var startTime: CFTimeInterval = 0
    private var lastTick: CFTimeInterval = 0
    private var framesWritten = 0
    private(set) var outputURL: URL?

    /// The area being recorded right now (global points, top-left origin), for the on-screen frame.
    private let areaLock = NSLock()
    private var _area: CGRect = .zero
    var currentArea: CGRect { areaLock.lock(); defer { areaLock.unlock() }; return _area }

    /// Called on an arbitrary queue if capture stops on its own (e.g. permission revoked).
    var onStoppedUnexpectedly: (Error) -> Void = { _ in }

    // MARK: - Start / stop

    func start(displayID: CGDirectDisplayID, excludingWindowIDs: [CGWindowID], to url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw Failure.noDisplay }
        let excluded = content.windows.filter { excludingWindowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)

        let bounds = CGDisplayBounds(displayID)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int(bounds.width * scale)
        config.height = Int(bounds.height * scale)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.showsCursor = true
        config.queueDepth = 6
        config.capturesAudio = false

        // Output: the display's shape, at most 3840 wide (and even, as encoders require).
        let longest = max(bounds.width, bounds.height) * scale
        let fit = min(1, 3840 / longest)
        let out = CGSize(width: (bounds.width * scale * fit / 2).rounded() * 2,
                         height: (bounds.height * scale * fit / 2).rounded() * 2)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(out.width),
            AVVideoHeightKey: Int(out.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(out.width * out.height * 5),
                AVVideoExpectedSourceFrameRateKey: Int(fps),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(out.width),
            kCVPixelBufferHeightKey as String: Int(out.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ])
        guard writer.canAdd(input) else { throw Failure.writer("can't add video input") }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "can't start writing") }
        writer.startSession(atSourceTime: .zero)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)

        queue.sync {
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            self.stream = stream
            self.viewport = RecordingViewport(display: bounds)
            self.displayScale = scale
            self.outputSize = out
            self.outputURL = url
            self.latestFrame = nil
            self.framesWritten = 0
            self.setArea(bounds)
        }
        try await stream.startCapture()
        queue.sync { self.startClock() }
    }

    /// Finish the file. Calls back on the main queue with the URL (nil if nothing was written).
    func stop(completion: @escaping @Sendable (URL?) -> Void) {
        queue.async {
            self.clock?.cancel()
            self.clock = nil
            let stream = self.stream
            self.stream = nil
            Task { try? await stream?.stopCapture() }
            guard let writer = self.writer, let input = self.input else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let url = self.outputURL
            let wrote = self.framesWritten > 0
            self.writer = nil
            self.input = nil
            self.adaptor = nil
            self.latestFrame = nil
            input.markAsFinished()
            writer.finishWriting {
                let ok = writer.status == .completed && wrote
                if !ok, let url = url { try? FileManager.default.removeItem(at: url) }
                DispatchQueue.main.async { completion(ok ? url : nil) }
            }
        }
    }

    /// ⌥ + scroll: positive zooms in.
    func zoom(by amount: CGFloat) {
        queue.async { self.viewport?.zoom(by: amount) }
    }

    // MARK: - Frames

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = sampleBuffer.imageBuffer else { return }
        latestFrame = pixels
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStoppedUnexpectedly(error)
    }

    private func startClock() {
        startTime = CACurrentMediaTime()
        lastTick = startTime
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1 / fps, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        clock = timer
        timer.resume()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = now - lastTick
        lastTick = now
        guard var viewport = viewport else { return }
        viewport.step(cursor: CGEvent(source: nil)?.location ?? CGPoint(x: viewport.display.midX, y: viewport.display.midY), dt: dt)
        self.viewport = viewport
        let area = viewport.area
        setArea(area)

        guard let frame = latestFrame, let input = input, input.isReadyForMoreMediaData,
              let adaptor = adaptor, let pool = adaptor.pixelBufferPool else { return }
        var outBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer) == kCVReturnSuccess, let out = outBuffer else { return }

        // Area → pixels of the captured frame (Core Image's origin is bottom-left).
        let source = CIImage(cvPixelBuffer: frame)
        let h = source.extent.height
        let local = area.offsetBy(dx: -viewport.display.minX, dy: -viewport.display.minY)
        let crop = CGRect(x: local.minX * displayScale, y: h - local.maxY * displayScale,
                          width: local.width * displayScale, height: local.height * displayScale)
        let sx = outputSize.width / crop.width
        let sy = outputSize.height / crop.height
        let image = source.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY).concatenating(CGAffineTransform(scaleX: sx, y: sy)))
            .samplingLinear()
        ciContext.render(image, to: out, bounds: CGRect(origin: .zero, size: outputSize), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))

        let time = CMTime(seconds: now - startTime, preferredTimescale: 600)
        if adaptor.append(out, withPresentationTime: time) { framesWritten += 1 }
    }

    private func setArea(_ rect: CGRect) {
        areaLock.lock()
        _area = rect
        areaLock.unlock()
    }
}
