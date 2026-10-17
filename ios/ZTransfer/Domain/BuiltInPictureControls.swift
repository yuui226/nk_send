import Foundation
import CryptoKit

/// Android BuiltInPictureControls: catalogue order and original bytes are bundled;
/// opening the chooser never downloads a preset. Research samples stay unlisted.
struct BuiltInPictureControl: Identifiable, Equatable, Sendable {
    let name: String
    let fileName: String
    let sizeBytes: Int
    let sha256: String
    var id: String { fileName }

    func read(bundle: Bundle = .main) throws -> NikonPictureControlFile {
        guard let root = bundle.resourceURL else { throw NikonPictureControlError.invalid("Missing built-in Picture Controls") }
        let bytes = try Data(contentsOf: root.appendingPathComponent("PictureControls").appendingPathComponent(fileName))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard bytes.count == sizeBytes, digest == sha256 else {
            throw NikonPictureControlError.invalid("Built-in Picture Control integrity check failed")
        }
        let file = try NikonPictureControlFile(bytes)
        guard file.name == name else { throw NikonPictureControlError.invalid("Built-in Picture Control name mismatch") }
        return file
    }
}

func builtInPictureControls(bundle: Bundle = .main) throws -> [BuiltInPictureControl] {
    struct Catalog: Decodable {
        struct Entry: Decodable { let name: String; let file: String; let sizeBytes: Int; let sha256: String }
        let schemaVersion: Int
        let presets: [Entry]
    }
    guard let root = bundle.resourceURL else { throw NikonPictureControlError.invalid("Missing built-in Picture Controls") }
    let data = try Data(contentsOf: root.appendingPathComponent("PictureControls/catalog.json"))
    let catalog = try JSONDecoder().decode(Catalog.self, from: data)
    guard catalog.schemaVersion == 1, !catalog.presets.isEmpty,
          Set(catalog.presets.map(\.file)).count == catalog.presets.count else {
        throw NikonPictureControlError.invalid("Invalid built-in Picture Control catalogue")
    }
    return try catalog.presets.map { entry in
        guard !entry.file.contains("/"), !entry.file.contains("\\"), entry.file.hasSuffix(".NP3") else {
            throw NikonPictureControlError.invalid("Invalid built-in Picture Control path")
        }
        return BuiltInPictureControl(name: entry.name, fileName: entry.file, sizeBytes: entry.sizeBytes, sha256: entry.sha256)
    }
}
