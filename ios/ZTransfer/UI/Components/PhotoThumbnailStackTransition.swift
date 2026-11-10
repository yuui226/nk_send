import SwiftUI
import UIKit

/// Content changes publish only at an identity/payload boundary. Per-frame
/// alpha belongs to the tiny opacity modifiers, not catalog/stack composition.
@MainActor
final class PhotoThumbnailStackClock: ObservableObject {
    @Published private(set) var snapshots: [PhotoThumbnailStackSnapshot]
    private var motion: PhotoThumbnailStackMotion
    private var opacities: [[PublishedPhotoIdentity]: AndroidAnimatedOpacity] = [:]
    private var link: CADisplayLink?

    init(_ files: [CameraFile]) {
        motion = .init(files); snapshots = motion.snapshots
        publish()
    }
    func opacity(_ key: [PublishedPhotoIdentity]) -> AndroidAnimatedOpacity {
        if let value = opacities[key] { return value }
        let value = AndroidAnimatedOpacity(); value.update(motion.opacity(key))
        opacities[key] = value
        return value
    }
    func update(_ files: [CameraFile]) {
        motion.update(files); publish()
        guard motion.isRunning, link == nil else { return }
        let next = ZTransferDisplayLink.make(owner: self) { owner, frame in
            owner.advance(Int64(frame.timestamp * 1_000_000_000))
        }
        link = next; next.add(to: .main, forMode: .common)
    }
    func reset(_ files: [CameraFile]) {
        stop(); motion = .init(files); publish()
    }
    private func advance(_ nanos: Int64) {
        motion.advance(nanos); publish()
        if !motion.isRunning { stop() }
    }
    private func publish() {
        if snapshots != motion.snapshots {
            snapshots = motion.snapshots
            let retained = Set(snapshots.map(\.id))
            opacities = opacities.filter { retained.contains($0.key) }
        }
        for snapshot in snapshots { opacity(snapshot.id).update(motion.opacity(snapshot.id)) }
    }
    private func stop() { link?.invalidate(); link = nil }
}

struct PhotoThumbnailStackTransition<Content: View>: View {
    let files: [CameraFile]
    @ViewBuilder let content: ([CameraFile]) -> Content
    @StateObject private var clock: PhotoThumbnailStackClock

    init(files: [CameraFile], @ViewBuilder content: @escaping ([CameraFile]) -> Content) {
        self.files = files; self.content = content
        _clock = StateObject(wrappedValue: PhotoThumbnailStackClock(files))
    }
    var body: some View {
        ZStack {
            ForEach(clock.snapshots) { snapshot in
                content(snapshot.files)
                    .modifier(AndroidOpacity(opacity: clock.opacity(snapshot.id)))
                    .allowsHitTesting(false)
            }
        }
        .onAppear { clock.update(files) }
        .onChange(of: files) { clock.update($0) }
        .onDisappear { clock.reset(files) }
    }
}
