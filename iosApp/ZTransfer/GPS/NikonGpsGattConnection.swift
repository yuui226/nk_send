import Foundation
import Combine

enum GpsGattChannel: String, CaseIterable { case pair, notification, controllerId, geo }
struct GpsBluetoothCandidate: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
}
enum GpsGattError: Error, Equatable {
    case unavailable, unknownDevice, invalidState, missingService, missingCharacteristic
    case notificationUnavailable, disconnected, timedOut, closed, queueFull, invalidPayload, payloadTooLarge, eventOverflow
}
enum GpsGattDriverEvent {
    case scanning
    case candidate(GpsBluetoothCandidate)
    case ready(maximumWriteLength: Int)
    case value(GpsGattChannel, Data)
    case written(GpsGattChannel, Error?)
    case failed(Error)
}

/// Main-queue platform seam. A driver is single-use, and must not synthesize write acknowledgements.
@MainActor protocol NikonGpsGattDriver: AnyObject {
    var eventHandler: ((GpsGattDriverEvent) -> Void)? { get set }
    func scan()
    func stopScan()
    func connect(_ identifier: UUID)
    func write(_ data: Data, channel: GpsGattChannel)
    func close()
}

/// One BLE generation, not a GPS authentication state. Only .withResponse callbacks finish writes.
/// No business pairing/retry rules here. A lost callback poisons the generation: a late callback has
/// no transaction identifier and must never complete a subsequent write to the same characteristic.
@MainActor final class NikonGpsGattConnection: ObservableObject {
    enum Phase: String { case idle, starting, scanning, selecting, connecting, gattReady, closed, failed }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var candidates: [GpsBluetoothCandidate] = []
    @Published private(set) var failure: Error?
    let values: AsyncThrowingStream<(GpsGattChannel, Data), Error>
    private let valueContinuation: AsyncThrowingStream<(GpsGattChannel, Data), Error>.Continuation
    private let driver: NikonGpsGattDriver
    private let operationTimeout: TimeInterval
    private var phaseTimer: Task<Void, Never>?
    private var phaseTimerID = UUID()
    private var maximumWriteLength = 0
    private struct Write {
        let id: UUID
        let channel: GpsGattChannel
        let bytes: Data
        let continuation: CheckedContinuation<Void, Error>
    }
    private var queue: [Write] = []
    private var active: Write?
    private var writeTimer: Task<Void, Never>?

    init(driver: NikonGpsGattDriver, operationTimeout: TimeInterval = 3) {
        self.driver = driver
        self.operationTimeout = min(30, max(0.01, operationTimeout))
        var continuation: AsyncThrowingStream<(GpsGattChannel, Data), Error>.Continuation!
        values = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(32)) { continuation = $0 }
        valueContinuation = continuation
        driver.eventHandler = { [weak self] event in self?.receive(event) }
    }

    func scan() throws {
        guard phase == .idle else { throw GpsGattError.invalidState }
        phase = .starting
        armPhaseTimeout(seconds: 10)
        driver.scan()
    }

    func stopScan() {
        guard phase == .scanning || phase == .starting else { return }
        cancelPhaseTimer()
        driver.stopScan()
        phase = .selecting
    }

    func connect(_ identifier: UUID) throws {
        guard phase == .scanning || phase == .selecting else { throw GpsGattError.invalidState }
        guard candidates.contains(where: { $0.id == identifier }) else { throw GpsGattError.unknownDevice }
        driver.stopScan()
        phase = .connecting
        armPhaseTimeout(seconds: 15)
        driver.connect(identifier)
    }

    func write(_ bytes: Data, channel: GpsGattChannel) async throws {
        try Task.checkCancellation()
        guard phase == .gattReady else { throw GpsGattError.invalidState }
        let expected: Int
        switch channel {
        case .pair: expected = 17
        case .controllerId: expected = 32
        case .geo: expected = 41
        case .notification: throw GpsGattError.invalidPayload
        }
        guard bytes.count == expected else { throw GpsGattError.invalidPayload }
        // Do not split Nikon packets at an invented ATT size. CoreBluetooth handles the supported
        // with-response length; a smaller negotiated limit is an explicit compatibility failure.
        guard bytes.count <= maximumWriteLength else { throw GpsGattError.payloadTooLarge }
        guard queue.count < 16 else { throw GpsGattError.queueFull }
        let identifier = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                queue.append(Write(id: identifier, channel: channel, bytes: bytes, continuation: continuation))
                drain()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWrite(identifier) }
        }
    }

    func close() { finish(error: GpsGattError.closed, failed: false) }

    private func receive(_ event: GpsGattDriverEvent) {
        guard phase != .closed && phase != .failed else { return }
        switch event {
        case .scanning:
            guard phase == .starting else { return }
            phase = .scanning
            cancelPhaseTimer()
            let id = phaseTimerID
            phaseTimer = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
                guard let self, self.phaseTimerID == id else { return }
                self.stopScan()
            }
        case .candidate(let value):
            guard phase == .scanning else { return }
            if let index = candidates.firstIndex(where: { $0.id == value.id }) { candidates[index] = value }
            else if candidates.count < 64 { candidates.append(value) }
        case .ready(let limit):
            guard phase == .connecting else { return }
            cancelPhaseTimer()
            maximumWriteLength = limit
            phase = .gattReady
        case .value(let channel, let bytes):
            guard phase == .connecting || phase == .gattReady else { return }
            guard bytes.count <= 512 else { finish(error: GpsGattError.invalidPayload); return }
            // Dropping protocol notifications is unsafe even though UI status may be conflated.
            if case .dropped = valueContinuation.yield((channel, bytes)) { finish(error: GpsGattError.eventOverflow) }
        case .written(let channel, let error):
            guard let current = active, current.channel == channel else { return }
            if let error { finish(error: error); return }
            writeTimer?.cancel(); writeTimer = nil; active = nil
            current.continuation.resume()
            drain()
        case .failed(let error): finish(error: error)
        }
    }

    private func drain() {
        guard phase == .gattReady, active == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        active = next
        writeTimer = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: UInt64(self.operationTimeout * 1_000_000_000)) } catch { return }
            guard self.active?.id == next.id else { return }
            self.finish(error: GpsGattError.timedOut)
        }
        driver.write(next.bytes, channel: next.channel)
    }

    private func cancelWrite(_ id: UUID) {
        if active?.id == id { finish(error: CancellationError()); return }
        if let index = queue.firstIndex(where: { $0.id == id }) {
            queue.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }

    private func cancelPhaseTimer() { phaseTimerID = UUID(); phaseTimer?.cancel(); phaseTimer = nil }
    private func armPhaseTimeout(seconds: TimeInterval) {
        cancelPhaseTimer()
        let id = phaseTimerID
        phaseTimer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
            guard let self, self.phaseTimerID == id else { return }
            self.finish(error: GpsGattError.timedOut)
        }
    }

    private func finish(error: Error, failed: Bool = true) {
        guard phase != .closed && phase != .failed else { return }
        phase = failed ? .failed : .closed
        failure = failed ? error : nil
        cancelPhaseTimer(); writeTimer?.cancel(); writeTimer = nil
        driver.eventHandler = nil
        driver.close()
        let waiting = queue; queue.removeAll()
        let current = active; active = nil
        current?.continuation.resume(throwing: error)
        for item in waiting { item.continuation.resume(throwing: error) }
        valueContinuation.finish(throwing: error)
    }
}
