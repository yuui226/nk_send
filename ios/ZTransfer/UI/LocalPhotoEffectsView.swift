import PhotosUI
import SwiftUI

/// Android LocalPhotoEffectsPage: fixed 4:3 pager, batch action, inline editors.
/// The picked list is the batch selection; there is no second selection grid.
struct LocalPhotoEffectsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var effectsStore = PhotoEffectsStore(scope: .localPhotos)
    @StateObject private var batch = LocalPhotoBatchViewModel()
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var previewPage = 0
    @State private var showingPicker = false
    @State private var showingHelp = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                toolbar
                preview.padding(.top, 14)
                batchButton.padding(.top, 10)
                if batch.state.phase == .partial || batch.state.phase == .failed {
                    Text("\(batch.state.progress.failed) 张未能保存，原照片未受影响")
                        .font(.system(size: 12)).foregroundStyle(ZTransferColors.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }
                PhotoEffectsControls(draft: Binding(
                    get: { effectsStore.settings },
                    set: { effectsStore.update($0) }
                ), showLocationFields: false)
                .padding(.top, 10).padding(.bottom, 18)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
        .background(ZTransferColors.background.ignoresSafeArea())
        .photosPicker(isPresented: $showingPicker, selection: $pickerItems,
                      matching: .images, preferredItemEncoding: .current)
        .onChange(of: pickerItems) { items in
            guard !items.isEmpty, !batch.state.generating else { return }
            batch.select(items)
            previewPage = 0
        }
        .onDisappear { batch.dispose() }
        .alert("照片效果说明", isPresented: $showingHelp) {
            Button("确定", role: .cancel) {}
        } message: {
            Text("可多选照片，共用当前滤镜、边框和水印，效果图另存。\n\n预览：左右滑动切换照片 · 长按对比滤镜前后\n边框：截图等无 EXIF 的图片不显示拍摄参数\n优先保存到原目录；不可写时自动保存到 Pictures/ZTransfer")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.up").font(.system(size: 19, weight: .semibold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(WorkbenchGlassButtonStyle())
            Text("滤镜·边框·水印").font(.system(size: 16, weight: .bold)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !batch.state.photos.isEmpty {
                Button { showingPicker = true } label: {
                    Text("更换图片").font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10).frame(height: 38)
                }
                .buttonStyle(WorkbenchGlassButtonStyle()).disabled(batch.state.generating)
            }
            Button { showingHelp = true } label: {
                Image(systemName: "lightbulb.fill").foregroundStyle(ZTransferColors.accentOrange)
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(WorkbenchGlassButtonStyle()).accessibilityLabel("照片效果说明")
        }
        .foregroundStyle(ZTransferColors.primaryText)
    }

    private var preview: some View {
        Group {
            if batch.state.photos.isEmpty {
                Button { showingPicker = true } label: {
                    VStack(spacing: 6) {
                        Text("选择图片").font(.system(size: 14, weight: .medium)).foregroundStyle(ZTransferColors.accentBlue)
                        Text("（可多选）").font(.system(size: 12)).foregroundStyle(ZTransferColors.secondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ZTransferColors.primaryText.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(ZTransferColors.secondaryText.opacity(0.15)))
                }
                .buttonStyle(.plain)
            } else {
                TabView(selection: $previewPage) {
                    ForEach(batch.state.photos.indices, id: \.self) { index in
                        Group {
                            // Only the visible page and immediate neighbours
                            // retain bounded 1280-pixel previews.
                            if abs(index - previewPage) <= 1 {
                                LocalEffectPreview(item: batch.state.photos[index], settings: effectsStore.settings)
                            } else { Color.clear }
                        }.tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .id(batch.state.photos)
            }
        }
        .aspectRatio(4.0 / 3, contentMode: .fit)
    }

    private var batchButton: some View {
        Button {
            if batch.state.photos.isEmpty { showingPicker = true }
            else { batch.generate(settings: effectsStore.settings) }
        } label: {
            LocalPhotoBatchLabel(state: batch.state, page: previewPage)
                .frame(maxWidth: .infinity).frame(height: 50).clipped()
        }
        .buttonStyle(WorkbenchGlassButtonStyle())
        .disabled(batch.state.phase != .ready || (!batch.state.photos.isEmpty && !effectsStore.settings.hasEffect))
    }
}

private struct LocalPhotoBatchLabel: View {
    let state: LocalPhotoBatchState<PhotosPickerItem>
    let page: Int
    @State private var previousPhase: LocalPhotoBatchPhase = .ready

    var body: some View {
        ZStack {
            HStack(spacing: 10) {
                if state.phase == .ready, !state.photos.isEmpty {
                    Text("\(page + 1) / \(state.photos.count)").font(.system(size: 12)).monospacedDigit()
                        .foregroundStyle(ZTransferColors.secondaryText)
                }
                if state.phase == .generating {
                    HStack(spacing: 0) {
                        Text("生成中 ")
                        Text("\(state.progress.completed)").fontWeight(.bold).monospacedDigit()
                            .id(state.progress.completed)
                            .transition(.asymmetric(
                                insertion: .offset(y: -8).combined(with: .opacity).animation(.easeOut(duration: 0.16)),
                                removal: .offset(y: 8).combined(with: .opacity).animation(.easeOut(duration: 0.12))))
                        Text("/\(state.progress.total)").fontWeight(.bold).monospacedDigit()
                    }
                } else { Text(text) }
            }
            .font(.system(size: 14, weight: .semibold)).foregroundStyle(ZTransferColors.primaryText)
            .id(state.phase)
            .transition(ZTransferMotion.buttonStateTransition(forward: state.phase.rawValue >= previousPhase.rawValue))
        }
        .animation(.easeInOut(duration: 0.22), value: state.phase)
        .animation(.easeOut(duration: 0.16), value: state.progress.completed)
        .onChange(of: state.phase) { previousPhase = $0 }
    }

    private var text: String {
        switch state.phase {
        case .complete: "已保存 \(state.progress.saved) 张"
        case .partial: "已保存 \(state.progress.saved)/\(state.progress.total) 张"
        case .failed: "生成失败"
        default: state.photos.isEmpty ? "选择图片" : "生成并保存（\(state.photos.count)）"
        }
    }
}

private struct LocalEffectPreview: View {
    let item: PhotosPickerItem
    let settings: PhotoEffectsSettings
    @State private var source: UIImage?
    @State private var images: LocalPhotoPreviewImages?
    @State private var failed = false
    @GestureState private var comparing = false

    var body: some View {
        Group {
            if let images {
                Image(uiImage: comparing ? images.unfiltered : images.filtered).resizable().scaledToFit()
            } else if failed {
                Text("这张照片暂时无法预览，可滑动查看其他照片")
                    .font(.system(size: 12)).foregroundStyle(ZTransferColors.secondaryText)
            } else { ProgressView().tint(ZTransferColors.accentBlue) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($comparing) { value, state, _ in
                if case .second(true, _) = value { state = true }
            })
        .task(id: PreviewRequest(item: item, settings: settings)) {
            do {
                let image: UIImage
                if let source { image = source }
                else {
                    image = try await LocalPhotoOutput.decodePreview(item: item)
                    try Task.checkCancellation()
                    source = image
                }
                let next = try await LocalPhotoOutput.preview(image: image, settings: settings)
                try Task.checkCancellation()
                images = next
                failed = false
            } catch is CancellationError {} catch { failed = true }
        }
    }
}

private struct PreviewRequest: Equatable {
    let item: PhotosPickerItem
    let settings: PhotoEffectsSettings
}

private struct WorkbenchGlassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(ZTransferColors.secondaryText.opacity(0.15)))
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(ZTransferMotion.standard, value: configuration.isPressed)
    }
}
