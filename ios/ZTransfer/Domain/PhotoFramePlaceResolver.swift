import CoreLocation
import Foundation
import Combine
import Network

/// Android uses a 32-entry access-order cache with distinct success/failure TTLs.
struct PhotoFramePlaceCache {
    struct Entry {
        let place: PhotoFramePlace?
        let time: TimeInterval
    }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    var count: Int { entries.count }

    static func key(latitude: Double, longitude: Double, locale: Locale) -> String {
        locale.identifier.replacingOccurrences(of: "_", with: "-") +
            String(format: ":%.4f,%.4f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
    }

    mutating func entry(for key: String, now: TimeInterval) -> Entry? {
        guard let entry = entries[key] else { return nil }
        touch(key)
        return now - entry.time < (entry.place == nil ? 60 : 86_400) ? entry : nil
    }

    mutating func insert(_ place: PhotoFramePlace?, for key: String, now: TimeInterval) {
        entries[key] = Entry(place: place, time: now)
        touch(key)
        if order.count > 32 { entries.removeValue(forKey: order.removeFirst()) }
    }

    private mutating func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

actor PhotoFramePlaceResolver {
    static let shared = PhotoFramePlaceResolver()
    typealias Query = @Sendable (Double, Double, Locale) async -> PhotoFramePlace?
    private struct Request {
        let key: String
        let latitude: Double
        let longitude: Double
        let locale: Locale
        let allowed: @Sendable () async -> Bool
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<PhotoFramePlace?, Never>
        let timer: Task<Void, Never>
    }
    private var cache = PhotoFramePlaceCache()
    private let query: Query
    private var requests: [UUID: Request] = [:]
    private var waiting: [UUID] = []
    private var attempted: Set<UUID> = []
    private var active: UUID?
    private var worker: Task<Void, Never>?
    var pendingCount: Int { requests.count }

    init(query: @escaping Query = PhotoFramePlaceResolver.systemQuery) { self.query = query }

    func resolve(latitude: Double, longitude: Double, timeout: Duration = .seconds(1), locale: Locale = photoFramePlaceLocale(),
                 allowed: @escaping @Sendable () async -> Bool = { true }) async -> PhotoFramePlace? {
        guard !Task.isCancelled, validPhotoFrameCoordinates(latitude, longitude) else { return nil }
        let key = PhotoFramePlaceCache.key(latitude: latitude, longitude: longitude, locale: locale)
        if let cached = cache.entry(for: key, now: ProcessInfo.processInfo.systemUptime) { return cached.place }
        let budget = min(max(timeout, .zero), .seconds(1))
        guard budget > .zero else { return nil }
        let id = UUID()
        let deadline = ContinuousClock.now.advanced(by: budget)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                let timer = Task { [weak self] in
                    do { try await Task.sleep(until: deadline, clock: .continuous) }
                    catch { return }
                    await self?.finish(id, place: nil)
                }
                requests[id] = Request(key: key, latitude: latitude, longitude: longitude,
                    locale: locale, allowed: allowed, deadline: deadline, continuation: continuation, timer: timer)
                waiting.append(id)
                startNext()
            }
        } onCancel: { Task { await self.finish(id, place: nil) } }
    }

    private func startNext() {
        guard active == nil else { return }
        while !waiting.isEmpty {
            let id = waiting.removeFirst()
            guard let request = requests[id] else { continue }
            if ContinuousClock.now >= request.deadline {
                requests.removeValue(forKey: id)
                request.timer.cancel()
                request.continuation.resume(returning: nil)
                continue
            }
            if let cached = cache.entry(for: request.key, now: ProcessInfo.processInfo.systemUptime) {
                requests.removeValue(forKey: id)
                request.timer.cancel()
                request.continuation.resume(returning: cached.place)
                continue
            }
            active = id
            let query = self.query
            worker = Task { [weak self] in
                guard !Task.isCancelled, await self?.beginQuery(id) == true else {
                    await self?.finish(id, place: nil)
                    return
                }
                let result = await query(request.latitude, request.longitude, request.locale)
                await self?.finish(id, place: result)
            }
            return
        }
    }

    private func beginQuery(_ id: UUID) async -> Bool {
        guard let request = requests[id], await request.allowed(),
              !Task.isCancelled, active == id, requests[id] != nil,
              ContinuousClock.now < request.deadline else { return false }
        attempted.insert(id)
        return true
    }

    /// Complete the caller independently of the backend. A late callback cannot
    /// overwrite a timeout's negative cache entry or complete a newer request.
    private func finish(_ id: UUID, place: PhotoFramePlace?) {
        guard let request = requests.removeValue(forKey: id) else { return }
        request.timer.cancel()
        waiting.removeAll { $0 == id }
        var result = place
        if ContinuousClock.now >= request.deadline { result = nil }
        if result?.city == nil && result?.region == nil { result = nil }
        let didAttempt = attempted.remove(id) != nil
        if active == id {
            if didAttempt { cache.insert(result, for: request.key, now: ProcessInfo.processInfo.systemUptime) }
            active = nil
            worker?.cancel()
            worker = nil
        }
        request.continuation.resume(returning: result)
        startNext()
    }

    @MainActor
    private static func systemQuery(latitude: Double, longitude: Double, locale: Locale) async -> PhotoFramePlace? {
        let request = PhotoFrameSystemGeocoder()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            return await request.lookup(latitude: latitude, longitude: longitude, locale: locale)
        } onCancel: { Task { @MainActor in request.cancel() } }
    }

    func enriching(_ metadata: PhotoFrameMetadata, settings: PhotoFrameMetadataSettings,
                   allowed: @escaping @Sendable () async -> Bool,
                   timeout: Duration = .seconds(1), locale: Locale = photoFramePlaceLocale()) async -> PhotoFrameMetadata {
        func replacingPlace(_ place: PhotoFramePlace?) -> PhotoFrameMetadata {
            PhotoFrameMetadata(make: metadata.make, model: metadata.model, lensModel: metadata.lensModel,
                focalLength: metadata.focalLength, aperture: metadata.aperture, shutter: metadata.shutter,
                iso: metadata.iso, exposureCompensation: metadata.exposureCompensation, dateTime: metadata.dateTime,
                latitude: metadata.latitude, longitude: metadata.longitude, altitude: metadata.altitude,
                city: place?.city, region: place?.region)
        }
        let empty = replacingPlace(nil)
        guard !Task.isCancelled, settings.showCity || settings.showRegion,
              await allowed(), let latitude = metadata.latitude, let longitude = metadata.longitude,
              validPhotoFrameCoordinates(latitude, longitude) else { return empty }
        guard let place = await resolve(latitude: latitude, longitude: longitude, timeout: timeout, locale: locale, allowed: allowed),
              !Task.isCancelled, await allowed() else { return empty }
        return replacingPlace(place)
    }

}


/// Keep all CLGeocoder operations on one actor; only the immutable place value
/// crosses back to the resolver. The callback API avoids transferring the
/// non-Sendable geocoder into a nonisolated async API while cancellation uses it.
@MainActor
private final class PhotoFrameSystemGeocoder {
    private let coder = CLGeocoder()
    private var cancelled = false
    func lookup(latitude: Double, longitude: Double, locale: Locale) async -> PhotoFramePlace? {
        guard !cancelled, !Task.isCancelled else { return nil }
        return await withCheckedContinuation { continuation in
            coder.reverseGeocodeLocation(CLLocation(latitude: latitude, longitude: longitude), preferredLocale: locale) { marks, _ in
                let place = marks?.first.map {
                    photoFramePlace(city: $0.locality, district: $0.subLocality,
                        subAdmin: $0.subAdministrativeArea, admin: $0.administrativeArea, countryCode: $0.isoCountryCode)
                }
                continuation.resume(returning: place)
            }
        }
    }
    func cancel() { cancelled = true; coder.cancelGeocode() }
}


/// User-approved iOS equivalent of Android's validated-internet gate.
/// Default-route reachability is advisory; AP blocking takes precedence and
/// the resolver's bounded backend handles networks without internet access.
@MainActor
final class PhotoFramePlaceAvailability: ObservableObject {
    static let shared = PhotoFramePlaceAvailability()
    @Published private(set) var allowed = false
    private var pathAvailable = false
    private var apBlocked = true
    private var monitor: NWPathMonitor?
    private var generation = UUID()
    private let queue = DispatchQueue(label: "com.ztransfer.place.path")

    func start() {
        guard monitor == nil else { return }
        let token = UUID(); generation = token
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.updatePath(available)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        generation = UUID()
        monitor?.cancel(); monitor = nil
        updatePath(false)
    }

    func updateConnection(wirelessMode: WirelessMode, isUSB: Bool) {
        // Android's active USB connection overrides the remembered AP choice.
        apBlocked = !isUSB && wirelessMode == .ap
        publish()
    }

    func updatePath(_ available: Bool) {
        pathAvailable = available
        publish()
    }

    private func publish() {
        let next = !apBlocked && pathAvailable
        if allowed != next { allowed = next }
    }

    deinit { monitor?.cancel() }
}
