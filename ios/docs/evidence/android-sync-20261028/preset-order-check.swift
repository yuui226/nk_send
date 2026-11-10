import Foundation
let names = try String(contentsOfFile: "/tmp/ztransfer-preset-order/names.txt", encoding: .utf8).split(separator: "\n").map(String.init)
let expected = [14,1,0,2,3,5,4,13,6,8,7,11,12,10,9].map { names[$0] }
let files = names.enumerated().map { PresetFile(identifier: String($0.offset), name: $0.element + ".np3", relativePath: $0.element + "/" + $0.element + ".np3", size: nil) }
precondition(RemoteLUTCatalog.visibleFiles(files, fileExtension: "np3").map(\.label) == expected)
precondition(PhotoLUTCategorySelection.categories(in: files).compactMap { $0 } == expected)
precondition(PresetTextOrder.folded("\u{10400}") == Array("\u{10400}".utf16))
print("PASS: Android UTF-16 file and category ordering, including surrogate units")
