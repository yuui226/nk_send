import XCTest
@testable import ZTransfer

final class LosslessCropTaskTests: XCTestCase {
    func testTaskRoundTripsAndPreservesAlignedRecipe() throws {
        let source = JpegCropSource(width: 4000, height: 3000, mcuWidth: 16, mcuHeight: 16, orientation: 1)
        let recipe = JpegCropRecipe(source: source, rect: .init(left: 16, top: 32, right: 2016, bottom: 1536))
        let task = LosslessCropTask(fileID: 42, recipe: recipe, createdAt: Date(timeIntervalSince1970: 10))
        let data = try JSONEncoder().encode(task)
        XCTAssertEqual(try JSONDecoder().decode(LosslessCropTask.self, from: data), task)
    }
    func testStoreAppendsTasks() {
        let defaults = UserDefaults(suiteName: "lossless-crop-test")!
        defaults.removePersistentDomain(forName: "lossless-crop-test")
        let store = LosslessCropTaskStore(defaults: defaults)
        let source = JpegCropSource(width: 100, height: 100, mcuWidth: 8, mcuHeight: 8, orientation: 1)
        store.append(.init(fileID: 1, recipe: .init(source: source, rect: .init(left: 0, top: 0, right: 80, bottom: 80))))
        XCTAssertEqual(store.load().map(\.fileID), [1])
        store.upsert(.init(fileID: 1, recipe: .init(source: source, rect: .init(left: 8, top: 8, right: 88, bottom: 88))))
        XCTAssertEqual(store.load().count, 1); XCTAssertEqual(store.load().first?.rect.left, 8)
        store.remove(fileID: 1); XCTAssertTrue(store.load().isEmpty)
    }
}
