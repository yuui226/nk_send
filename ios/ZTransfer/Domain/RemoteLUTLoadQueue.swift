import Foundation

actor RemoteLUTLoadQueue {
    private var generation: UInt64 = 0
    private var task: Task<CubeLUT?, Never>?

    func load(data: Data, parser: @escaping @Sendable (Data) -> CubeLUT?) async -> CubeLUT? {
        generation &+= 1
        let current = generation
        task?.cancel()
        let next = Task { parser(data) }
        task = next
        let result = await next.value
        guard current == generation, !Task.isCancelled else { return nil }
        return result
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
    }
}
