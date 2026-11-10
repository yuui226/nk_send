import Foundation

// Android TransferQueuePresentation.kt / GenerationQueueRows.kt (18145b3a).
// Structural snapshots only: these functions never observe a byte/animation clock.
enum QueueActivityState: Equatable { case idle, waiting, running, paused }

struct TransferQueuePresentation: Equatable {
    var downloadTask: TransferQueueItem?
    var downloadState: QueueActivityState = .idle
    var downloadRemaining = 0
    var generationTasks: [TransferQueueItem] = []
    var generationState: QueueActivityState = .idle
    var generationRemaining = 0

    init(items: [TransferQueueItem] = [], isTransferring: Bool = false,
         excludedIDs: Set<UUID> = [], pauseAfterCurrent: Bool = false) {
        var running: [TransferQueueItem] = [], waiting: [(Int, TransferQueueItem)] = []
        for (index, item) in items.enumerated() {
            if excludedIDs.contains(item.id), item.status != .transferring, !item.isGeneratingFrame { continue }
            if item.isGeneratingFrame {
                guard item.isQueuedForFrameGeneration else { continue }
                generationRemaining += 1
                if item.frameGenerationStartedAtElapsedMs != nil { running.append(item) }
                else { waiting.append((index, item)) }
            } else if item.status == .transferring {
                downloadRemaining += 1
                if downloadTask == nil { downloadTask = item }
            } else if item.status == .waiting { downloadRemaining += 1 }
        }
        // A stable fallback supports restored/debug fixtures without inventing
        // a chronological meaning for UUIDs. All live attempts have an ordinal.
        waiting.sort { $0.1.attemptOrder == $1.1.attemptOrder ? $0.0 < $1.0 : $0.1.attemptOrder < $1.1.attemptOrder }
        generationTasks = running + waiting.map(\.1)
        generationState = !running.isEmpty ? .running : (!waiting.isEmpty ? .waiting : .idle)
        downloadState = downloadTask != nil ? .running : (downloadRemaining == 0 ? .idle :
            (!isTransferring || pauseAfterCurrent ? .paused : .waiting))
    }
}

enum GenerationRowPhase: Equatable {
    case active, succeeded, exiting, exitingSuccess
    var completed: Bool { self == .succeeded || self == .exitingSuccess }
    var retiring: Bool { self == .exiting || self == .exitingSuccess }
    var frozen: Bool { self != .active }
}

struct GenerationRowSnapshot: Equatable, Identifiable {
    var task: TransferQueueItem
    var position: Int
    var phase: GenerationRowPhase = .active
    var id: UUID { task.id }
}

func generationReallyCompleted(_ task: TransferQueueItem?) -> Bool {
    guard let task else { return false }
    return task.status == .completed && !task.isGeneratingFrame && task.frameGenerationElapsedMs != nil &&
        !task.frameGenerationSkipped && task.frameError == nil && task.error == nil
}

/// At most three resident rows and two departures, irrespective of queue length.
func generationRowSnapshots(previous: [GenerationRowSnapshot], tasks: [TransferQueueItem],
                            allTasks: [TransferQueueItem]) -> [GenerationRowSnapshot] {
    let previousIDs = Set(previous.map(\.id))
    var currentPrevious: Set<UUID> = [], head: [TransferQueueItem] = []
    for task in tasks where task.isQueuedForFrameGeneration {
        if previousIDs.contains(task.id) { currentPrevious.insert(task.id) }
        if head.count < 3, !head.contains(where: { $0.id == task.id }) { head.append(task) }
    }
    var final: [UUID: TransferQueueItem] = [:]
    if !previousIDs.isEmpty {
        for task in allTasks {
            if previousIDs.contains(task.id) { final[task.id] = task }
            if final.count == previousIDs.count { break }
        }
    }
    func finalTask(_ row: GenerationRowSnapshot) -> TransferQueueItem {
        final[row.id]?.frameGenerationElapsedMs != nil ? final[row.id]! : row.task
    }
    let holds = previous.compactMap { row -> GenerationRowSnapshot? in
        guard !row.phase.retiring, !currentPrevious.contains(row.id), row.position < 2 else { return nil }
        if row.phase == .succeeded { return final[row.id] == nil || generationReallyCompleted(final[row.id]) ? row : nil }
        return generationReallyCompleted(final[row.id]) ? .init(task: finalTask(row), position: row.position, phase: .succeeded) : nil
    }.sorted { $0.position < $1.position }.prefix(2)
    let holdIDs = Set(holds.map(\.id))
    var current = head.filter { !holdIDs.contains($0.id) }.prefix(3 - holds.count).map {
        GenerationRowSnapshot(task: $0, position: 0)
    }
    let residentIDs = Set(current.map(\.id)).union(holdIDs)
    let occupied = Set(previous.filter { !$0.phase.retiring && residentIDs.contains($0.id) }.map(\.position))
    for hold in holds {
        let insertion = (0..<hold.position).filter { occupied.contains($0) }.count
        current.insert(hold, at: min(insertion, current.count))
    }
    for index in current.indices { current[index].position = index }
    let retiring = previous.filter { !$0.phase.retiring && !residentIDs.contains($0.id) && $0.position < 2 }.map { row in
        let green = row.phase.completed && (final[row.id] == nil || generationReallyCompleted(final[row.id]))
        return GenerationRowSnapshot(task: finalTask(row), position: row.position, phase: green ? .exitingSuccess : .exiting)
    }
    let oldRetiring = previous.filter { $0.phase.retiring && !residentIDs.contains($0.id) }.map { row in
        GenerationRowSnapshot(task: row.task.frameGenerationElapsedMs == nil ? finalTask(row) : row.task,
                              position: row.position, phase: row.phase)
    }
    return Array((retiring + oldRetiring).prefix(2)) + current
}

func finishGenerationRowPhase(_ rows: [GenerationRowSnapshot], id: UUID,
                              expected: GenerationRowPhase) -> [GenerationRowSnapshot] {
    if expected == .succeeded {
        return rows.map { row in
            var next = row
            if row.id == id && row.phase == expected { next.phase = .exitingSuccess }
            return next
        }
    }
    return expected.retiring ? rows.filter { $0.id != id || $0.phase != expected } : rows
}
