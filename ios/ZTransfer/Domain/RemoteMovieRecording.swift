@preconcurrency import AVFoundation
import Foundation
import UIKit

/// Direct StartMovieRec result from Android's rcStartMovieDetailed. Bit 10 is
/// authoritative when a page reopens while the camera is already recording.
struct RemoteMovieStartResult: Equatable, Sendable {
    let responseCode: UInt16
    let prohibitCondition: UInt32?
    var prohibitExtendedResponse: UInt16? = nil
    var applicationModeResponse: UInt16? = nil
    var applicationModePropertyResponse: UInt16? = nil
    var startCommandResponse: UInt16? = nil

    var indicatesRecording: Bool {
        responseCode == 0x2001 || (prohibitCondition.map { $0 & (1 << 10) != 0 } ?? false)
    }

    var diagnosticSummary: String {
        var result = String(format: "result=0x%04X startOp=0x%04X", responseCode, responseCode)
        if let prohibitCondition {
            result += String(format: " prohibit=0x%08X", prohibitCondition)
        }
        if let prohibitExtendedResponse { result += String(format: " preEx=0x%04X", prohibitExtendedResponse) }
        if let applicationModeResponse { result += String(format: " appOp=0x%04X", applicationModeResponse) }
        if let applicationModePropertyResponse { result += String(format: " appProp=0x%04X", applicationModePropertyResponse) }
        return result
    }

    var needsLiveViewRestart: Bool {
        guard responseCode != PTPConstants.responseOK else { return false }
        let storageMask: UInt32 = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) | (1 << 11)
        let nonRestartable: UInt32 = (1 << 9) | (1 << 10)
        if let prohibitCondition, prohibitCondition & storageMask != 0 { return false }
        if let prohibitCondition, prohibitCondition & nonRestartable != 0 { return false }
        if let prohibitCondition, prohibitCondition != 0 {
            return prohibitCondition & ((1 << 12) | (1 << 14)) != 0
        }
        return responseCode == 0xA004 || responseCode == PTPConstants.deviceBusy
    }

    var requiresApplicationMode: Bool {
        prohibitCondition.map { $0 & (1 << 14) != 0 } ?? false
    }
}

/// Android RemoteLab.cmdBusyRetry sends once, then retries DEVICE_BUSY at most
/// five times with 200 ms between commands. Other responses return unchanged.
enum RemoteMovieCommandRetry {
    static func execute(
        command: @Sendable () async throws -> UInt16,
        pause: @Sendable () async throws -> Void = {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    ) async throws -> UInt16 {
        try Task.checkCancellation()
        var response = try await command()
        try Task.checkCancellation()
        var retries = 0
        while response == 0x2019 && retries < 5 {
            try await pause()
            try Task.checkCancellation()
            response = try await command()
            try Task.checkCancellation()
            retries += 1
        }
        return response
    }
}

enum RemoteRecordingCommand: Equatable, Sendable { case start, stop }

/// A completion may update the page only while it still owns this request.
/// Cancelling/leaving invalidates the token even if the camera replies later.
struct RemoteRecordingOperationGate: Equatable, Sendable {
    struct Token: Equatable, Sendable {
        fileprivate let sequence: UInt64
        let command: RemoteRecordingCommand
    }

    private var sequence: UInt64 = 0
    private var pending: Token?
    var isBusy: Bool { pending != nil }

    mutating func begin(_ command: RemoteRecordingCommand) -> Token? {
        guard pending == nil else { return nil }
        sequence &+= 1
        let token = Token(sequence: sequence, command: command)
        pending = token
        return token
    }

    func accepts(_ token: Token) -> Bool { pending == token }

    @discardableResult
    mutating func complete(_ token: Token) -> Bool {
        guard accepts(token) else { return false }
        pending = nil
        return true
    }

    mutating func invalidate() { pending = nil }
}

struct RemoteRecordingHint: Equatable, Sendable {
    let message: String
    let durationNanoseconds: UInt64
    let diagnostic: String?

    static func startFailed(_ result: RemoteMovieStartResult?) -> Self {
        Self(message: AppLocalized.resource("remote_rec_start_failed"),
             durationNanoseconds: 12_000_000_000, diagnostic: result?.diagnosticSummary)
    }

    static func stopFailed(responseCode: UInt16 = 0xFFFF) -> Self {
        Self(message: AppLocalized.resource("remote_rec_stop_failed"),
             durationNanoseconds: 6_000_000_000,
             diagnostic: String(format: "stop=0x%04X", responseCode))
    }
}

enum RemoteLocalRecordingPhase: Equatable, Sendable {
    case idle
    case recording
    case paused
    case finalizing
    case saved
}

/// Encodes the decoded Live View frames themselves, independently of the
/// camera's movie command. Video PTS uses each frame's monotonic arrival time;
/// optional microphone samples use the same host clock and the same accumulated
/// pause duration, matching Android's ViewfinderRecorder contract.
/// A single pending input plus a single scheduled consumer. The producer
/// replaces stale input before scheduling work, never capturing it in a queue block.
final class RemoteRecordingLatestInput<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Element?
    private var scheduled = false

    func offer(_ value: Element) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pending = value
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    func take() -> Element? {
        lock.lock()
        defer { lock.unlock() }
        defer { pending = nil }
        return pending
    }

    /// Called once after processing a taken value. Retry only if no newer input
    /// arrived; keeping scheduled true reserves exactly one follow-up consumer.
    func finish(retry: Element? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if pending == nil { pending = retry }
        scheduled = pending != nil
        return scheduled
    }

    func discardAndFinish() {
        lock.lock()
        defer { lock.unlock() }
        pending = nil
        scheduled = false
    }

    func discardPending() {
        lock.lock()
        defer { lock.unlock() }
        pending = nil
    }
}

struct RemoteRecordingFailureStreak {
    private(set) var count = 0
    private(set) var stopped = false

    mutating func record(success: Bool) -> Bool {
        guard !stopped else { return false }
        count = success ? 0 : count + 1
        guard count >= 30 else { return false }
        stopped = true
        return true
    }
}

final class RemoteViewfinderRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Configuration {
        let outputURL: URL
        let sourceSize: CGSize
        let withAudio: Bool
        let desqueeze: Double
        let onEncodingFailure: @Sendable () -> Void
    }

    struct VideoOperations: Sendable {
        var isReady: @Sendable (AVAssetWriterInput) -> Bool = { $0.isReadyForMoreMediaData }
        var append: @Sendable (AVAssetWriterInputPixelBufferAdaptor, CVPixelBuffer, CMTime) -> Bool = {
            $0.append($1, withPresentationTime: $2)
        }
    }

    convenience init(configuration: Configuration) {
        self.init(outputURL: configuration.outputURL, sourceSize: configuration.sourceSize,
                  withAudio: configuration.withAudio, desqueeze: configuration.desqueeze,
                  onEncodingFailure: configuration.onEncodingFailure)
    }

    private let outputURL: URL
    private var stagingDirectory: URL?
    private var stagingURL: URL?
    private let width: Int
    private let height: Int
    private let makeAudioCapture: (@Sendable () -> AVCaptureSession?)?
    private let withAudio: Bool
    private let clock: @Sendable () -> TimeInterval
    private let makeWriter: @Sendable (URL) throws -> AVAssetWriter
    private let videoOperations: VideoOperations
    private let queue = DispatchQueue(label: "com.ztransfer.remote-recorder", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "com.ztransfer.remote-recorder.audio", qos: .userInitiated)

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private var captureSession: AVCaptureSession?
    private var recording = false
    private var paused = false
    private var baseUptime: TimeInterval?
    private var pauseStartedAt: TimeInterval?
    private var pausedDuration: TimeInterval = 0
    private var lastAudioEnd: CMTime?
    private var lastVideoPTS = CMTime.invalid
    private var encodingFailures = RemoteRecordingFailureStreak()
    private let onEncodingFailure: @Sendable () -> Void
    private let pendingAudio = RemoteRecordingLatestInput<CMSampleBuffer>()
    private let pendingVideo = RemoteRecordingLatestInput<(UIImage, TimeInterval, Double)>()

    init(outputURL: URL, sourceSize: CGSize, withAudio: Bool,
         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         desqueeze: Double = 1,
         makeAudioCapture: (@Sendable () -> AVCaptureSession?)? = nil,
         makeWriter: @escaping @Sendable (URL) throws -> AVAssetWriter = {
             try AVAssetWriter(outputURL: $0, fileType: .mp4)
         },
         videoOperations: VideoOperations = .init(),
         onEncodingFailure: @escaping @Sendable () -> Void = {}) {
        self.makeAudioCapture = makeAudioCapture
        self.clock = clock
        self.makeWriter = makeWriter
        self.videoOperations = videoOperations
        self.onEncodingFailure = onEncodingFailure
        self.outputURL = outputURL
        self.width = max(2, Int((sourceSize.width * Self.validDesqueeze(desqueeze)).rounded()) & ~1)
        self.height = max(2, Int(sourceSize.height) & ~1)
        self.withAudio = withAudio
    }

    func start() -> Bool {
        queue.sync {
            guard writer == nil else { return false }
            do {
                try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                // Android SAF creates a new document; never remove an existing
                // recording. Own a unique staging directory until muxing finishes.
                let staging = outputURL.deletingLastPathComponent()
                    .appendingPathComponent(".recording_\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
                stagingDirectory = staging
                let temporary = staging.appendingPathComponent(outputURL.lastPathComponent)
                stagingURL = temporary
                let writer = try makeWriter(temporary)
                let bitRate = min(20_000_000, max(500_000, Int(Double(width * height) * 1.5 * 2)))
                let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: bitRate,
                        AVVideoExpectedSourceFrameRateKey: 60,
                        AVVideoMaxKeyFrameIntervalKey: 120
                    ]
                ])
                video.expectsMediaDataInRealTime = true
                guard writer.canAdd(video) else { release(); return false }
                writer.add(video)
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: video,
                    sourcePixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                        kCVPixelBufferWidthKey as String: width,
                        kCVPixelBufferHeightKey as String: height,
                        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                    ]
                )
                var audio: AVAssetWriterInput?
                var capture: AVCaptureSession?
                if withAudio, let configured = makeAudioCapture.map({ $0() }) ?? configureAudioCapture() {
                    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: 44_100,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderBitRateKey: 128_000
                    ])
                    input.expectsMediaDataInRealTime = true
                    if writer.canAdd(input) {
                        writer.add(input)
                        audio = input
                        capture = configured
                    }
                }
                guard writer.startWriting() else { release(); return false }
                writer.startSession(atSourceTime: .zero)
                self.writer = writer
                self.videoInput = video
                self.adaptor = adaptor
                self.audioInput = audio
                self.captureSession = capture
                // Android establishes the shared A/V epoch at recording start.
                self.baseUptime = clock()
                self.recording = true
                capture?.startRunning()
                return true
            } catch {
                release()
                return false
            }
        }
    }

    func append(image: UIImage, receivedAtUptime: TimeInterval, desqueeze: Double = 1) {
        guard pendingVideo.offer((image, receivedAtUptime, desqueeze)) else { return }
        queue.async { [weak self] in self?.drainLatestVideoFrame() }
    }

    /// Await work already submitted, without blocking the caller's actor.
    /// A delayed retry or a newly offered frame may still follow this barrier.
    func waitForSubmittedWork() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    func pause() {
        queue.async { [weak self] in
            guard let self, recording, !paused else { return }
            paused = true
            pauseStartedAt = clock()
            pendingVideo.discardPending()
            pendingAudio.discardPending()
        }
    }

    func resume() {
        queue.async { [weak self] in
            guard let self, recording, paused else { return }
            if let pauseStartedAt {
                pausedDuration += max(0, clock() - pauseStartedAt)
            }
            self.pauseStartedAt = nil
            paused = false
        }
    }

    func stop() async -> URL? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, recording, let writer else {
                    continuation.resume(returning: nil)
                    return
                }
                recording = false
                pendingVideo.discardPending()
                pendingAudio.discardPending()
                captureSession?.stopRunning()
                captureSession = nil
                // A terminal writer cannot accept input completion or another
                // finishWriting request. Failed recording never publishes staging.
                guard writer.status == .writing else {
                    release()
                    continuation.resume(returning: nil)
                    return
                }
                videoInput?.markAsFinished()
                audioInput?.markAsFinished()
                writer.finishWriting { [weak self] in
                    guard let self else { continuation.resume(returning: nil); return }
                    self.queue.async {
                        var published: URL?
                        if writer.status == .completed, let temporary = self.stagingURL {
                            published = try? OutputFileNameReservations.shared.withReservedName(self.outputURL) { destination in
                                try FileManager.default.moveItem(at: temporary, to: destination)
                                return destination
                            }
                        }
                        self.release()
                        continuation.resume(returning: published)
                    }
                }
            }
        }
    }

    private func drainLatestVideoFrame() {
        guard recording, !paused, !encodingFailures.stopped else {
            pendingVideo.discardAndFinish()
            return
        }
        let frame = pendingVideo.take()
        var retry: (UIImage, TimeInterval, Double)?
        if let frame {
            if encode(frame) {
                _ = encodingFailures.record(success: true)
            } else if encodingFailures.record(success: false) {
                pendingVideo.discardAndFinish()
                onEncodingFailure()
                return
            } else {
                retry = frame
            }
        }
        // Yield after one frame, so pause/stop are not starved by new input.
        guard pendingVideo.finish(retry: retry) else { return }
        if retry != nil {
            queue.asyncAfter(deadline: .now() + .milliseconds(5)) { [weak self] in
                self?.drainLatestVideoFrame()
            }
        } else {
            queue.async { [weak self] in self?.drainLatestVideoFrame() }
        }
    }

    private func encode(_ frame: (UIImage, TimeInterval, Double)) -> Bool {
        guard let writer, writer.status == .writing, let videoInput, let adaptor else { return false }
        guard videoOperations.isReady(videoInput) else { return true }
        guard let pixelBuffer = makePixelBuffer(from: frame.0, desqueeze: frame.2, pool: adaptor.pixelBufferPool)
        else { return false }
        guard let baseUptime else { return false }
        var seconds = max(0, frame.1 - baseUptime - pausedDuration)
        if lastVideoPTS.isValid { seconds = max(seconds, CMTimeGetSeconds(lastVideoPTS) + 0.000_001) }
        let pts = CMTime(seconds: seconds, preferredTimescale: 1_000_000)
        guard videoOperations.append(adaptor, pixelBuffer, pts) else { return false }
        lastVideoPTS = pts
        return true
    }

    private func configureAudioCapture() -> AVCaptureSession? {
        guard let device = AVCaptureDevice.default(for: .audio),
              let deviceInput = try? AVCaptureDeviceInput(device: device) else { return nil }
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        guard session.canAddInput(deviceInput), session.canAddOutput(output) else { return nil }
        session.beginConfiguration()
        session.addInput(deviceInput)
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: audioQueue)
        session.commitConfiguration()
        return session
    }

    @objc func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                             from connection: AVCaptureConnection) {
        appendAudioSample(sampleBuffer)
    }

    func appendAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard pendingAudio.offer(sampleBuffer) else { return }
        queue.async { [weak self] in self?.drainLatestAudioSample() }
    }

    private func drainLatestAudioSample() {
        guard recording, !paused else {
            pendingAudio.discardAndFinish()
            return
        }
        if let sample = pendingAudio.take() { appendAudio(sample) }
        if pendingAudio.finish() {
            queue.async { [weak self] in self?.drainLatestAudioSample() }
        }
    }

    private func appendAudio(_ sample: CMSampleBuffer) {
        guard recording, !paused, let input = audioInput, input.isReadyForMoreMediaData,
              let baseUptime else { return }
        let originalPTS = CMSampleBufferGetPresentationTimeStamp(sample)
        guard originalPTS.isValid else { return }
        let adjusted = max(0, CMTimeGetSeconds(originalPTS) - baseUptime - pausedDuration)
        var needed = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0,
                                                     arrayToFill: nil, entriesNeededOut: &needed) == noErr,
              needed > 0 else { return }
        var timings = Array(repeating: CMSampleTimingInfo(), count: needed)
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: needed,
                                                     arrayToFill: &timings, entriesNeededOut: &needed) == noErr else { return }
        let delta = CMTimeSubtract(CMTime(seconds: adjusted, preferredTimescale: 1_000_000), originalPTS)
        for index in timings.indices {
            timings[index].presentationTimeStamp = CMTimeAdd(timings[index].presentationTimeStamp, delta)
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = CMTimeAdd(timings[index].decodeTimeStamp, delta)
            }
        }
        var retimed: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                     sampleBuffer: sample,
                                                     sampleTimingEntryCount: timings.count,
                                                     sampleTimingArray: &timings,
                                                     sampleBufferOut: &retimed) == noErr,
              let retimed else { return }
        guard fillAudioGap(before: retimed, input: input), input.isReadyForMoreMediaData,
              input.append(retimed) else { return }
        lastAudioEnd = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(retimed), CMSampleBufferGetDuration(retimed))
    }

    /// AVAssetWriter's AAC converter concatenates PCM even across timestamp
    /// gaps. Feed bounded silent buffers to preserve elapsed capture time.
    private func fillAudioGap(before sample: CMSampleBuffer, input: AVAssetWriterInput) -> Bool {
        guard var end = lastAudioEnd else { return true }
        guard let description = CMSampleBufferGetFormatDescription(sample) else { return false }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let rate = format.sampleRate
        guard rate.isFinite, rate > 0, rate <= Double(Int32.max) else { return false }
        let target = CMSampleBufferGetPresentationTimeStamp(sample)
        while CMTimeSubtract(target, end).seconds * rate >= 1 {
            guard input.isReadyForMoreMediaData else { return false }
            let remaining = CMTimeSubtract(target, end).seconds * rate
            let count = AVAudioFrameCount(min(4096, remaining.rounded()))
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return false }
            pcm.frameLength = count
            for buffer in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList) {
                guard let data = buffer.mData else { return false }
                memset(data, 0, Int(buffer.mDataByteSize))
            }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)),
                                            presentationTimeStamp: end, decodeTimeStamp: .invalid)
            var silence: CMSampleBuffer?
            guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
                sampleCount: Int(count), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &silence) == noErr,
                let silence,
                CMSampleBufferSetDataBufferFromAudioBufferList(silence, blockBufferAllocator: kCFAllocatorDefault,
                    blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr,
                input.append(silence) else { return false }
            end = CMTimeAdd(end, CMTime(value: Int64(count), timescale: Int32(rate)))
            lastAudioEnd = end
        }
        return true
    }

    static func validDesqueeze(_ value: Double) -> Double {
        value.isFinite && (1...2).contains(value) ? value : 1
    }

    static func fittedFrame(source: CGSize, canvas: CGSize, desqueeze: Double) -> CGRect {
        let aspect = source.width * validDesqueeze(desqueeze) / max(1, source.height)
        let width = min(canvas.width, canvas.height * aspect)
        let height = width / max(aspect, .leastNonzeroMagnitude)
        return CGRect(x: (canvas.width - width) / 2, y: (canvas.height - height) / 2,
                      width: width, height: height)
    }

    private func makePixelBuffer(from image: UIImage, desqueeze: Double, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
              let buffer, let cg = image.cgImage else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(data: base, width: width, height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                          CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(cg, in: Self.fittedFrame(source: CGSize(width: cg.width, height: cg.height),
                                             canvas: CGSize(width: width, height: height), desqueeze: desqueeze))
        return buffer
    }

    private func release() {
        if captureSession?.isRunning == true { captureSession?.stopRunning() }
        captureSession = nil
        writer = nil
        videoInput = nil
        audioInput = nil
        adaptor = nil
        baseUptime = nil
        lastAudioEnd = nil
        pauseStartedAt = nil
        pausedDuration = 0
        paused = false
        lastVideoPTS = .invalid
        if let stagingDirectory { try? FileManager.default.removeItem(at: stagingDirectory) }
        stagingDirectory = nil
        stagingURL = nil
    }

    static func outputURL(preferredDirectory: URL?) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let name = "rec_\(formatter.string(from: Date())).mp4"
        if let preferredDirectory { return preferredDirectory.appendingPathComponent(name) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("recordings", isDirectory: true)
        return base.appendingPathComponent(name)
    }
}
