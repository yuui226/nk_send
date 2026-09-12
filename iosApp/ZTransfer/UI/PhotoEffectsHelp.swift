import SwiftUI
import ZTransferShared

@MainActor
final class PhotoEffectsHelpModel: ObservableObject {
    @Published private(set) var languageTag: String

    init(languageTag: String = Locale.preferredLanguages.first ?? "zh-Hans") {
        self.languageTag = languageTag
    }

    var text: NativePhotoEffectsHelpText {
        NativePhotoEffectsText.shared.forLanguage(languageTag: languageTag)
    }

    func updateLanguage(_ tag: String) {
        languageTag = tag
    }
}

/// One shared help surface for both the settings effect card and the photo-workbench effect card.
/// The host controls placement; this component owns wording, accessibility and presentation only.
@MainActor
struct PhotoEffectsHelpButton: View {
    @StateObject private var model: PhotoEffectsHelpModel
    @ObservedObject private var appearance = AppAppearanceSettings.shared
    @State private var showingHelp = false

    init(model: PhotoEffectsHelpModel = PhotoEffectsHelpModel()) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        Button {
            showingHelp = true
        } label: {
            Image(systemName: "lightbulb")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.yellow)
                .frame(width: 42, height: 42)
                .background(.ultraThinMaterial, in: Circle())
                .overlay { Circle().stroke(Color.white.opacity(0.28), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("照片效果使用提示")
        .accessibilityHint(model.text.longPressHint)
        .sheet(isPresented: $showingHelp) {
            PhotoEffectsHelpCard(model: model)
                .presentationDetents([.height(190)])
                .presentationDragIndicator(.visible)
        }
        .onAppear { model.updateLanguage(appearance.languageTag) }
        .onChange(of: appearance.languageTag) { model.updateLanguage($0) }
    }
}

@MainActor
struct PhotoEffectsHelpCard: View {
    @ObservedObject var model: PhotoEffectsHelpModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("照片效果", systemImage: "lightbulb.fill")
                .font(.headline)
                .foregroundStyle(.yellow)
            Text(model.text.dialHint)
            Text(model.text.longPressHint)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(.ultraThinMaterial)
    }
}
