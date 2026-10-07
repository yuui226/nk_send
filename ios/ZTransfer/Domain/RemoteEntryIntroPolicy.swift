import Foundation
import Combine

/// Android 617082c3 TransferViewModel + FileListScreen: independent V2 campaign.
/// Older reminder counts deliberately do not migrate into these preferences.
enum RemoteEntryIntroPolicy {
    static let playCountKey = "remote_entry_intro_v2_play_count"
    static let usedKey = "remote_entry_intro_v2_used"
    static let delayNanoseconds: UInt64 = 800_000_000
    static let holdNanoseconds: UInt64 = 4_000_000_000

    static func recordedPlayCount(_ count: Int, entryUsed: Bool) -> Int {
        guard isRemoteEntryIntroEligible(playCount: count, entryUsed: entryUsed) else { return count }
        return max(0, count) + 1
    }
}

let remoteEntryIntroMaxPlays = 20

func isRemoteEntryIntroEligible(playCount: Int, entryUsed: Bool = false) -> Bool {
    !entryUsed && max(0, playCount) < remoteEntryIntroMaxPlays
}

/// Owns one list entry's reminder. Preference state survives reconstruction;
/// expansion does not. Cancellation while away must never leave it stuck open.
@MainActor
final class RemoteEntryIntroController: ObservableObject {
    @Published private(set) var expanded = false
    private(set) var handledForEntry = false
    private let preferences: UserDefaults

    init(preferences: UserDefaults = .standard) { self.preferences = preferences }

    private var eligible: Bool {
        isRemoteEntryIntroEligible(
            playCount: preferences.integer(forKey: RemoteEntryIntroPolicy.playCountKey),
            entryUsed: preferences.bool(forKey: RemoteEntryIntroPolicy.usedKey))
    }

    func run(onStarted: (() -> Void)? = nil, sleep: @MainActor (UInt64) async throws -> Void = {
        try await Task.sleep(nanoseconds: $0)
    }) async {
        guard !handledForEntry, eligible else { return }
        do {
            try await sleep(RemoteEntryIntroPolicy.delayNanoseconds)
            try Task.checkCancellation()
            guard !handledForEntry, eligible else { return }
            handledForEntry = true
            preferences.set(RemoteEntryIntroPolicy.recordedPlayCount(
                preferences.integer(forKey: RemoteEntryIntroPolicy.playCountKey), entryUsed: false),
                forKey: RemoteEntryIntroPolicy.playCountKey)
            expanded = true
            onStarted?()
            defer { expanded = false }
            try await sleep(RemoteEntryIntroPolicy.holdNanoseconds)
        } catch {
            // SwiftUI cancels this task on disappearance; no repeat or error UI.
        }
    }

    func markUsed() {
        preferences.set(true, forKey: RemoteEntryIntroPolicy.usedKey)
        expanded = false
    }

    func collapse() { expanded = false }
}
