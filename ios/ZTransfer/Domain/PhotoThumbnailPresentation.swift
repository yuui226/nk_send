import Foundation
import Combine

/// Android BurstCollectionCell draws back-to-front; this index follows the
/// catalog (front-to-back). Offsets stay in points, not fractions of cell size.
struct PhotoThumbnailStackCard: Equatable {
    let rotation: Double
    let x: Double
    let y: Double
    init(frontIndex: Int, visibleCount: Int) {
        let count = min(3, max(1, visibleCount))
        let backIndex = count - 1 - frontIndex
        rotation = count == 1 ? 0 : count == 2 ? (frontIndex == 0 ? 3 : -5)
            : frontIndex == 0 ? 0 : frontIndex == 1 ? 5 : -6
        x = frontIndex == 0 ? 0 : backIndex.isMultiple(of: 2) ? -4 : 4
        y = frontIndex == 0 ? 1 : 2
    }
}

struct PhotoThumbnailStackSnapshot: Identifiable, Equatable {
    let files: [CameraFile]
    let id: [PublishedPhotoIdentity]
    init(_ files: [CameraFile]) {
        self.files = Array(files.prefix(3))
        id = self.files.map(PublishedPhotoIdentity.init)
    }
}

/// Only the rendered three identities are AnimatedContent keys on Android.
/// Tail/count changes update the live collection without making two identical
/// image stacks. Reversals retain the displayed alpha and animation velocity.
struct PhotoThumbnailStackMotion {
    private(set) var snapshots: [PhotoThumbnailStackSnapshot]
    private(set) var target: [PublishedPhotoIdentity]
    private var opacities: [[PublishedPhotoIdentity]: ZTransferScalarAnimation]
    var isRunning: Bool { opacities.values.contains { $0.isRunning } }

    init(_ files: [CameraFile]) {
        let snapshot = PhotoThumbnailStackSnapshot(files)
        snapshots = [snapshot]; target = snapshot.id
        opacities = [snapshot.id: .init(value: 1)]
    }
    func opacity(_ key: [PublishedPhotoIdentity]) -> Float { opacities[key]?.value ?? 0 }
    mutating func update(_ files: [CameraFile]) {
        let next = PhotoThumbnailStackSnapshot(files)
        if let index = snapshots.firstIndex(where: { $0.id == next.id }) { snapshots[index] = next }
        else { snapshots.append(next); opacities[next.id] = .init(value: 0) }
        guard next.id != target else { return }
        target = next.id
        for snapshot in snapshots {
            let key = snapshot.id
            let spec: ZTransferAndroidMotion = opacities[key]?.isRunning == true
                ? .criticallyDampedSpring(stiffness: 1500)
                : .tween(milliseconds: key == target ? 180 : 160)
            opacities[key]?.retarget(key == target ? 1 : 0, using: spec)
        }
    }
    mutating func advance(_ nanos: Int64) {
        for snapshot in snapshots { opacities[snapshot.id]?.advance(frameNanos: nanos) }
        if !isRunning {
            snapshots.removeAll { $0.id != target }
            opacities = [target: .init(value: 1)]
        }
    }
}

/// Android rememberThumbnailImagePresentation: subscribe before the initial
/// read; later handle-specific notifications read local cache only. Loading
/// can be cancelled independently of a ready image and its visual fade.
@MainActor
final class PhotoThumbnailLoader<Image: Sendable>: ObservableObject {
    @Published private(set) var image: Image?
    @Published private(set) var fadeComplete: Bool
    let cachedAtMount: Bool
    private var generation: UInt64 = 0

    init(cached: Image?) {
        image = cached
        cachedAtMount = cached != nil
        fadeComplete = cached != nil
    }

    func finishFade() {
        if image != nil, !fadeComplete { fadeComplete = true }
    }

    /// `updates` includes its initial event, as CameraSession.thumbnailUpdates
    /// does. Registering the stream first closes the cache/read notification race.
    func load(enabled: Bool, allowRemote: Bool,
              updates: @Sendable () async -> AsyncStream<Void>,
              read: @Sendable (Bool) async throws -> Image?) async {
        generation &+= 1
        let owner = generation
        guard enabled, image == nil, !Task.isCancelled else { return }
        let stream = await updates()
        var initial = true
        for await _ in stream {
            guard !Task.isCancelled, generation == owner, image == nil else { return }
            let remote = initial && allowRemote
            initial = false
            let loaded = try? await read(remote)
            guard !Task.isCancelled, generation == owner else { return }
            if let loaded { image = loaded; return }
        }
    }
}

/// Shared by the first nonempty grid entrance and newly decoded images.
/// Compose waits for the image's first display frame, then runs tween(180)
/// with its default FastOutSlowIn curve. Empty batches pause, never rewind.
struct PhotoThumbnailFade {
    private var motion: ZTransferScalarAnimation
    private var ready = false
    var opacity: Float { motion.value }
    var isRunning: Bool { motion.isRunning }

    init(initiallyVisible: Bool = false) {
        motion = .init(value: initiallyVisible ? 1 : 0)
    }
    mutating func update(ready: Bool) {
        guard self.ready != ready else { return }
        self.ready = ready
        if ready {
            if motion.value < 1 { motion.retarget(1, using: .tween(milliseconds: 180)) }
        } else { motion.reset(to: motion.value) }
    }
    mutating func advance(_ frameNanos: Int64) { motion.advance(frameNanos: frameNanos) }
}
