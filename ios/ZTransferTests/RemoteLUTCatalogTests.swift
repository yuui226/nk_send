import XCTest
@testable import ZTransfer

final class RemoteLUTCatalogTests: XCTestCase {
    func testCategorySelectionLocatesCurrentButPreservesUserChoiceOnRefresh() {
        let files = [
            RemoteLUTFile(identifier: "b", name: "b.cube", relativePath: "B/b.cube", size: nil),
            RemoteLUTFile(identifier: "root", name: "root.cube", relativePath: "root.cube", size: nil),
            RemoteLUTFile(identifier: "a", name: "a.cube", relativePath: "A/a.cube", size: nil)
        ]
        XCTAssertEqual(PhotoLUTCategorySelection.categories(in: files), [nil, "A", "B"])
        var selection = PhotoLUTCategorySelection()
        selection.reconcile(files: [], selected: "b")
        selection.reconcile(files: files, selected: "b")
        XCTAssertEqual(selection.category, "B")
        selection.category = "A"
        selection.reconcile(files: Array(files.reversed()), selected: "b")
        XCTAssertEqual(selection.category, "A")
        selection.reconcile(files: files, selected: "root")
        XCTAssertNil(selection.category)
        selection.category = "A"
        selection.reconcile(files: files.filter { $0.category != "A" }, selected: "root")
        XCTAssertNil(selection.category)
        selection.reconcile(files: [], selected: nil)
        XCTAssertNil(selection.category)
    }

    func testDuplicateLabelsIncludeCategoryAndStableFolderPositions() {
        let files = [
            RemoteLUTFile(identifier: "root", name: "Film.cube", relativePath: "Film.cube", size: nil),
            RemoteLUTFile(identifier: "one", name: "Film.cube", relativePath: "A/Film.cube", size: nil),
            RemoteLUTFile(identifier: "two", name: "film.CUBE", relativePath: "A/film.CUBE", size: nil),
            RemoteLUTFile(identifier: "unique", name: "Solo.cube", relativePath: "B/Solo.cube", size: nil),
            RemoteLUTFile(identifier: "empty", name: ".cube", relativePath: ".cube", size: nil)
        ]
        let labels = RemoteLUTCatalog.labels(files, uncategorized: "Uncategorized")
        XCTAssertEqual(labels["root"], "Film · Uncategorized")
        XCTAssertEqual(labels["one"], "Film · A · 2")
        XCTAssertEqual(labels["two"], "film · A · 3")
        XCTAssertEqual(labels["unique"], "Solo")
        XCTAssertEqual(labels["empty"], ".cube")
        let favoriteFirst = [files[2], files[0], files[1]]
        XCTAssertEqual(favoriteFirst.map { labels[$0.identifier]! },
                       ["film · A · 3", "Film · Uncategorized", "Film · A · 2"])
        XCTAssertEqual(RemoteLUTCatalog.labels(files, uncategorized: "未分類")["root"], "Film · 未分類")
    }

    func testPhotoFolderStatusAndNameFirstOrdering() {
        XCTAssertEqual(RemoteLUTCatalog.photoFolderStatus(hasFolder: false, loading: true, failure: "error"), "photo_lut_set_folder")
        XCTAssertEqual(RemoteLUTCatalog.photoFolderStatus(hasFolder: true, loading: true, failure: "lut_folder_denied"), "lut_folder_denied")
        XCTAssertEqual(RemoteLUTCatalog.photoFolderStatus(hasFolder: true, loading: true, failure: nil), "lut_reading_folder")
        XCTAssertEqual(RemoteLUTCatalog.photoFolderStatus(hasFolder: true, loading: false, failure: nil), "lut_folder_empty")
        let files = [
            RemoteLUTFile(identifier: "2", name: "z.cube", relativePath: "A/z.cube", size: nil),
            RemoteLUTFile(identifier: "3", name: "a.cube", relativePath: "Z/a.cube", size: nil),
            RemoteLUTFile(identifier: "1", name: "A.cube", relativePath: "A.cube", size: nil),
            RemoteLUTFile(identifier: "4", name: "a.cube", relativePath: "B/a.cube", size: nil)
        ]
        XCTAssertEqual(RemoteLUTCatalog.visibleFiles(files).map(\.identifier), ["1", "3", "4", "2"])
    }

    func testRootAndOneCategoryCubeFilesOnly() {
        let input = [
            RemoteLUTFile(identifier: "deep", name: "deep.cube", relativePath: "film/2026/deep.cube", size: 1),
            RemoteLUTFile(identifier: "txt", name: "readme.txt", relativePath: "readme.txt", size: 1),
            RemoteLUTFile(identifier: "b", name: "B.CUBE", relativePath: "film/B.CUBE", size: 1),
            RemoteLUTFile(identifier: "a", name: "a.cube", relativePath: "a.cube", size: 1)
        ]
        XCTAssertEqual(RemoteLUTCatalog.visibleFiles(input).map(\.identifier), ["a", "b"])
    }
}
