import Combine
import SwiftUI

/// Only the active row subscribes to progress; inactive rows and the page
/// depend solely on structural snapshots. Toggle the subscription, not the
/// content's structural identity. Replacing
/// an active/inactive branch destroyed the card's in-flight appearance, color
/// and progress animations when the same task changed status.
struct QueueProgressScope<Content: View>: View {
    let model: TransferQueueProgressViewModel
    let active: Bool
    @ViewBuilder let content: (TransferActiveProgress?) -> Content
    @StateObject private var observation = QueueProgressSubscription()

    var body: some View {
        content(active ? model.activeProgress : nil)
            .onAppear { observation.observe(model, active: active) }
            .onChange(of: active) { observation.observe(model, active: $0) }
            .onChange(of: ObjectIdentifier(model)) { _ in observation.observe(model, active: active) }
            .onDisappear { observation.stop() }
    }
}

@MainActor
private final class QueueProgressSubscription: @preconcurrency ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private weak var model: TransferQueueProgressViewModel?
    private var subscription: AnyCancellable?

    func observe(_ model: TransferQueueProgressViewModel, active: Bool) {
        guard active else { stop(); return }
        guard self.model !== model || subscription == nil else { return }
        stop()
        self.model = model
        subscription = model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func stop() { subscription = nil; model = nil }
}
