import SwiftUI

/// One presentation owner shared by settings and the phone-photo workbench. Hosts call `present`
/// from their existing effect action; the route keeps sheet lifetime outside the effect controls.
@MainActor
final class PhotoEffectsPresentation: ObservableObject {
    @Published private(set) var isPresented = false

    func present() { isPresented = true }
    func dismiss() { isPresented = false }
}

@MainActor
struct PhotoEffectsPresentationModifier: ViewModifier {
    @ObservedObject var presentation: PhotoEffectsPresentation
    let generateAndSave: @Sendable (IOSPhotoEffectAsset, IOSPhotoFilterSelection) async throws -> Bool

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { presentation.isPresented },
            set: { value in if !value { presentation.dismiss() } }
        )) {
            PhotoEffectsWorkbench(generateAndSave: generateAndSave)
                .presentationDragIndicator(.visible)
        }
    }
}

@MainActor
extension View {
    func photoEffectsPresentation(
        _ presentation: PhotoEffectsPresentation,
        generateAndSave: @escaping @Sendable (IOSPhotoEffectAsset, IOSPhotoFilterSelection) async throws -> Bool = { asset, selection in
            try await PhotoEffectsExportService().generateAndSave(asset, selection: selection)
        }
    ) -> some View {
        modifier(PhotoEffectsPresentationModifier(presentation: presentation, generateAndSave: generateAndSave))
    }
}

@MainActor
struct PhotoEffectsEntryButton: View {
    let presentation: PhotoEffectsPresentation

    var body: some View {
        Button {
            presentation.present()
        } label: {
            Label("照片效果", systemImage: "wand.and.stars")
        }
        .accessibilityLabel("打开照片效果")
    }
}
