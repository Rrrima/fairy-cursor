import AVFoundation
import FairyCore

/// The recording's one sound track: takes the audio ScreenCaptureKit hands over (the computer's
/// sound, the microphone), brings each piece to 48 kHz stereo, lets `SoundMix` blend them, and
/// hands back stretches of the blend ready for the file.
///
/// One track, not one per source: most places a video is shared play only the first track, and
/// the voice or the computer's sound would go missing. Used from the recorder's queue only.
final class SoundTrack {
    enum Source: Int { case computer, microphone }

    static let rate: Double = 48_000
    /// The blend waits this long for pieces to arrive before a stretch is final.
    static let latency: Double = 0.35

    /// What the file's sound input wants: AAC, stereo.
    static let fileSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: rate,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 160_000,
    ]

    private var mix = SoundMix()
    private var converters: [Source: AVAudioConverter] = [:]
    /// True once any sound has come in: until then nothing is written, so a silent recording
    /// stays a video with no sound track's worth of zeros.
    private(set) var hasSound = false

    private let format: CMAudioFormatDescription? = {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: SoundTrack.rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
            mBitsPerChannel: 32, mReserved: 0)
        var out: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &out)
        return out
    }()

    /// Add a piece that belongs at `seconds` into the video.
    func add(_ sampleBuffer: CMSampleBuffer, from source: Source, at seconds: Double) {
        guard let (left, right) = stereo(sampleBuffer, source: source) else { return }
        hasSound = true
        mix.add(source: source.rawValue, at: Int((seconds * Self.rate).rounded()), left: left, right: right)
    }

    /// The next stretch of the track up to `seconds` into the video (at most a second of it).
    func next(upTo seconds: Double) -> CMSampleBuffer? {
        guard hasSound, let format = format,
              let (start, samples) = mix.drain(upTo: Int(seconds * Self.rate), limit: Int(Self.rate)) else { return nil }
        let bytes = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr, let block = block,
              CMBlockBufferAssureBlockMemory(block) == kCMBlockBufferNoErr else { return nil }
        let copied = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var out: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: samples.count / 2,
            presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(Self.rate)),
            packetDescriptions: nil, sampleBufferOut: &out)
        return out
    }

    /// After a pause or a change of sources: new pieces start fresh.
    func breakContinuity() {
        mix.breakContinuity()
        converters.removeAll()
    }

    // MARK: - Any format in, 48 kHz stereo out

    private func stereo(_ sampleBuffer: CMSampleBuffer, source: Source) -> ([Float], [Float])? {
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let description = sampleBuffer.formatDescription else { return nil }
        let input = AVAudioFormat(cmAudioFormatDescription: description)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                           into: buffer.mutableAudioBufferList) == noErr else { return nil }

        // Same channels, 48 kHz floats, one array per channel. Folding to stereo is done by
        // hand below: a mono microphone should come out of both speakers.
        guard let wanted = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.rate,
                                         channels: input.channelCount, interleaved: false) else { return nil }
        var ready = buffer
        if input != wanted {
            if converters[source]?.inputFormat != input { converters[source] = AVAudioConverter(from: input, to: wanted) }
            guard let converter = converters[source] else { return nil }
            let capacity = AVAudioFrameCount(Double(frames) * Self.rate / input.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: wanted, frameCapacity: capacity) else { return nil }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil else { return nil }
            ready = out
        }
        let count = Int(ready.frameLength)
        guard count > 0, let channels = ready.floatChannelData else { return nil }
        let left = Array(UnsafeBufferPointer(start: channels[0], count: count))
        let right = ready.format.channelCount > 1 ? Array(UnsafeBufferPointer(start: channels[1], count: count)) : left
        return (left, right)
    }
}
