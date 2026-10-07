import Foundation

struct RemoteLUTFile: Equatable, Sendable {
    let identifier: String
    let name: String
    let relativePath: String
    let size: Int64?
}

enum RemoteLUTCatalog {
    /// Android scans LUT files in the selected root and one category level.
    /// Deeper descendants and non-cube files are intentionally excluded.
    static func visibleFiles(_ files: [RemoteLUTFile]) -> [RemoteLUTFile] {
        files.filter {
            $0.name.lowercased().hasSuffix(".cube") &&
            $0.relativePath.split(separator: "/").count <= 2
        }.sorted {
            $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending
        }
    }
}
