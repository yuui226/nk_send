import Foundation

/// Local Debug snapshots of existing work only; no probes or per-frame writes.
/// Release never evaluates the report expression.
enum CameraRuntimeDiagnostics {
    enum Kind: String { case transportFailure, review, level }
    #if DEBUG
    private static let output = DispatchQueue(label: "com.ztransfer.camera-runtime-diagnostics", qos: .utility)
    static func record(_ kind: Kind, _ report: @autoclosure () -> String) {
        let text = "recorded=\(Date().ISO8601Format())\n" + String(report().prefix(8192))
        output.async {
            guard let directory = try? FileManager.default.url(for: .cachesDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true) else { return }
            try? Data(text.utf8).write(to: directory.appendingPathComponent("Camera-\(kind.rawValue)-latest.txt"), options: .atomic)
        }
    }
    #else
    static func record(_ kind: Kind, _ report: @autoclosure () -> String) {}
    #endif
}

/// Passive timing of existing operations. No UI publication or extra requests.
/// Release does not evaluate messages/clocks or allocate recording storage.
final class STAConnectionTrace: @unchecked Sendable {
    #if DEBUG
    private let lock = NSLock()
    private let now: @Sendable () -> Int64
    private var start: Int64
    private var previous: Int64
    private var lines: [String] = []
    private var omitted = 0
    #endif
    init(now: @escaping @Sendable () -> Int64 = { Int64(ProcessInfo.processInfo.systemUptime * 1_000) }) {
        #if DEBUG
        self.now = now; start = now(); previous = start
        #endif
    }
    func note(_ message: @autoclosure () -> String) {
        #if DEBUG
        lock.withLock {
            let time = now()
            if lines.count == 256 { lines.remove(at: 128); omitted += 1 }
            lines.append("+\(max(0, time - start))ms Δ\(max(0, time - previous))ms \(message())")
            previous = time
        }
        #endif
    }
    func report() -> String {
        #if DEBUG
        lock.withLock {
            var output = lines
            if omitted > 0 { output.insert("中间省略 \(omitted) 条", at: 128) }
            return (["+ms=本次连接起点；Δms=距上一条记录（含请求、解析或等待）"] + output).joined(separator: "\n")
        }
        #else
        ""
        #endif
    }
}

/// Android StaDiagnosticHistory: preserve complete attempts, never accept a
/// cancelled discovery's callbacks into its successor. Only Debug owns data.
final class STADiagnosticHistory: @unchecked Sendable {
    private let lock = NSLock()
    private let now: @Sendable () -> Int64
    private var next: UInt64 = 0
    private final class Session {
        let id: UInt64, start: Int64
        let date: String
        init(id: UInt64, start: Int64, date: String) { self.id = id; self.start = start; self.date = date }
        var blocks: [String] = []
        var characters = 0, omitted = 0
        var completion: String?
    }
    private var current: Session?
    init(now: @escaping @Sendable () -> Int64 = { Int64(ProcessInfo.processInfo.systemUptime * 1_000) }) { self.now = now }
    func begin() -> UInt64 {
        lock.withLock {
            next &+= 1
            current = Session(id: next, start: now(), date: Date().ISO8601Format())
            return next
        }
    }
    func note(_ id: UInt64, _ text: String) {
        lock.withLock { append(id, text) }
    }
    func attempt(_ id: UInt64, label: String, report: String) {
        guard !report.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        note(id, "attempt [\(label)]\n" + report.trimmingCharacters(in: .newlines))
    }
    @discardableResult
    func finish(_ id: UInt64, _ outcome: String) -> String? {
        lock.withLock {
            guard let session = current, session.id == id, session.completion == nil else { return nil }
            let elapsed = max(0, now() - session.start)
            session.completion = "+\(elapsed)ms result=\(outcome.prefix(160))"
            return report(session)
        }
    }
    func clear() { lock.withLock { current = nil } }
    func isCurrent(_ id: UInt64) -> Bool { lock.withLock { current?.id == id } }
    func snapshot() -> String {
        lock.withLock {
            guard let s = current else { return "暂无 STA 连接记录" }
            return report(s)
        }
    }
    private func report(_ s: Session) -> String {
        let omitted = s.omitted > 0 ? ["省略较早记录 \(s.omitted) 块；保留的 attempt 均为完整内容"] : []
        return (["session=\(s.id) started=\(s.date)"] + omitted + s.blocks +
            [s.completion ?? "+\(max(0, now() - s.start))ms result=running"]).joined(separator: "\n")
    }
    private func append(_ id: UInt64, _ text: String) {
        guard let s = current, s.id == id, s.completion == nil else { return }
        let block = "+\(max(0, now() - s.start))ms \(text)"
        let count = block.utf16.count
        if count > 65_536 { s.omitted += 1 }
        else {
            while !s.blocks.isEmpty && (s.characters + count > 65_536 || s.blocks.count >= 160) {
                s.characters -= s.blocks.removeFirst().utf16.count; s.omitted += 1
            }
            s.blocks.append(block); s.characters += count
        }
    }
}

enum STAConnectionDiagnostics {
    #if DEBUG
    static let history = STADiagnosticHistory()
    private static let outputQueue = DispatchQueue(label: "com.ztransfer.sta-connection-diagnostics", qos: .utility)
    private static var reportHeader: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "ZTransfer STA 连接诊断 v1 app=\(info["CFBundleShortVersionString"] ?? "")(\(info["CFBundleVersion"] ?? ""))\n" +
            "单位 ms；+ 为本次连接开始后的时间。仅记录已有流程，不发送额外请求。\n"
    }
    private static func latestReportURL() throws -> URL {
        try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("STAConnection-latest.txt")
    }
    static func begin() -> UInt64 { history.begin() }
    static func note(_ id: UInt64, _ text: @autoclosure () -> String) { history.note(id, text()) }
    static func attempt(_ id: UInt64, label: @autoclosure () -> String, report: @autoclosure () -> String) {
        history.attempt(id, label: label(), report: report())
    }
    static func finish(_ id: UInt64, _ outcome: @autoclosure () -> String) {
        guard let finished = history.finish(id, outcome()) else { return }
        let report = reportHeader + finished
        // One bounded, app-private report per completed attempt. This lets
        // device diagnostics read the real socket cause without UI copying or
        // attaching a debugger. No per-frame writes or release-build output.
        outputQueue.async {
            guard history.isCurrent(id) else { return }
            do { try report.write(to: latestReportURL(), atomically: true, encoding: .utf8) }
            catch { NSLog("STA connection diagnostics persistence unavailable") }
        }
    }
    static func clear() {
        history.clear()
        outputQueue.async { if let url = try? latestReportURL() { try? FileManager.default.removeItem(at: url) } }
    }
    static func snapshot() -> String {
        reportHeader + history.snapshot()
    }
    #else
    static func begin() -> UInt64 { 0 }
    static func note(_ id: UInt64, _ text: @autoclosure () -> String) {}
    static func attempt(_ id: UInt64, label: @autoclosure () -> String, report: @autoclosure () -> String) {}
    static func finish(_ id: UInt64, _ outcome: @autoclosure () -> String) {}
    #endif
}
