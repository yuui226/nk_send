import Foundation

/// Opt-in per-file STA diagnostics. No photo bytes, names, paths or addresses.
/// Clock reads and counters stay on the hot path; file I/O is offloaded.
/// Network wait includes framework scheduling, and is NOT a wire RTT measurement.
final class PTPTransferDiagnostics: @unchecked Sendable {
    static var isEnabledForDevelopmentLaunch: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["ZTRANSFER_STA_DIAGNOSTICS"] == "1"
        #else
        false
        #endif
    }
    private let lock = NSLock()
    private let id = UUID().uuidString
    private let started = ContinuousClock.now
    private var chunkStarted = ContinuousClock.now
    private var previousChunkEnd: ContinuousClock.Instant?
    private var firstRead: ContinuousClock.Instant?
    private var lastCheckpoint = ContinuousClock.now
    private var values: [String: Double] = [:]
    private var fileWrites: Double = 0
    private var fileWriteMS: Double = 0
    private var chunk = 0
    private var tcpSnapshot: (@Sendable () -> [String: Double]?)?
    private var tcpBaseline: [String: Double] = [:]
    private let emit: @Sendable (String) -> Void

    init(emit: @escaping @Sendable (String) -> Void = PTPTransferDiagnostics.persist) {
        self.emit = emit
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let parts = start.duration(to: .now).components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }

    func beginFile(size: UInt64) { publish("file_begin", extra: ["expected_bytes": Double(size)]) }

    func beginChunk(offset: UInt64, requested: UInt64) {
        lock.withLock {
            chunk += 1
            values = ["offset": Double(offset), "requested_bytes": Double(requested)]
            tcpSnapshot = nil
            tcpBaseline = [:]
            if let previousChunkEnd { values["between_chunks_ms"] = Self.milliseconds(since: previousChunkEnd) }
            chunkStarted = .now
            firstRead = nil
            lastCheckpoint = .now
        }
        publish("chunk_begin")
    }

    func gateAcquired() { mark("gate_acquired_ms") }
    func transport(bsdSocket: Bool, receiveBufferBytes: Int?,
                   tcpSnapshot: (@Sendable () -> [String: Double]?)? = nil) {
        let baseline = tcpSnapshot?() ?? [:]
        lock.withLock {
            self.tcpSnapshot = tcpSnapshot
            tcpBaseline = baseline
            values["bsd_socket"] = bsdSocket ? 1 : 0
            // -1 means unavailable, never infer a kernel buffer from a
            // Network.framework maximumLength argument.
            values["kernel_receive_buffer_bytes"] = Double(receiveBufferBytes ?? -1)
        }
    }
    func sessionAcquired() { mark("session_acquired_ms") }
    func commandSent() { mark("command_sent_ms") }
    // In this mode posixRead measures recv only; there is no per-read queue /
    // continuation. Worker dispatch and packet assembly remain in file time.
    func continuousReadWorkerStarted() {
        lock.withLock { values["posix_phase_worker_calls", default: 0] += 1 }
    }
    private func mark(_ field: String) {
        lock.withLock { values[field] = Self.milliseconds(since: chunkStarted) }
    }

    func read(bytes: Int, waitedMS: Double) {
        let checkpoint = lock.withLock {
            if firstRead == nil {
                firstRead = .now
                values["first_read_ms"] = Self.milliseconds(since: chunkStarted)
            }
            values["read_calls", default: 0] += 1
            values["wire_bytes", default: 0] += Double(bytes)
            values["receive_wait_ms", default: 0] += waitedMS
            values["max_receive_wait_ms"] = max(values["max_receive_wait_ms", default: 0], waitedMS)
            if waitedMS >= 50 { values["reads_waiting_50ms", default: 0] += 1 }
            if lastCheckpoint.duration(to: .now) >= .seconds(5) {
                lastCheckpoint = .now
                return true
            }
            return false
        }
        if checkpoint { publish("receiving") }
    }

    /// Subdivides the outer receive_wait_ms, not additional elapsed time.
    /// Syscall time is recv wall time (including any preemption), not wire RTT.
    func posixRead(queueMS: Double, syscallMS: Double, workerOtherMS: Double, resumeMS: Double) {
        lock.withLock {
            values["posix_read_calls", default: 0] += 1
            values["posix_queue_wait_ms", default: 0] += queueMS
            values["posix_syscall_ms", default: 0] += syscallMS
            values["posix_worker_other_ms", default: 0] += workerOtherMS
            values["posix_resume_wait_ms", default: 0] += resumeMS
            if syscallMS >= 50 {
                values["posix_slow_syscall_count", default: 0] += 1
                values["posix_slow_syscall_ms", default: 0] += syscallMS
            }
        }
    }

    func sink(bytes: Int, elapsedMS: Double) {
        lock.withLock {
            if values["first_payload_ms"] == nil { values["first_payload_ms"] = Self.milliseconds(since: chunkStarted) }
            values["payload_bytes", default: 0] += Double(bytes)
            values["sink_ms", default: 0] += elapsedMS
        }
    }

    func write(bytes: Int, elapsedMS: Double) {
        lock.withLock {
            fileWrites += 1
            fileWriteMS += elapsedMS
            values["write_calls", default: 0] += 1
            values["write_bytes", default: 0] += Double(bytes)
            values["write_ms", default: 0] += elapsedMS
        }
    }

    func endChunk(code: UInt16?) {
        publish("chunk_end", extra: ["response_code": code.map(Double.init) ?? -1])
        lock.withLock { previousChunkEnd = .now }
    }

    func finish(success: Bool, finalizeMS: Double) {
        publish("file_end", extra: ["success": success ? 1 : 0, "finalize_ms": finalizeMS])
    }

    private func publish(_ event: String, extra: [String: Double] = [:]) {
        let (snapshot, baseline) = lock.withLock { (tcpSnapshot, tcpBaseline) }
        var tcpFields: [String: Double] = [:]
        if let snapshot {
            let current = snapshot()
            tcpFields = current ?? [:]
            tcpFields["tcp_info_available"] = current == nil ? 0 : 1
            // Kernel counters cover the whole connection. Also report chunk
            // deltas; never interpret pre-existing thumbnail traffic as file I/O.
            for (key, start) in baseline where key.hasSuffix("_total") {
                if let end = current?[key], end >= start {
                    tcpFields[String(key.dropLast(6)) + "_chunk"] = end - start
                }
            }
        }
        let record: [String: String] = lock.withLock {
            var fields = values.merging(tcpFields) { _, new in new }.merging(extra) { _, new in new }
            fields["chunk"] = Double(chunk)
            fields["chunk_elapsed_ms"] = Self.milliseconds(since: chunkStarted)
            fields["file_elapsed_ms"] = Self.milliseconds(since: started)
            fields["file_write_calls"] = fileWrites
            fields["file_write_ms"] = fileWriteMS
            var result = fields.mapValues { String(format: "%.3f", $0) }
            result["event"] = event
            result["id"] = id
            result["schema"] = "1"
            return result
        }
        // Encoding is bounded (one short record per chunk or five seconds).
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        emit(line)
    }

    private static let outputQueue = DispatchQueue(label: "com.ztransfer.sta-diagnostics", qos: .utility)
    static func persist(_ line: String) {
        #if DEBUG
        outputQueue.async {
            do {
                let manager = FileManager.default
                let directory = try manager.url(for: .cachesDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
                    .appendingPathComponent("Diagnostics", isDirectory: true)
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
                let current = directory.appendingPathComponent("sta-transfer.jsonl")
                let previous = directory.appendingPathComponent("sta-transfer.previous.jsonl")
                if let size = try? current.resourceValues(forKeys: [.fileSizeKey]).fileSize, size >= 2 * 1024 * 1024 {
                    if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
                    try manager.moveItem(at: current, to: previous)
                }
                if !manager.fileExists(atPath: current.path) { manager.createFile(atPath: current.path, contents: nil) }
                let file = try FileHandle(forWritingTo: current)
                defer { try? file.close() }
                try file.seekToEnd()
                try file.write(contentsOf: Data((line + "\n").utf8))
            } catch {
                // A diagnostics failure must never affect the transfer.
                NSLog("STA diagnostics persistence unavailable")
            }
        }
        #endif
    }
}
