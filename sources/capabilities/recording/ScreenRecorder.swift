import AVFoundation
import CoreImage
import FairyCore
import FairyKit
import Foundation
import ScreenCaptureKit

/// Records one display to a .mov, showing only the `RecordingViewport` area of each frame: the
/// output is that area scaled to fill the video, so shrinking it with ⌥ + scroll zooms in.
///
/// ScreenCaptureKit delivers frames only when the screen changes, so a still screen would freeze
/// the zoom mid-animation. Instead the latest captured frame is kept and a steady 60 Hz clock
/// renders the output from it, stepping the viewport each tick.
///
/// Sound comes from the same stream: the computer's and the microphone's, whichever are switched
/// on, blended into one track (see `SoundTrack`). The recording can be paused; what happens
/// meanwhile is simply not in the video, and that is when the sound sources may change.
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
    private var soundInput: AVAssetWriterInput?
    private var soundTrack = SoundTrack()
    private var sound = RecordingSound()
    private var filter: SCContentFilter?
    private var captureSize = CGSize.zero
    private var clock: DispatchSourceTimer?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    private var latestFrame: CVPixelBuffer?
    private var viewport: RecordingViewport?
    private var displayScale: CGFloat = 2
    private var outputSize = CGSize.zero
    private var startTime: CFTimeInterval = 0
    private var lastTick: CFTimeInterval = 0
    /// Paused: nothing is written, and the time spent paused is cut out of the video.
    private var paused = false
    private var pauseBegan: CFTimeInterval = 0
    private var pausedTotal: CFTimeInterval = 0
    /// Sound older than this (system clock) belongs to before the recording or to a pause.
    private var soundAfter: CFTimeInterval = .greatestFiniteMagnitude
    private var framesWritten = 0
    private(set) var outputURL: URL?

    /// The area being recorded right now (global points, top-left origin), for the on-screen frame.
    private let areaLock = NSLock()
    private var _area: CGRect = .zero
    var currentArea: CGRect { areaLock.lock(); defer { areaLock.unlock() }; return _area }

    /// Called on an arbitrary queue if capture stops on its own (e.g. permission revoked).
    var onStoppedUnexpectedly: (Error) -> Void = { _ in }

    // MARK: - Start / stop

    func start(displayID: CGDirectDisplayID, excludingWindowIDs: [CGWindowID], sound: RecordingSound, to url: URL) async throws -> RecordingSound {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw Failure.noDisplay }
        let excluded = content.windows.filter { excludingWindowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)

        let bounds = CGDisplayBounds(displayID)
        let scale = CGFloat(filter.pointPixelScale)
        let captureSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)

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
        // Always there, so sound can be switched on part-way; it stays empty if it never is.
        let soundInput = AVAssetWriterInput(mediaType: .audio, outputSettings: SoundTrack.fileSettings)
        soundInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(soundInput) else { throw Failure.writer("can't add sound input") }
        writer.add(soundInput)
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "can't start writing") }
        writer.startSession(atSourceTime: .zero)

        queue.sync {
            self.filter = filter
            self.captureSize = captureSize
        }
        let stream = try makeStream(filter: filter, size: captureSize, sound: sound)

        queue.sync {
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            self.soundInput = soundInput
            self.soundTrack = SoundTrack()
            self.sound = sound
            self.paused = false
            self.pausedTotal = 0
            self.soundAfter = .greatestFiniteMagnitude
            self.stream = stream
            self.viewport = RecordingViewport(display: bounds)
            self.displayScale = scale
            self.outputSize = out
            self.outputURL = url
            self.latestFrame = nil
            self.framesWritten = 0
            self.setArea(bounds)
        }
        var listening = sound
        do {
            try await stream.startCapture()
        } catch {
            // A remembered microphone that won't start shouldn't cost the whole recording.
            guard !sound.isSilent else { throw error }
            FairyLog.write("recording couldn't start with sound \(sound): \(error) — recording without")
            listening = RecordingSound()
            let silent = try makeStream(filter: filter, size: captureSize, sound: listening)
            queue.sync {
                self.stream = silent
                self.sound = listening
            }
            try await silent.startCapture()
        }
        queue.sync { self.startClock() }
        return listening
    }

    /// One stream for the picture and whichever sounds are on. A stream's sources are fixed when
    /// it starts, so changing them means a new stream (done while paused, where it can't show).
    private func makeStream(filter: SCContentFilter, size: CGSize, sound: RecordingSound) throws -> SCStream {
        let config = SCStreamConfiguration()
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.showsCursor = true
        config.queueDepth = 6
        config.capturesAudio = sound.computer
        // The fairy's own sounds are not part of what you're showing.
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(SoundTrack.rate)
        config.channelCount = 2
        config.captureMicrophone = sound.microphone
        if sound.microphone, let id = sound.microphoneID { config.microphoneCaptureDeviceID = id }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if sound.computer { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if sound.microphone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        return stream
    }

    // MARK: - Pause

    /// Stop writing. The screen can do anything meanwhile; none of it is in the video.
    func pause() {
        queue.async {
            guard !self.paused, self.clock != nil else { return }
            self.paused = true
            self.pauseBegan = CACurrentMediaTime()
        }
    }

    /// Carry on, listening to `sound` from here. Returns what it is really listening to: if the
    /// new sources can't be started (a microphone that went away), it keeps the old ones.
    @discardableResult
    func resume(sound wanted: RecordingSound) async -> RecordingSound {
        let (current, old, filter, size) = queue.sync { (self.sound, self.stream, self.filter, self.captureSize) }
        var now = current
        if wanted != current, let filter = filter, old != nil {
            do {
                let fresh = try makeStream(filter: filter, size: size, sound: wanted)
                // The old one is let go first so its stopping isn't taken for a failure.
                queue.sync { self.stream = nil }
                try? await old?.stopCapture()
                do {
                    try await fresh.startCapture()
                    // Stopped while this was starting: the new stream has nothing to feed.
                    let stillRecording = queue.sync { () -> Bool in
                        guard self.writer != nil else { return false }
                        self.stream = fresh
                        return true
                    }
                    guard stillRecording else {
                        try? await fresh.stopCapture()
                        return current
                    }
                    now = wanted
                } catch {
                    FairyLog.write("recording sound \(wanted) didn't start: \(error) — keeping \(current)")
                    let back = try makeStream(filter: filter, size: size, sound: current)
                    try await back.startCapture()
                    let stillRecording = queue.sync { () -> Bool in
                        guard self.writer != nil else { return false }
                        self.stream = back
                        return true
                    }
                    if !stillRecording { try? await back.stopCapture() }
                }
            } catch {
                FairyLog.write("recording stream couldn't be rebuilt: \(error)")
                queue.sync { if self.stream == nil, self.writer != nil { self.stream = old } }
            }
        }
        let result = now
        queue.sync {
            self.sound = result
            guard self.paused else { return }
            let t = CACurrentMediaTime()
            self.pausedTotal += t - self.pauseBegan
            self.soundAfter = t
            self.soundTrack.breakContinuity()
            self.lastTick = t
            self.paused = false
        }
        return result
    }

    /// Seconds of video so far at system-clock time `t`.
    private func videoTime(at t: CFTimeInterval) -> Double {
        (paused ? pauseBegan : t) - startTime - pausedTotal
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
            // The last stretch of sound, without waiting for latecomers.
            self.writeSound(upTo: self.videoTime(at: CACurrentMediaTime()))
            let soundInput = self.soundInput
            self.writer = nil
            self.input = nil
            self.adaptor = nil
            self.soundInput = nil
            self.latestFrame = nil
            input.markAsFinished()
            soundInput?.markAsFinished()
            writer.finishWriting {
                let ok = writer.status == .completed && wrote
                if !ok, let url = url { try? FileManager.default.removeItem(at: url) }
                DispatchQueue.main.async { completion(ok ? url : nil) }
            }
        }
    }

    /// Whether ⌥ is held: the area follows the cursor only then.
    private var following = false
    func setFollowing(_ on: Bool) {
        queue.async { self.following = on }
    }

    /// ⌥ + scroll: positive zooms in.
    func zoom(by amount: CGFloat) {
        queue.async { self.viewport?.zoom(by: amount) }
    }

    /// Double-tap ⌥: ease back out to the whole display.
    func resetZoom() {
        queue.async { self.viewport?.reset() }
    }

    // MARK: - Frames

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio || type == .microphone {
            takeSound(sampleBuffer, from: type == .audio ? .computer : .microphone)
            return
        }
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = sampleBuffer.imageBuffer else { return }
        latestFrame = pixels
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // A stream that was replaced (the sound sources changed) is meant to stop.
        queue.async {
            guard stream === self.stream else { return }
            self.onStoppedUnexpectedly(error)
        }
    }

    // MARK: - Sound

    private var loggedSound: Set<SoundTrack.Source> = []

    /// A piece of sound from the stream. Its timestamp is on the system clock, like the video's,
    /// so it lands in the track at the moment it was heard.
    private func takeSound(_ sampleBuffer: CMSampleBuffer, from source: SoundTrack.Source) {
        guard soundInput != nil, clock != nil, !paused, sampleBuffer.isValid else { return }
        let heard = sampleBuffer.presentationTimeStamp.seconds
        guard heard.isFinite, heard >= soundAfter else { return }
        if loggedSound.insert(source).inserted {
            let format = sampleBuffer.formatDescription?.audioStreamBasicDescription
            FairyLog.write("recording hears \(source): \(Int(format?.mSampleRate ?? 0)) Hz, \(format?.mChannelsPerFrame ?? 0) ch, \(Int((CACurrentMediaTime() - heard) * 1000)) ms behind")
        }
        soundTrack.add(sampleBuffer, from: source, at: heard - startTime - pausedTotal)
    }

    /// Write the blended track up to `seconds` into the video.
    private func writeSound(upTo seconds: Double) {
        guard let soundInput = soundInput, soundTrack.hasSound else { return }
        while soundInput.isReadyForMoreMediaData, let piece = soundTrack.next(upTo: seconds) {
            soundInput.append(piece)
        }
    }

    private func startClock() {
        startTime = CACurrentMediaTime()
        lastTick = startTime
        soundAfter = startTime
        loggedSound = []
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
        guard !paused, var viewport = viewport else { return }
        writeSound(upTo: now - startTime - pausedTotal - SoundTrack.latency)
        // The area moves only while ⌥ is held (see RecordingViewport).
        let optionHeld = following
        let cursor = CGEvent(source: nil)?.location ?? CGPoint(x: viewport.display.midX, y: viewport.display.midY)
        viewport.step(cursor: cursor, following: optionHeld, dt: dt)
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

        let time = CMTime(seconds: now - startTime - pausedTotal, preferredTimescale: 600)
        if adaptor.append(out, withPresentationTime: time) { framesWritten += 1 }
    }

    private func setArea(_ rect: CGRect) {
        areaLock.lock()
        _area = rect
        areaLock.unlock()
    }
}
