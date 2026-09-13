import PhotosUI
import SwiftUI

/// Android LocalPhotoEffectsPage: fixed 4:3 pager, batch action, inline editors.
/// The picked list is the batch selection; there is no second selection grid.
struct LocalPhotoEffectsView: View {
    let onNavigateUp: () -> Void
    @StateObject private var effectsStore = PhotoEffectsStore(scope: .localPhotos)
    @StateObject private var batch = LocalPhotoBatchViewModel()
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var watermarkPickerItems: [PhotosPickerItem] = []
    @State private var previewPage = 0
    @State private var showingPicker = false
    @State private var showingHelp = false
    @State private var showingWatermarkPicker = false
    @State private var scrollOffset: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                toolbar
                preview.padding(.top, 14)
                batchButton.padding(.top, 10)
                batchFailureView
                LocalWorkbenchControls(draft: effectsBinding,
                                       showingWatermarkPicker: $showingWatermarkPicker,
                                       showLocationFields: false)
                .padding(.top, 10).padding(.bottom, 18)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: 680).frame(maxWidth: .infinity)
            .background(WorkbenchScrollTracker())
        }
        .coordinateSpace(name: "workbenchScroll")
        .onPreferenceChange(WorkbenchScrollOffsetKey.self) { scrollOffset = $0 }
        // The Android pager takes over when the workbench is at its top edge.
        // Keeping this simultaneous avoids stealing vertical scrolling inside
        // the editor once the user has moved down the page.
        .simultaneousGesture(DragGesture(minimumDistance: 18).onEnded { value in
            // Wheel drags are vertical too; only the top navigation/preview
            // band may hand a downward gesture to the page pager. This keeps
            // changing a detent from accidentally navigating back.
            guard scrollOffset >= -2, value.startLocation.y < 360,
                  value.translation.height > 70 else { return }
            onNavigateUp()
        })
        .background(ZTransferColors.background.ignoresSafeArea())
        .photosPicker(isPresented: $showingPicker, selection: $pickerItems,
                      matching: .images, preferredItemEncoding: .current)
        .photosPicker(isPresented: $showingWatermarkPicker, selection: $watermarkPickerItems,
                      maxSelectionCount: 1, matching: .images, preferredItemEncoding: .current)
        .onChange(of: pickerItems) { items in
            guard !items.isEmpty, !batch.state.generating else { return }
            batch.select(items)
            previewPage = 0
        }
        .onChange(of: watermarkPickerItems) { items in
            guard let item = items.last else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data),
                      let hash = effectsStore.importWatermarkImage(image) else {
                    await MainActor.run { watermarkPickerItems = [] }
                    return
                }
                var watermark = effectsStore.settings.watermark
                watermark.content = .image
                watermark.imageHash = hash
                var updated = effectsStore.settings
                updated.watermark = watermark
                effectsStore.update(updated)
                await MainActor.run { watermarkPickerItems = [] }
            }
        }
        .alert("照片效果说明", isPresented: $showingHelp) {
            Button("确定", role: .cancel) {}
        } message: {
            Text("可多选照片，共用当前滤镜、边框和水印，效果图另存。\n\n预览：左右滑动切换照片 · 长按对比滤镜前后\n边框：截图等无 EXIF 的图片不显示拍摄参数\n优先保存到原目录；不可写时自动保存到 Pictures/ZTransfer")
        }
    }

    private var batchHasFailure: Bool {
        batch.state.phase == .partial || batch.state.phase == .failed
    }

    private var batchFailureText: String {
        let failed = batch.state.progress.failed
        return "\(failed) 张未能保存，原照片未受影响"
    }

    @ViewBuilder private var batchFailureView: some View {
        if batchHasFailure {
            Text(batchFailureText)
                .font(.system(size: 12)).foregroundStyle(ZTransferColors.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
        }
    }

    private var effectsBinding: Binding<PhotoEffectsSettings> {
        Binding(get: { effectsStore.settings }, set: { effectsStore.update($0) })
    }

    private var previewSettings: PhotoEffectsSettings {
        var value = effectsStore.settings
        value.metadata = value.metadataByPreset[value.photoFramePreset.rawValue] ?? value.metadata
        return value
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button(action: onNavigateUp) {
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
                                LocalEffectPreview(item: batch.state.photos[index], settings: previewSettings)
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
            else { batch.generate(settings: previewSettings) }
        } label: {
            LocalPhotoBatchLabel(state: batch.state, page: previewPage)
                .frame(maxWidth: .infinity).frame(height: 50).clipped()
        }
        .buttonStyle(WorkbenchGlassButtonStyle())
        .disabled(batch.state.phase != .ready || (!batch.state.photos.isEmpty && !effectsStore.settings.hasEffect))
    }
}

/// Compact arrangement used by Android's LocalPhotoEffectsPage.  The transfer
/// settings editor intentionally remains a different card hierarchy; the
/// workbench puts the filter row first, then the frame row and nested watermark
/// controls exactly in that order.
private struct LocalWorkbenchControls: View {
    @Binding var draft: PhotoEffectsSettings
    @Binding var showingWatermarkPicker: Bool
    var showLocationFields = false
    @State private var metadataExpanded = false
    @State private var watermarkExpanded = false
    @State private var filterChooserPresented = false
    @State private var filterChooserCategory: LocalPhotoFilterCategory = .all

    private var filterOptions: [String?] {
        let favorites = PhotoFilterCatalog.presets.filter(isFavorite)
        let regular = PhotoFilterCatalog.presets.filter { !isFavorite($0) }
        return [nil] + (favorites + regular).map(\.id)
    }
    private func filterKey(_ id: String) -> String {
        Np3FilterCatalog.preset(id: id)?.catalogKey ?? id
    }
    private func isFavorite(_ preset: PhotoFilterPreset) -> Bool { draft.favoriteFilterIDs.contains(filterKey(preset.id)) }
    private func isFavoriteID(_ id: String) -> Bool { draft.favoriteFilterIDs.contains(filterKey(id)) }
    private var selectedFilterID: String? { draft.photoFilterEnabled ? draft.selectedFilter?.preset.id : nil }
    private var frameEnabled: Bool { draft.photoFrameEnabled && draft.photoFrameBorderEnabled }
    private var activeMetadata: PhotoFrameMetadataSettings {
        draft.metadataByPreset[draft.photoFramePreset.rawValue] ?? draft.metadata
    }
    private var orderedFrameOptions: [PhotoFramePreset?] {
        let favorites = draft.favoriteFrameEffects.map(\.preset)
        let ordered = favorites + PhotoFramePreset.allCases.filter { !favorites.contains($0) }
        return [nil] + ordered
    }
    private var photoWatermarkPositions: [PhotoFrameWatermarkPosition] {
        [.photoTopLeft, .photoTopCenter, .photoTopRight, .photoCenter,
         .photoBottomLeft, .photoBottomCenter, .photoBottomRight]
    }
    private var textWatermarkPositions: [PhotoFrameWatermarkPosition] {
        frameEnabled ? PhotoFrameWatermarkPosition.allCases : photoWatermarkPositions
    }
    private func updateMetadata(_ update: (inout PhotoFrameMetadataSettings) -> Void) {
        var value = activeMetadata
        update(&value)
        draft.metadata = value
        draft.metadataByPreset[draft.photoFramePreset.rawValue] = value
    }

    var body: some View {
        ZStack {
        VStack(spacing: 10) {
            WorkbenchCard(accent: ZTransferColors.accentBlue) {
                HStack(spacing: 8) {
                    DetentWheel(label: "照片滤镜", options: filterOptions, selected: selectedFilterID,
                                optionLabel: { id in id.flatMap { PhotoFilterCatalog.resolve($0)?.name } ?? "关闭" },
                                onCommit: { id in
                                    guard let id, let preset = PhotoFilterCatalog.resolve(id) else {
                                        draft.photoFilterEnabled = false; return
                                    }
                                    draft.photoFilterEnabled = true
                                    let remembered = draft.filterIntensities[filterKey(id)] ?? draft.selectedFilter?.intensityPercent ?? 80
                                    draft.selectedFilter = .init(preset: preset, intensityPercent: remembered)
                                }, rowHeight: 18, wheelHeight: 50,
                                onLongClick: { filterChooserPresented = true },
                                favoriteOption: { id in id.map(isFavoriteID) ?? false },
                                favoriteIconColor: ZTransferColors.accentBlue)
                    .frame(maxWidth: .infinity)
                    DetentWheel(label: "滤镜强度", options: Array(stride(from: 100, through: 2, by: -2)),
                                selected: draft.selectedFilter?.intensityPercent ?? 80,
                                optionLabel: { "\($0)%" }, onCommit: { value in
                                    guard let selected = draft.selectedFilter else { return }
                                    draft.filterIntensities[filterKey(selected.preset.id)] = value
                                    draft.selectedFilter = .init(preset: selected.preset, intensityPercent: value)
                                }, rowHeight: 18, wheelHeight: 50, enabled: draft.photoFilterEnabled)
                    .frame(maxWidth: .infinity)
                    Button {
                        if let id = selectedFilterID {
                            let key = filterKey(id)
                            if draft.favoriteFilterIDs.contains(key) { draft.favoriteFilterIDs.remove(key) }
                            else { draft.favoriteFilterIDs.insert(key) }
                        }
                    } label: {
                        Image(systemName: selectedFilterID.map(isFavoriteID) == true ? "star.fill" : "star")
                            .font(.system(size: 25, weight: .medium))
                            .foregroundStyle(selectedFilterID.map(isFavoriteID) == true ? ZTransferColors.accentBlue : ZTransferColors.secondaryText)
                            .frame(width: 50, height: 50)
                    }.buttonStyle(.plain)
                    .disabled(selectedFilterID == nil || !draft.photoFilterEnabled)
                    .opacity(selectedFilterID == nil || !draft.photoFilterEnabled ? 0.48 : 1)
            }
        }
            WorkbenchCard(accent: ZTransferColors.accentOrange) {
                HStack(spacing: 8) {
                    DetentWheel(label: "边框", options: orderedFrameOptions,
                                selected: frameEnabled ? draft.photoFramePreset : nil,
                                optionLabel: { $0.map(frameName) ?? "关闭" }, onCommit: { value in
                                    guard let value else {
                                        draft.photoFrameBorderEnabled = false
                                        draft.photoFrameEnabled = draft.watermark.enabled
                                        return
                                    }
                                    draft.photoFramePreset = value
                                    draft.photoFrameEnabled = true
                                    draft.photoFrameBorderEnabled = true
                                    if draft.metadataByPreset[value.rawValue] == nil {
                                        let defaults = PhotoFrameMetadataSettings.defaults(for: value)
                                        draft.metadataByPreset[value.rawValue] = defaults
                                        draft.metadata = defaults
                                    }
                                    if let favorite = draft.favoriteFrameEffects.first(where: { $0.preset == value }) {
                                        draft.watermark = favorite.watermark
                                    }
                                }, rowHeight: 18, wheelHeight: 50, accentColor: ZTransferColors.accentOrange)
                    .frame(maxWidth: .infinity)
                    DetentWheel(label: "边框信息", options: [false], selected: false,
                                optionLabel: { _ in "边框信息" }, onCommit: { _ in },
                                rowHeight: 18, wheelHeight: 50, enabled: frameEnabled,
                                accentColor: ZTransferColors.accentOrange,
                                emphasized: metadataExpanded,
                                onActivated: { withAnimation(.easeInOut(duration: 0.30)) { metadataExpanded.toggle() } })
                    .frame(maxWidth: .infinity)
                    Button {
                        guard frameEnabled else { return }
                        let preset = draft.photoFramePreset
                        if let index = draft.favoriteFrameEffects.firstIndex(where: { $0.preset == preset }) {
                            draft.favoriteFrameEffects.remove(at: index)
                            draft.favoriteFramePresets.remove(preset)
                        } else {
                            draft.favoriteFrameEffects.append(.init(preset: preset, watermark: draft.watermark))
                            draft.favoriteFramePresets.insert(preset)
                        }
                    } label: {
                        Image(systemName: draft.favoriteFrameEffects.contains(where: { $0.preset == draft.photoFramePreset }) ? "star.fill" : "star")
                            .font(.system(size: 25, weight: .medium))
                            .foregroundStyle(draft.favoriteFrameEffects.contains(where: { $0.preset == draft.photoFramePreset }) ? ZTransferColors.accentOrange : ZTransferColors.secondaryText)
                            .frame(width: 50, height: 50)
                    }.buttonStyle(.plain)
                    .disabled(!frameEnabled)
                    .opacity(frameEnabled ? 1 : 0.48)
                }
                if frameEnabled && metadataExpanded {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            metadataButton("焦距", activeMetadata.showFocalLength) { updateMetadata { $0.showFocalLength.toggle() } }
                            metadataButton("曝光参数", activeMetadata.showExposure) { updateMetadata { $0.showExposure.toggle() } }
                            metadataButton("镜头型号", activeMetadata.showLensModel) { updateMetadata { $0.showLensModel.toggle() } }
                        }
                        HStack(spacing: 8) {
                            metadataButton("品牌", activeMetadata.showBrand) { updateMetadata { $0.showBrand.toggle() } }
                            metadataButton("型号", activeMetadata.showModel) { updateMetadata { $0.showModel.toggle() } }
                        }
                        HStack(spacing: 8) {
                            let datePatterns: [String?] = [nil, "yyyy-MM-dd", "yyyy/MM/dd", "yyyy.MM.dd", "MM-dd-yyyy"]
                            let timePatterns: [String?] = [nil, "HH:mm", "HH:mm:ss", "HH.mm", "HH.mm.ss"]
                            DetentWheel(label: "日期格式", options: datePatterns, selected: activeMetadata.showDate ? activeMetadata.datePattern : nil,
                                        optionLabel: { value in
                                            guard let value else { return "关闭" }
                                            switch value { case "yyyy-MM-dd": return "2026-08-17"; case "yyyy/MM/dd": return "2026/08/17"; case "yyyy.MM.dd": return "2026.08.17"; default: return "08-17-2026" }
                                        }, onCommit: { value in updateMetadata { $0.showDate = value != nil; if let value { $0.datePattern = value } } }, rowHeight: 18, wheelHeight: 50)
                            DetentWheel(label: "时间格式", options: timePatterns, selected: activeMetadata.showTime ? activeMetadata.timePattern : nil,
                                        optionLabel: { value in
                                            guard let value else { return "关闭" }
                                            switch value { case "HH:mm": return "14:32"; case "HH:mm:ss": return "14:32:08"; case "HH.mm": return "14.32"; default: return "14.32.08" }
                                        }, onCommit: { value in updateMetadata { $0.showTime = value != nil; if let value { $0.timePattern = value } } }, rowHeight: 18, wheelHeight: 50)
                        }
                    }
                    .padding(8)
                    .background(.thinMaterial.opacity(0.58), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(ZTransferColors.secondaryText.opacity(0.18)))
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                }
            }
            WorkbenchCard(accent: ZTransferColors.accentPurple) {
                HStack(spacing: 8) {
                    DetentWheel(label: "水印", options: [false, true], selected: draft.watermark.enabled,
                                optionLabel: { $0 ? "开启" : "关闭" }, onCommit: { value in
                                    draft.watermark.enabled = value
                                    draft.photoFrameEnabled = draft.photoFrameBorderEnabled || value
                                }, rowHeight: 18, wheelHeight: 50, enabled: true, accentColor: ZTransferColors.accentPurple)
                    DetentWheel(label: "水印设置", options: [false], selected: false,
                                optionLabel: { _ in "水印设置" }, onCommit: { _ in }, rowHeight: 18, wheelHeight: 50,
                                enabled: draft.watermark.enabled, accentColor: ZTransferColors.accentPurple,
                                emphasized: watermarkExpanded,
                                onActivated: { withAnimation(.easeInOut(duration: 0.30)) { watermarkExpanded.toggle() } })
                }
                if watermarkExpanded && draft.watermark.enabled {
                    VStack(spacing: 8) {
                        DetentWheel(label: "水印类型", options: PhotoFrameWatermarkContent.allCases, selected: draft.watermark.content,
                                    optionLabel: { $0 == .text ? "文字" : "图片" }, onCommit: { value in
                                        if value == .image && draft.watermark.imageHash == nil { showingWatermarkPicker = true }
                                        else { draft.watermark.content = value }
                                    }, rowHeight: 18, wheelHeight: 50, accentColor: ZTransferColors.accentPurple)
                        if draft.watermark.content == .text {
                            TextField("水印文字", text: Binding(get: { draft.watermark.text }, set: { draft.watermark.text = String($0.prefix(PhotoFrameWatermark.maxTextLength)) }))
                                .textFieldStyle(.plain).padding(.horizontal, 12).frame(height: 42)
                                .background(ZTransferColors.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                        } else {
                            Button("更换 Logo") { showingWatermarkPicker = true }
                                .buttonStyle(WorkbenchGlassButtonStyle()).frame(maxWidth: .infinity).frame(height: 42)
                        }
                        if draft.watermark.content == .text {
                            HStack(spacing: 8) {
                                DetentWheel(label: "字体", options: PhotoFrameWatermarkFont.allCases, selected: draft.watermark.font, optionLabel: fontName, onCommit: { draft.watermark.font = $0 }, rowHeight: 18, wheelHeight: 50, accentColor: ZTransferColors.accentPurple)
                                DetentWheel(label: "大小", options: Array(stride(from: 100, through: 2, by: -2)), selected: draft.watermark.sizePercent, optionLabel: { "\($0)%" }, onCommit: { draft.watermark.sizePercent = $0 }, rowHeight: 18, wheelHeight: 50, accentColor: ZTransferColors.accentPurple)
                                DetentWheel(label: "透明度", options: Array(stride(from: 100, through: 2, by: -2)), selected: draft.watermark.opacityPercent, optionLabel: { "\($0)%" }, onCommit: { draft.watermark.opacityPercent = $0 }, rowHeight: 18, wheelHeight: 50, accentColor: ZTransferColors.accentPurple)
                            }
                            HStack(spacing: 8) {
                                DetentWheel(label: "位置", options: textWatermarkPositions, selected: textWatermarkPositions.contains(draft.watermark.position) ? draft.watermark.position : .photoBottomCenter, optionLabel: positionName, onCommit: { draft.watermark.position = $0 }, rowHeight: 18, wheelHeight: 50, accentColor: ZTransferColors.accentPurple)
                                DetentWheel(label: "颜色", options: PhotoFrameWatermarkColor.allCases, selected: draft.watermark.color, optionLabel: colorName, onCommit: { draft.watermark.color = $0 }, rowHeight: 18, wheelHeight: 50, accentColor: ZTransferColors.accentPurple)
                                DetentWheel(label: "可读性", options: PhotoFrameWatermarkEffect.allCases, selected: draft.watermark.effect, optionLabel: effectName, onCommit: { draft.watermark.effect = $0 }, rowHeight: 18, wheelHeight: 50, accentColor: ZTransferColors.accentPurple)
                            }
                        } else {
                            HStack(spacing: 8) {
                                DetentWheel(label: "大小", options: Array(stride(from: 100, through: 2, by: -2)), selected: draft.watermark.sizePercent, optionLabel: { "\($0)%" }, onCommit: { draft.watermark.sizePercent = $0 }, rowHeight: 18, wheelHeight: 50, accentColor: ZTransferColors.accentPurple)
                                DetentWheel(label: "透明度", options: Array(stride(from: 100, through: 2, by: -2)), selected: draft.watermark.opacityPercent, optionLabel: { "\($0)%" }, onCommit: { draft.watermark.opacityPercent = $0 }, rowHeight: 18, wheelHeight: 50, accentColor: ZTransferColors.accentPurple)
                                DetentWheel(label: "位置", options: photoWatermarkPositions, selected: photoWatermarkPositions.contains(draft.watermark.position) ? draft.watermark.position : .photoBottomCenter, optionLabel: positionName, onCommit: { draft.watermark.position = $0 }, rowHeight: 18, wheelHeight: 50, accentColor: ZTransferColors.accentPurple)
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                }
            }
            .onChange(of: draft.watermark) { value in
                guard frameEnabled else { return }
                guard let index = draft.favoriteFrameEffects.firstIndex(where: { $0.preset == draft.photoFramePreset }) else { return }
                draft.favoriteFrameEffects[index].watermark = value
            }
        }
        if filterChooserPresented { filterChooserOverlay }
        }
        .animation(ZTransferMotion.standard, value: filterChooserPresented)
        .onChange(of: draft.photoFrameBorderEnabled) { value in
            if !value { metadataExpanded = false }
        }
        .onChange(of: draft.watermark.enabled) { value in
            if !value { watermarkExpanded = false }
        }
    }

    private var filterChooserOverlay: some View {
        ZStack {
            Color.black.opacity(0.18).ignoresSafeArea()
                .onTapGesture { filterChooserPresented = false }
            HStack(spacing: 8) {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(LocalPhotoFilterCategory.allCases) { category in
                            Button {
                                filterChooserCategory = category
                            } label: {
                                Text(category.title)
                                    .font(.system(size: 13, weight: filterChooserCategory == category ? .semibold : .regular))
                                    .foregroundStyle(filterChooserCategory == category ? ZTransferColors.accentBlue : ZTransferColors.secondaryText)
                                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .background(filterChooserCategory == category ? ZTransferColors.accentBlue.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(width: 84)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(filterChooserItems) { preset in
                            Button {
                                draft.photoFilterEnabled = true
                                let remembered = draft.filterIntensities[filterKey(preset.id)] ?? draft.selectedFilter?.intensityPercent ?? 80
                                draft.selectedFilter = .init(preset: preset, intensityPercent: remembered)
                                filterChooserPresented = false
                            } label: {
                                HStack(spacing: 8) {
                                    if isFavorite(preset) { Image(systemName: "star.fill").font(.system(size: 12)).foregroundStyle(ZTransferColors.accentBlue) }
                                    Text(preset.name).font(.system(size: 14, weight: selectedFilterID == preset.id ? .semibold : .regular)).foregroundStyle(ZTransferColors.primaryText)
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                                .padding(.horizontal, 10)
                                .background(selectedFilterID == preset.id ? ZTransferColors.accentBlue.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(10)
            .frame(width: 320, height: 420)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(ZTransferColors.secondaryText.opacity(0.18)))
            .shadow(radius: 12, y: 5)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private var filterChooserItems: [PhotoFilterPreset] {
        let all = PhotoFilterCatalog.presets
        let candidates: [PhotoFilterPreset]
        switch filterChooserCategory {
        case .all: candidates = all
        case .favorites: candidates = all.filter(isFavorite)
        default: candidates = all.filter { $0.category == filterChooserCategory }
        }
        let favorites = candidates.filter(isFavorite)
        return favorites + candidates.filter { !isFavorite($0) }
    }

    private func metadataButton(_ title: String, _ selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(selected ? .white : ZTransferColors.primaryText).frame(maxWidth: .infinity).frame(height: 48).background(selected ? ZTransferColors.accentBlue : ZTransferColors.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 12)) }.buttonStyle(.plain)
    }
    private func frameName(_ value: PhotoFramePreset) -> String {
        switch value {
        case .mist: return "雾白"; case .cinema: return "暗夜"; case .minimal: return "简白"; case .frosted: return "毛玻璃"; case .plaque: return "铭牌"; case .immersive: return "沉浸"; case .brandInset: return "品牌内嵌"; case .brandGallery: return "品牌留白"; case .classicSignature: return "经典签名"; case .galleryMat: return "艺术装裱"; case .colorArchive: return "色彩档案"; case .filmGallery: return "胶片画廊"; case .filmEdge: return "胶片边框"
        }
    }
    private func fontName(_ value: PhotoFrameWatermarkFont) -> String {
        switch value { case .signature: return "流畅签名"; case .elegant: return "编辑衬线"; case .calligraphy: return "窄体铭牌"; case .simple: return "简约"; case .bold: return "醒目" }
    }
    private func positionName(_ value: PhotoFrameWatermarkPosition) -> String {
        switch value { case .auto: return "边框·随样式"; case .left: return "边框·左侧"; case .center: return "边框·居中"; case .right: return "边框·右侧"; case .photoTopLeft: return "图内·左上"; case .photoTopCenter: return "图内·中上"; case .photoTopRight: return "图内·右上"; case .photoCenter: return "图内·中央"; case .photoBottomLeft: return "图内·左下"; case .photoBottomCenter: return "图内·中下"; case .photoBottomRight: return "图内·右下" }
    }
    private func colorName(_ value: PhotoFrameWatermarkColor) -> String {
        switch value { case .adaptive: return "自适应"; case .white: return "暖白"; case .black: return "石墨"; case .gold: return "香槟金"; case .mistBlue: return "雾霾蓝"; case .roseGold: return "玫瑰棕" }
    }
    private func effectName(_ value: PhotoFrameWatermarkEffect) -> String {
        switch value { case .auto: return "智能"; case .none: return "默认"; case .shadow: return "阴影"; case .outline: return "描边" }
    }

}

private struct WorkbenchCard<Content: View>: View {
    let accent: Color
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 8) { content }
            .padding(8)
            .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(accent.opacity(0.30), lineWidth: 1.2))
    }
}

private enum LocalPhotoFilterCategory: String, CaseIterable, Identifiable {
    case all, favorites, landscape, portrait, monochrome, film, cinematic, color
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部"; case .favorites: return "收藏"; case .landscape: return "风景"; case .portrait: return "人像"
        case .monochrome: return "黑白"; case .film: return "胶片"; case .cinematic: return "电影感"; case .color: return "色彩"
        }
    }
}

private extension PhotoFilterPreset {
    var category: LocalPhotoFilterCategory {
        let value = name
        if value.range(of: "黑白|单色|Mono", options: [.regularExpression, .caseInsensitive]) != nil { return .monochrome }
        if value.range(of: "人像|Portrait|Skin|Love Glow|Warm Portrait|Soft Portrait", options: [.regularExpression, .caseInsensitive]) != nil { return .portrait }
        if value.range(of: "风景|Landscape|Nature|Forest|Fern|Moss|Urban Green|Blue Hour|Sunset", options: [.regularExpression, .caseInsensitive]) != nil { return .landscape }
        if value.range(of: "电影|Cine|Cinema|Teal and Orange|Dusk", options: [.regularExpression, .caseInsensitive]) != nil { return .cinematic }
        if value.range(of: "胶片|Film|Vintage|Darkroom", options: [.regularExpression, .caseInsensitive]) != nil { return .film }
        return .color
    }
}

private struct WorkbenchScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct WorkbenchScrollTracker: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: WorkbenchScrollOffsetKey.self,
                                   value: proxy.frame(in: .named("workbenchScroll")).minY)
        }
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
