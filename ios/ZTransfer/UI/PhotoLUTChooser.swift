import SwiftUI
import UniformTypeIdentifiers

struct PhotoLUTChooser: View {
    @ObservedObject var store: PhotoLUTStore
    var onSelect: (String, String, Int) -> Void = { _, _, _ in }
    var onIntensity: (Int) -> Void = { _ in }
    @State private var showingFolder = false
    @State private var files: [RemoteLUTFile] = []
    @State private var access = RemoteLUTFolderAccess()
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("照片 LUT").font(.headline); Spacer(); Button("选择文件夹") { showingFolder = true } }
            if files.isEmpty { Text("未选择 LUT 文件夹").foregroundStyle(.secondary).font(.footnote) }
            ForEach(store.ordered(files), id: \.identifier) { file in
                HStack {
                    Button { choose(file) } label: { Text(file.relativePath).lineLimit(1) }
                    Spacer()
                    Button { store.toggleFavorite(file.identifier) } label: { Image(systemName: store.favorites.contains(file.identifier) ? "star.fill" : "star") }
                    if store.selectedIdentifier == file.identifier { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) }
                }
            }
            if store.selectedIdentifier != nil {
                HStack { Text("强度"); Slider(value: Binding(get: { Double(store.intensityPercent) }, set: { let value = Int($0.rounded()); store.setIntensity(value); onIntensity(value) }), in: 0...100, step: 1); Text("\(store.intensityPercent)%").monospacedDigit() }
            }
        }
        .fileImporter(isPresented: $showingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            do { try access.save(url); store.setFolderBookmark(access.resolve()?.bookmarkDataSafe); files = try access.scan() } catch { files = [] }
        }
        .onAppear { files = (try? access.scan()) ?? [] }
    }
    private func choose(_ file: RemoteLUTFile) {
        guard let data = try? access.read(file), let lut = try? CubeLUTParser.parse(data) else { return }
        _ = try? store.saveSnapshot(lut); store.select(file.identifier); onSelect("cube:\(lut.digest)", file.name, store.intensityPercent)
    }
}

private extension URL {
    var bookmarkDataSafe: Data? { try? bookmarkData(options: URL.BookmarkCreationOptions(rawValue: 1 << 4), includingResourceValuesForKeys: nil, relativeTo: nil) }
}
