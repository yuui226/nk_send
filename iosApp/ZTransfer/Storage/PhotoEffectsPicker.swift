import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// System photo picker bridge for the workbench. A zero selection limit keeps the picker useful
/// for a batch of any size; the session still de-duplicates identities before rendering.
struct PhotoEffectsPicker: UIViewControllerRepresentable {
    let onSelection: ([IOSPhotoEffectAsset]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelection: onSelection) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 0
        configuration.preferredAssetRepresentationMode = .current
        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onSelection: ([IOSPhotoEffectAsset]) -> Void

        init(onSelection: @escaping ([IOSPhotoEffectAsset]) -> Void) {
            self.onSelection = onSelection
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else {
                picker.dismiss(animated: true)
                return
            }
            let ordered = results
            Task { [weak self, weak picker] in
                var assets: [IOSPhotoEffectAsset] = []
                assets.reserveCapacity(ordered.count)
                for result in ordered {
                    guard let url = try? await Self.copyImage(from: result.itemProvider) else { continue }
                    let id = result.assetIdentifier ?? url.lastPathComponent
                    let name = result.itemProvider.suggestedName ?? url.deletingPathExtension().lastPathComponent
                    assets.append(IOSPhotoEffectAsset(id: id, url: url, displayName: name))
                }
                guard let self else { return }
                await MainActor.run {
                    self.onSelection(assets)
                    picker?.dismiss(animated: true)
                }
            }
        }

        private static func copyImage(from provider: NSItemProvider) async throws -> URL {
            guard let type = provider.registeredTypeIdentifiers.first(where: {
                UTType($0)?.conforms(to: .image) == true
            }) else { throw PickerError.unsupportedType }
            let source = try await withCheckedThrowingContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                    if let error { continuation.resume(throwing: error); return }
                    guard let url else { continuation.resume(throwing: PickerError.missingFile); return }
                    do {
                        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
                        let destination = FileManager.default.temporaryDirectory
                            .appendingPathComponent("ztransfer-effect-(UUID().uuidString).(ext)")
                        try FileManager.default.copyItem(at: url, to: destination)
                        continuation.resume(returning: destination)
                    } catch { continuation.resume(throwing: error) }
                }
            }
            return source
        }

        private enum PickerError: Error { case unsupportedType, missingFile }
    }
}

/// The preview host supplies the rendered image, so this pager remains independent of the
/// decoder and filter kernel. Swiping updates the same index used by the session and its status.
@MainActor
struct PhotoEffectsPreviewPager<Content: View>: View {
    @ObservedObject var session: PhotoEffectsBatchSession
    @ViewBuilder let content: (IOSPhotoEffectAsset) -> Content

    var body: some View {
        TabView(selection: Binding(get: { session.previewIndex }, set: session.setPreviewIndex)) {
            ForEach(Array(session.assets.enumerated()), id: \.element.id) { index, asset in
                content(asset)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
    }
}
