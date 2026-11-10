import CoreLocation
import Foundation
import Combine
import Network

/// Backend outcomes stay distinct: only a real empty/error response backs off.
/// Timeout, cancellation and unavailable connectivity never poison later exports.
enum PhotoPlaceLookupResult: Equatable, Sendable {
    case found(PhotoFramePlace), empty, error, unavailable
    init(_ place: PhotoFramePlace?) {
        if let place, place.city != nil || place.region != nil { self = .found(place) }
        else { self = .empty }
    }
    var place: PhotoFramePlace? { if case .found(let place) = self { return place }; return nil }
    var cacheLifetime: TimeInterval? {
        switch self { case .found: 86_400; case .empty: 15; case .error: 5; case .unavailable: nil }
    }
}

/// Android PhotoPlaceLookupCache: 32-entry access-order cache, success 24h,
/// explicit empty 15s, backend error 5s, no unavailable/timeout/cancel entries.
struct PhotoFramePlaceCache {
    struct Entry {
        let result: PhotoPlaceLookupResult
        let time: TimeInterval
        var place: PhotoFramePlace? { result.place }
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
        let age = now - entry.time
        guard let lifetime = entry.result.cacheLifetime, age >= 0, age < lifetime else {
            entries[key] = nil; order.removeAll { $0 == key }; return nil
        }
        touch(key)
        return entry
    }

    mutating func insert(_ result: PhotoPlaceLookupResult, for key: String, now: TimeInterval) {
        guard result.cacheLifetime != nil else { return }
        entries[key] = Entry(result: result, time: now)
        touch(key)
        if order.count > 32 { entries.removeValue(forKey: order.removeFirst()) }
    }
    private mutating func touch(_ key: String) {
        order.removeAll { $0 == key }; order.append(key)
    }
}

actor PhotoFramePlaceResolver {
    static let shared = PhotoFramePlaceResolver()
    static let requestTimeout: Duration = .seconds(3)
    typealias Query = @Sendable (Double, Double, Locale) async throws -> PhotoPlaceLookupResult
    private struct Request {
        let key: String
        let latitude: Double
        let longitude: Double
        let locale: Locale
        let allowed: @Sendable () async -> Bool
        let budget: Duration
        let continuation: CheckedContinuation<PhotoFramePlace?, Never>
    }
    private var cache = PhotoFramePlaceCache()
    private let query: Query
    private var requests: [UUID: Request] = [:]
    private var waiting: [UUID] = []
    private var active: UUID?
    private var deadline: ContinuousClock.Instant?
    private var timer: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    var pendingCount: Int { requests.count }

    init(query: @escaping Query = PhotoFramePlaceResolver.systemQuery) { self.query = query }

    func resolve(latitude: Double, longitude: Double, timeout: Duration = PhotoFramePlaceResolver.requestTimeout, locale: Locale = photoFramePlaceLocale(),
                 allowed: @escaping @Sendable () async -> Bool = { true }) async -> PhotoFramePlace? {
        guard !Task.isCancelled, validPhotoFrameCoordinates(latitude, longitude) else { return nil }
        let key = PhotoFramePlaceCache.key(latitude: latitude, longitude: longitude, locale: locale)
        if let cached = cache.entry(for: key, now: ProcessInfo.processInfo.systemUptime) { return cached.place }
        let budget = min(max(timeout, .zero), Self.requestTimeout)
        guard budget > .zero else { return nil }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                requests[id] = Request(key: key, latitude: latitude, longitude: longitude,
                    locale: locale, allowed: allowed, budget: budget, continuation: continuation)
                waiting.append(id)
                startNext()
            }
        } onCancel: { Task { await self.finish(id, result: nil) } }
    }

    private func startNext() {
        guard active == nil else { return }
        while !waiting.isEmpty {
            let id = waiting.removeFirst()
            guard let request = requests[id] else { continue }
            // Waiting behind another request consumes no backend timeout budget.
            // A completed same-coordinate request may now satisfy this waiter.
            if let cached = cache.entry(for: request.key, now: ProcessInfo.processInfo.systemUptime) {
                requests[id] = nil
                request.continuation.resume(returning: cached.place)
                continue
            }
            active = id
            let deadline = ContinuousClock.now.advanced(by: request.budget)
            self.deadline = deadline
            timer = Task { [weak self] in
                do { try await Task.sleep(until: deadline, clock: .continuous) }
                catch { return }
                await self?.finish(id, result: nil)
            }
            let query = self.query
            worker = Task { [weak self] in
                guard !Task.isCancelled, await request.allowed(), !Task.isCancelled else {
                    await self?.finish(id, result: nil); return
                }
                do {
                    let result = try await query(request.latitude, request.longitude, request.locale)
                    await self?.finish(id, result: Task.isCancelled ? nil : result)
                } catch is CancellationError { await self?.finish(id, result: nil) }
                catch { await self?.finish(id, result: Task.isCancelled ? nil : .error) }
            }
            return
        }
    }

    /// IDs isolate late callbacks. The serial owner releases on cancellation;
    /// the system adapter actively resumes its continuation when cancelled too.
    private func finish(_ id: UUID, result: PhotoPlaceLookupResult?) {
        guard let request = requests.removeValue(forKey: id) else { return }
        waiting.removeAll { $0 == id }
        var completed = result
        if active == id {
            if let deadline, ContinuousClock.now >= deadline { completed = nil }
            if case .found(let place)? = completed { completed = PhotoPlaceLookupResult(place) }
            if let completed { cache.insert(completed, for: request.key, now: ProcessInfo.processInfo.systemUptime) }
            active = nil; deadline = nil
            timer?.cancel(); timer = nil
            worker?.cancel(); worker = nil
        }
        request.continuation.resume(returning: completed?.place)
        startNext()
    }

    @MainActor
    private static func systemQuery(latitude: Double, longitude: Double, locale: Locale) async -> PhotoPlaceLookupResult {
        let request = PhotoFrameSystemGeocoder()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return .unavailable }
            return await request.lookup(latitude: latitude, longitude: longitude, locale: locale)
        } onCancel: { Task { @MainActor in request.cancel() } }
    }

    func enriching(_ metadata: PhotoFrameMetadata, settings: PhotoFrameMetadataSettings,
                   allowed: @escaping @Sendable () async -> Bool,
                   timeout: Duration = PhotoFramePlaceResolver.requestTimeout, locale: Locale = photoFramePlaceLocale()) async -> PhotoFrameMetadata {
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
    private var continuation: CheckedContinuation<PhotoPlaceLookupResult, Never>?
    func lookup(latitude: Double, longitude: Double, locale: Locale) async -> PhotoPlaceLookupResult {
        guard !cancelled, !Task.isCancelled else { return .unavailable }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            coder.reverseGeocodeLocation(CLLocation(latitude: latitude, longitude: longitude), preferredLocale: locale) { [weak self] marks, error in
                let result: PhotoPlaceLookupResult
                if let error {
                    let error = error as NSError
                    if error.domain == kCLErrorDomain && error.code == CLError.Code.geocodeFoundNoResult.rawValue { result = .empty }
                    else if error.domain == kCLErrorDomain && error.code == CLError.Code.geocodeCanceled.rawValue { result = .unavailable }
                    else { result = .error }
                } else {
                    let place = marks?.first.map {
                        photoFramePlace(city: $0.locality, district: $0.subLocality,
                            subAdmin: $0.subAdministrativeArea, admin: $0.administrativeArea, countryCode: $0.isoCountryCode)
                    }
                    result = PhotoPlaceLookupResult(place)
                }
                Task { @MainActor [weak self] in self?.finish(result) }
            }
        }
    }
    private func finish(_ result: PhotoPlaceLookupResult) {
        let pending = continuation; continuation = nil
        pending?.resume(returning: result)
    }
    func cancel() {
        cancelled = true
        finish(.unavailable)
        coder.cancelGeocode()
    }
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
