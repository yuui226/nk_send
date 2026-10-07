import Foundation

enum PhotoLUTRuntime {
    private static let storage = Storage()
    static func register(_ lut: CubeLUT) { storage.lock.lock(); storage.tables[lut.digest] = lut; storage.lock.unlock() }
    static func table(digest: String) -> CubeLUT? { storage.lock.lock(); defer { storage.lock.unlock() }; return storage.tables[digest] }
    private final class Storage: @unchecked Sendable { let lock = NSLock(); var tables: [String: CubeLUT] = [:] }
}
