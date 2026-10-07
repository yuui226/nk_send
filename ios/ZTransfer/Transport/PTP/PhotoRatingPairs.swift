import Foundation

private let jpegRatingExtensions: Set<String> = [".jpg", ".jpeg"]
private let rawRatingExtensions: Set<String> = [".nef", ".nrw"]

/// A unique same-name JPEG supplies its paired NEF/NRW rating. Ambiguous,
/// cross-card, or differently-timestamped matches stay independent.
internal func photoRatingSources(_ files: [CameraFile]) -> [UInt32: CameraFile] {
    func stem(_ file: CameraFile) -> String {
        guard let dot = file.fileName.lastIndex(of: ".") else { return file.fileName.lowercased() }
        return file.fileName[..<dot].lowercased()
    }
    let jpegs = Dictionary(grouping: files.filter { jpegRatingExtensions.contains($0.fileExtension) }, by: stem)
    return Dictionary(uniqueKeysWithValues: files.map { file in
        let paired: CameraFile? = rawRatingExtensions.contains(file.fileExtension)
            ? jpegs[stem(file)]?.filter { jpeg in
                (file.storageIDs.isEmpty || jpeg.storageIDs.isEmpty || !file.storageIDs.isDisjoint(with: jpeg.storageIDs)) &&
                (file.captureDate?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false ||
                 jpeg.captureDate?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false ||
                 file.captureDate == jpeg.captureDate)
            }.only
            : nil
        return (file.id, paired ?? file)
    })
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
