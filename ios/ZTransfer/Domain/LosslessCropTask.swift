import Foundation

struct LosslessCropTask: Codable, Equatable, Sendable {
    let fileID: UInt32
    let source: JpegCropSource
    let rect: CropRect
    let createdAt: Date
    init(fileID: UInt32, recipe: JpegCropRecipe, createdAt: Date = Date()) {
        recipe.source.validate(recipe.rect)
        self.fileID = fileID; self.source = recipe.source; self.rect = recipe.rect; self.createdAt = createdAt
    }
}

struct LosslessCropTaskStore {
    private let defaults: UserDefaults
    private let key: String
    init(defaults: UserDefaults = .standard, key: String = "losslessCropTasks.v1") { self.defaults = defaults; self.key = key }
    func load() -> [LosslessCropTask] { guard let data = defaults.data(forKey: key), let values = try? JSONDecoder().decode([LosslessCropTask].self, from: data) else { return [] }; return values }
    func save(_ tasks: [LosslessCropTask]) { defaults.set(try? JSONEncoder().encode(tasks), forKey: key) }
    func append(_ task: LosslessCropTask) { save(load() + [task]) }
    func upsert(_ task: LosslessCropTask) {
        var tasks = load(); tasks.removeAll { $0.fileID == task.fileID }; tasks.append(task); save(tasks)
    }
    func remove(fileID: UInt32) { save(load().filter { $0.fileID != fileID }) }
}
