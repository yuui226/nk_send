import Foundation

protocol PictureControlSlotAccess: Sendable {
    var cameraIdentity: String { get }
    var slot: Int { get }
    func checkSession() async throws
    func readSlot() async throws -> Data?
    func matchesSlot(expected: Data?, actual: Data?) throws -> Bool
    func writeSlot(_ data: Data) async throws
    func clearSlot() async throws
    func readSelection() async throws -> Int
    func select(_ value: Int) async throws
}
extension PictureControlSlotAccess {
    func matchesSlot(expected: Data?, actual: Data?) throws -> Bool { expected == actual }
}

enum PictureControlWriteStage: String, Sendable { case backup = "BACKUP", write = "WRITE", verify = "VERIFY", activate = "ACTIVATE" }
struct PictureControlReplacementError: Error, LocalizedError {
    let stage: PictureControlWriteStage
    let originalRestored: Bool
    let cause: any Error
    var errorDescription: String? {
        "Picture Control operation failed at \(stage.rawValue) (restored=\(originalRestored))"
    }
}

/// Android PictureControlReplacement. Admission is cancellable; after mutation
/// starts an independent task owns read-back, activation and any rollback.
struct PictureControlReplacement: Sendable {
    private static let gate = CancellableSerialWorkGate()
    let backup: PictureControlBackupStore

    private func snapshot(_ access: any PictureControlSlotAccess) async throws -> PictureControlSlotSnapshot {
        try require(NikonPictureControlData.customSlots.contains(access.slot), "Only C1–C9 may be changed")
        try await access.checkSession()
        let data = try await access.readSlot()
        let selection = try await access.readSelection()
        try require(data != nil || selection != access.slot, "An empty custom slot is selected")
        return try PictureControlSlotSnapshot(cameraIdentity: access.cameraIdentity, slot: access.slot, data: data, selection: selection)
    }

    func apply(_ access: any PictureControlSlotAccess, dataset: Data) async throws {
        try await Self.gate.withPermit {
            try require((1...NikonPictureControlFile.maximumBytes).contains(dataset.count), "Invalid Picture Control replacement size")
            let previous = try await snapshot(access)
            _ = try backup.saveOriginal(previous)
            try Task.checkCancellation()
            try await access.checkSession()
            try await Task {
                var stage = PictureControlWriteStage.write
                do {
                    if try !access.matchesSlot(expected: dataset, actual: previous.data) { try await access.writeSlot(dataset) }
                    stage = .verify
                    let actual = try await access.readSlot()
                    try require(try access.matchesSlot(expected: dataset, actual: actual), "Picture Control read-back mismatch")
                    stage = .activate
                    try await selectVerified(access, selection: access.slot)
                } catch {
                    let restored = await restoreSnapshot(access, previous, selection: previous.selection!)
                    throw PictureControlReplacementError(stage: stage, originalRestored: restored, cause: error)
                }
            }.value
        }
    }

    func activate(_ access: any PictureControlSlotAccess) async throws {
        try await Self.gate.withPermit {
            let previous = try await snapshot(access)
            try require(previous.data != nil, "An empty custom slot cannot be activated")
            if previous.selection == access.slot { return }
            try Task.checkCancellation()
            try await access.checkSession()
            try await Task {
                do { try await selectVerified(access, selection: access.slot) }
                catch {
                    var restored = false
                    do { try await selectVerified(access, selection: previous.selection!); restored = true } catch { }
                    throw PictureControlReplacementError(stage: .activate, originalRestored: restored, cause: error)
                }
            }.value
        }
    }

    func clear(_ access: any PictureControlSlotAccess) async throws {
        try await Self.gate.withPermit {
            let previous = try await snapshot(access)
            guard previous.data != nil else { return }
            _ = try backup.saveOriginal(previous)
            try Task.checkCancellation()
            try await access.checkSession()
            try await Task {
                do {
                    let selection = selectionAfterRestore(slot: access.slot, data: nil, current: previous.selection!)
                    if previous.selection != selection { try await selectVerified(access, selection: selection) }
                    try await access.clearSlot()
                    let actual = try await access.readSlot()
                    try require(try access.matchesSlot(expected: nil, actual: actual), "Custom slot was not cleared")
                    try require(try await access.readSelection() == selection, "Clearing changed the active Picture Control")
                } catch {
                    let restored = await restoreSnapshot(access, previous, selection: previous.selection!)
                    throw PictureControlReplacementError(stage: .verify, originalRestored: restored, cause: error)
                }
            }.value
        }
    }

    func restoreOriginal(_ access: any PictureControlSlotAccess) async throws {
        try await Self.gate.withPermit {
            try require(NikonPictureControlData.customSlots.contains(access.slot), "Only C1–C9 may be restored")
            try await access.checkSession()
            guard let original = try backup.load(identity: access.cameraIdentity, slot: access.slot) else {
                throw NikonPictureControlError.invalid("No original slot backup")
            }
            let currentSelection = try await access.readSelection()
            let previous: PictureControlSlotSnapshot?
            do {
                previous = try await PictureControlSlotSnapshot(cameraIdentity: access.cameraIdentity, slot: access.slot,
                                                                data: access.readSlot(), selection: currentSelection)
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                try await access.checkSession()
                previous = nil
            }
            try Task.checkCancellation()
            try await access.checkSession()
            try await Task {
                let selection = selectionAfterRestore(slot: access.slot, data: original.data, current: currentSelection)
                if !(await restoreSnapshot(access, original, selection: selection)) {
                    let restored = if let previous { await restoreSnapshot(access, previous, selection: currentSelection) } else { false }
                    throw PictureControlReplacementError(stage: .verify, originalRestored: restored,
                        cause: NikonPictureControlError.invalid("Original slot restoration was not confirmed"))
                }
            }.value
        }
    }

    private func selectionAfterRestore(slot: Int, data: Data?, current: Int) -> Int {
        data == nil && current == slot ? 1 : current
    }
    private func selectVerified(_ access: any PictureControlSlotAccess, selection: Int) async throws {
        try await access.checkSession()
        try await access.select(selection)
        try require(try await access.readSelection() == selection, "Picture Control activation was not confirmed")
    }
    private func restoreSnapshot(_ access: any PictureControlSlotAccess, _ snapshot: PictureControlSlotSnapshot,
                                 selection: Int) async -> Bool {
        do {
            try await access.checkSession()
            let original = snapshot.data
            try require(original != nil || selection != access.slot, "Cannot activate an empty restored slot")
            let alreadyRestored = (try? await access.matchesSlot(expected: original, actual: access.readSlot())) ?? false
            if !alreadyRestored {
                try await access.checkSession()
                if let original { try await access.writeSlot(original) }
                else {
                    if try await access.readSelection() == access.slot { try await selectVerified(access, selection: selection) }
                    try await access.clearSlot()
                }
            }
            let actual = try await access.readSlot()
            try require(try access.matchesSlot(expected: original, actual: actual), "Slot rollback read-back mismatch")
            try await selectVerified(access, selection: selection)
            return true
        } catch { return false }
    }
    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NikonPictureControlError.invalid(message) }
    }
}
