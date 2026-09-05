import Foundation
import Network

struct CameraBonjourService: Identifiable {
    let endpoint: NWEndpoint
    let name: String
    var id: String { String(describing: endpoint) }
}

struct CameraBonjourSnapshot {
    let services: [CameraBonjourService]
    let searching: Bool
    let message: String?
}

/// Only the two specific Nikon/PTP service types used by Android. Discovery is a candidate signal,
/// NOT camera authentication. The chosen service must pass the existing responder/session checks.
/// Both command/event sockets use the same resolved service endpoint and Wi-Fi routing constraint.
final class CameraBonjourDiscovery: @unchecked Sendable {
    static let serviceTypes = ["_ptp._tcp", "_nikon._tcp"]
    let updates: AsyncStream<CameraBonjourSnapshot>
    private let continuation: AsyncStream<CameraBonjourSnapshot>.Continuation
    private let queue = DispatchQueue(label: "com.ztransfer.camera.bonjour")
    private var browsers: [String: NWBrowser] = [:]
    private var results: [String: Set<NWBrowser.Result>] = [:]
    private var issues: [String: String] = [:]
    private var generation = UUID()
    private var deadline: DispatchWorkItem?

    init() {
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
                let parameters = NWParameters.tcp
                parameters.requiredInterfaceType = .wifi
                let browser = NWBrowser(for: .bonjour(type: type, domain: "local."), using: parameters)
                self.browsers[type] = browser
                browser.browseResultsChangedHandler = { [weak self] results, _ in
                    guard let self, self.generation == id else { return }
                    self.results[type] = results
                    self.publish()
                }
                browser.stateUpdateHandler = { [weak self] state in
                    guard let self, self.generation == id else { return }
                    switch state {
                    case .ready: self.issues[type] = nil
                    case .waiting(let error), .failed(let error): self.issues[type] = error.localizedDescription
                    default: break
                    }
                    self.publish()
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
            $0.browseResultsChangedHandler = nil; $0.stateUpdateHandler = nil; $0.cancel()
        }
        browsers.removeAll()
    }

    private func publish() {
        var seen = Set<NWEndpoint>()
        var candidates: [CameraBonjourService] = []
        for result in results.values.flatMap({ $0 }) {
            guard case .service(let name, _, _, _) = result.endpoint,
                  seen.insert(result.endpoint).inserted else { continue }
            candidates.append(CameraBonjourService(endpoint: result.endpoint, name: name))
        }
        candidates.sort { $0.id < $1.id }
        let message: String?
        if !issues.isEmpty { message = issues.keys.sorted().compactMap { issues[$0] }.joined(separator: "；") }
        else if browsers.isEmpty && candidates.isEmpty {
            message = "未发现 Bonjour 相机服务。可能未广播、Wi-Fi 不同或权限未允许；仍可输入 IP，不能据此判定拒绝授权。"
        } else { message = nil }
        continuation.yield(CameraBonjourSnapshot(services: candidates, searching: !browsers.isEmpty, message: message))
    }
}
