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

    static func startFailed(_ result: RemoteMovieStartResult?) -> Self {
        let detail = result.map { "\n" + $0.diagnosticSummary } ?? ""
        return Self(message: AppLocalized.resource("remote_rec_start_failed") + detail,
                    durationNanoseconds: 12_000_000_000)
    }

    static func stopFailed(responseCode: UInt16 = 0xFFFF) -> Self {
        Self(message: AppLocalized.resource("remote_rec_stop_failed") +
                 String(format: "\nstop=0x%04X", responseCode),
             durationNanoseconds: 6_000_000_000)
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
final class RemoteViewfinderRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let outputURL: URL
    private let width: Int
    private let height: Int
    private let withAudio: Bool
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
    private var lastVideoPTS = CMTime.invalid
    private var videoAppendPending = false
    private var newestPendingFrame: (UIImage, TimeInterval)?

    init(outputURL: URL, sourceSize: CGSize, withAudio: Bool) {
        self.outputURL = outputURL
        self.width = max(2, Int(sourceSize.width) & ~1)
        self.height = max(2, Int(sourceSize.height) & ~1)
        self.withAudio = withAudio
    }

    func start() -> Bool {
        queue.sync {
            do {
                try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: outputURL)
                let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
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
                guard writer.canAdd(video) else { release(deleteOutput: true); return false }
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
                if withAudio, let configured = configureAudioCapture() {
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
                guard writer.startWriting() else { release(deleteOutput: true); return false }
                writer.startSession(atSourceTime: .zero)
                self.writer = writer
                self.videoInput = video
                self.adaptor = adaptor
                self.audioInput = audio
                self.captureSession = capture
                self.recording = true
                capture?.startRunning()
                return true
            } catch {
                release(deleteOutput: true)
                return false
            }
        }
    }

    func append(image: UIImage, receivedAtUptime: TimeInterval) {
        queue.async { [weak self] in
            guard let self, recording, !paused else { return }
            newestPendingFrame = (image, receivedAtUptime)
            guard !videoAppendPending else { return }
            videoAppendPending = true
            drainLatestVideoFrame()
        }
    }

    func pause() {
        queue.async { [weak self] in
            guard let self, recording, !paused else { return }
            paused = true
            pauseStartedAt = ProcessInfo.processInfo.systemUptime
            newestPendingFrame = nil
        }
    }

    func resume() {
        queue.async { [weak self] in
            guard let self, recording, paused else { return }
            if let pauseStartedAt {
                pausedDuration += max(0, ProcessInfo.processInfo.systemUptime - pauseStartedAt)
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
                newestPendingFrame = nil
                captureSession?.stopRunning()
                captureSession = nil
                videoInput?.markAsFinished()
                audioInput?.markAsFinished()
                writer.finishWriting { [weak self] in
                    guard let self else { continuation.resume(returning: nil); return }
                    self.queue.async {
                        let success = writer.status == .completed
                        self.release(deleteOutput: !success)
                        continuation.resume(returning: success ? self.outputURL : nil)
                    }
                }
            }
        }
    }

    private func drainLatestVideoFrame() {
        defer { videoAppendPending = false }
        while recording, !paused, let frame = newestPendingFrame {
            newestPendingFrame = nil
            guard let writer, writer.status == .writing,
                  let videoInput, videoInput.isReadyForMoreMediaData,
                  let adaptor, let pixelBuffer = makePixelBuffer(from: frame.0, pool: adaptor.pixelBufferPool)
            else { continue }
            if baseUptime == nil { baseUptime = frame.1 }
            guard let baseUptime else { continue }
            var seconds = max(0, frame.1 - baseUptime - pausedDuration)
            if lastVideoPTS.isValid {
                seconds = max(seconds, CMTimeGetSeconds(lastVideoPTS) + 0.000_001)
            }
            let pts = CMTime(seconds: seconds, preferredTimescale: 1_000_000)
            if adaptor.append(pixelBuffer, withPresentationTime: pts) { lastVideoPTS = pts }
        }
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
        queue.async { [weak self] in self?.appendAudio(sampleBuffer) }
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
        _ = input.append(retimed)
    }

    private func makePixelBuffer(from image: UIImage, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
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
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private func release(deleteOutput: Bool) {
        if captureSession?.isRunning == true { captureSession?.stopRunning() }
        captureSession = nil
        writer = nil
        videoInput = nil
        audioInput = nil
        adaptor = nil
        baseUptime = nil
        pauseStartedAt = nil
        pausedDuration = 0
        paused = false
        lastVideoPTS = .invalid
        if deleteOutput { try? FileManager.default.removeItem(at: outputURL) }
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
