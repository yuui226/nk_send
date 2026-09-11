import Foundation
import Network

struct CameraBonjourService: Identifiable {
    let endpoint: NWEndpoint
    let name: String
    let alternatives: [NWEndpoint]
    // Selection binds a concrete service type; if the preferred service disappears a retry must
    // require explicit re-selection, not silently route the old row ID to its alternate endpoint.
    var id: String {
        guard case .service(_, let type, _, _) = endpoint, let group = Self.advertisedKey(endpoint) else { return String(describing: endpoint) }
        return group + "|type:" + type.lowercased()
    }
    init(endpoint: NWEndpoint, name: String, alternatives: [NWEndpoint] = []) {
        self.endpoint = endpoint; self.name = name; self.alternatives = alternatives
    }
    var selectableAlternatives: [CameraBonjourService] {
        alternatives.map { endpoint in
            let type: String
            if case .service(_, let value, _, _) = endpoint { type = value } else { type = "服务" }
            return CameraBonjourService(endpoint: endpoint, name: name + " · " + type)
        }
    }
    /// Group the same advertised instance across service types, NOT authenticated camera identity.
    /// Keep alternate endpoints: equal display names alone must never discard an observed service.
    static func coalesced(_ endpoints: [NWEndpoint]) -> [CameraBonjourService] {
        var groups: [String: Set<NWEndpoint>] = [:]
        for endpoint in endpoints {
            guard let key = advertisedKey(endpoint), case .service(_, let type, _, _) = endpoint,
                  CameraBonjourDiscovery.serviceTypes.contains(type) else { continue }
            groups[key, default: []].insert(endpoint)
        }
        return groups.keys.sorted().compactMap { key in
            let choices = (groups[key] ?? []).sorted {
                let left = preference($0), right = preference($1)
                return left == right ? String(describing: $0) < String(describing: $1) : left < right
            }
            guard let primary = choices.first, case .service(let name, _, _, _) = primary else { return nil }
            return CameraBonjourService(endpoint: primary, name: name, alternatives: Array(choices.dropFirst()))
        }
    }
    private static func preference(_ endpoint: NWEndpoint) -> Int {
        guard case .service(_, let type, _, _) = endpoint else { return 2 }
        return type == "_ptp._tcp" ? 0 : 1
    }
    private static func advertisedKey(_ endpoint: NWEndpoint) -> String? {
        guard case .service(let name, _, let domain, let interface) = endpoint else { return nil }
        let interfaceScope = interface.map { "\($0.index):\($0.name)" } ?? "any-interface"
        return [name.precomposedStringWithCanonicalMapping.lowercased(), domain.lowercased(), interfaceScope]
            .map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}

struct CameraBonjourSnapshot {
    let services: [CameraBonjourService]
    let searching: Bool
    let message: String?
}

enum CameraBonjourBrowserState { case ready, issue(String) }
protocol CameraBonjourBrowser: AnyObject {
    var onResults: (([NWEndpoint]) -> Void)? { get set }
    var onState: ((CameraBonjourBrowserState) -> Void)? { get set }
    func start(on queue: DispatchQueue)
    func cancel()
}

private final class AppleCameraBonjourBrowser: CameraBonjourBrowser {
    var onResults: (([NWEndpoint]) -> Void)?
    var onState: ((CameraBonjourBrowserState) -> Void)?
    private let browser: NWBrowser
    init(type: String) {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wifi
        browser = NWBrowser(for: .bonjour(type: type, domain: "local."), using: parameters)
    }
    func start(on queue: DispatchQueue) {
        browser.browseResultsChangedHandler = { [weak self] results, _ in self?.onResults?(results.map(\.endpoint)) }
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onState?(.ready)
            case .waiting(let error), .failed(let error): self?.onState?(.issue(TransferFailureMessage.describe(error)))
            default: break
            }
        }
        browser.start(queue: queue)
    }
    func cancel() {
        browser.browseResultsChangedHandler = nil; browser.stateUpdateHandler = nil
        onResults = nil; onState = nil; browser.cancel()
    }
}

/// Only the two specific Nikon/PTP service types used by Android. Discovery is a candidate signal,
/// NOT camera authentication. The chosen service must pass the existing responder/session checks.
/// Both command/event sockets use the same resolved service endpoint and Wi-Fi routing constraint.
final class CameraBonjourDiscovery: @unchecked Sendable {
    static let serviceTypes = ["_ptp._tcp", "_nikon._tcp"]
    let updates: AsyncStream<CameraBonjourSnapshot>
    private let continuation: AsyncStream<CameraBonjourSnapshot>.Continuation
    private let queue = DispatchQueue(label: "com.ztransfer.camera.bonjour")
    private let browserFactory: (String) -> CameraBonjourBrowser
    private var browsers: [String: CameraBonjourBrowser] = [:]
    private var results: [String: [NWEndpoint]] = [:]
    private var issues: [String: String] = [:]
    private var generation = UUID()
    private var deadline: DispatchWorkItem?

    init(browserFactory: @escaping (String) -> CameraBonjourBrowser = { AppleCameraBonjourBrowser(type: $0) }) {
        self.browserFactory = browserFactory
        var output: AsyncStream<CameraBonjourSnapshot>.Continuation!
        updates = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { output = $0 }
        continuation = output
    }
    deinit {
        deadline?.cancel()
        browsers.values.forEach { $0.cancel() }
        continuation.finish()
    }

    func start(timeout: TimeInterval = 8) {
        guard timeout.isFinite, timeout > 0, timeout <= 60 else { return }
        queue.async {
            self.cancelBrowsers()
            self.results.removeAll(); self.issues.removeAll()
            let id = UUID(); self.generation = id
            for type in Self.serviceTypes {
                let browser = self.browserFactory(type)
                self.browsers[type] = browser
                browser.onResults = { [weak self] results in
                    self?.queue.async { [weak self] in
                        guard let self, self.generation == id else { return }
                        self.results[type] = results
                        self.publish()
                    }
                }
                browser.onState = { [weak self] state in
                    self?.queue.async { [weak self] in
                        guard let self, self.generation == id else { return }
                        switch state {
                        case .ready: self.issues[type] = nil
                        case .issue(let message): self.issues[type] = message
                        }
                        self.publish()
                    }
                }
                browser.start(queue: self.queue)
            }
            let deadline = DispatchWorkItem { [weak self] in
                guard let self, self.generation == id else { return }
                self.cancelBrowsers()
                self.publish()
            }
            self.deadline = deadline
            self.queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
            self.publish()
        }
    }

    func stop() {
        queue.async { self.cancelBrowsers(); self.publish() }
    }

    private func cancelBrowsers() {
        generation = UUID() // Reject callbacks queued before stop/restart.
        deadline?.cancel(); deadline = nil
        browsers.values.forEach {
            $0.onResults = nil; $0.onState = nil; $0.cancel()
        }
        browsers.removeAll()
    }

    private func publish() {
        let candidates = CameraBonjourService.coalesced(results.values.flatMap { $0 })
        let message: String?
        if !issues.isEmpty { message = issues.keys.sorted().compactMap { issues[$0] }.joined(separator: "；") }
        else if browsers.isEmpty && candidates.isEmpty {
            message = "@ztr|no_services"
        } else { message = nil }
        continuation.yield(CameraBonjourSnapshot(services: candidates, searching: !browsers.isEmpty, message: message))
    }
}
