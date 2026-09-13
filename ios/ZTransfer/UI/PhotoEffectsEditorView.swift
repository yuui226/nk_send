import SwiftUI

/// Android-equivalent draft editor.  All mutations stay in a local draft until
/// 完成; cancelling the sheet never changes the persisted effect configuration.
struct PhotoEffectsEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let initial: PhotoEffectsSettings
    let onSave: (PhotoEffectsSettings) -> Void
    @State private var draft: PhotoEffectsSettings

    init(initial: PhotoEffectsSettings, onSave: @escaping (PhotoEffectsSettings) -> Void) {
        self.initial = initial
        self.onSave = onSave
        _draft = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                PhotoEffectsControls(draft: $draft)
                .padding(.horizontal, ZTransferMetrics.pageHorizontal)
                .padding(.vertical, 12)
            }
            .background(ZTransferColors.background.ignoresSafeArea())
            .navigationTitle("滤镜·边框·水印")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { onSave(draft); dismiss() } }
            }
        }
    }
}

/// Shared controls for transfer settings and the inline local workbench. The
/// caller owns whether edits are a cancellable draft or immediately persisted.
struct PhotoEffectsControls: View {
    @Binding var draft: PhotoEffectsSettings
    var showLocationFields = true

    var body: some View {
        VStack(spacing: 10) {
            filterCard
            frameCard
            watermarkCard
            metadataCard
        }
    }

    private var filterCard: some View {
        EditorCard(title: "照片滤镜") {
            EffectToggle(label: "开启", isOn: binding(\.photoFilterEnabled))
            if draft.photoFilterEnabled {
                let ids: [String?] = [nil] + PhotoFilterCatalog.presets.map(\.id)
                DetentWheel(label: "照片滤镜", options: ids,
                            selected: draft.selectedFilter?.preset.id,
                            optionLabel: { id in
                                guard let id else { return "无滤镜" }
                                return PhotoFilterCatalog.presets.first { $0.id == id }?.name ?? "无滤镜"
                            }, onCommit: { id in
                                guard let id, let preset = PhotoFilterCatalog.presets.first(where: { $0.id == id }) else {
                                    draft.selectedFilter = nil
                                    draft.photoFilterEnabled = false
                                    return
                                }
                                draft.selectedFilter = PhotoFilterSelection(
                                    preset: preset,
                                    intensityPercent: draft.selectedFilter?.intensityPercent ?? 80
                                )
                            })
                DetentWheel(label: "滤镜强度", options: Array(stride(from: 100, through: 2, by: -2)),
                            selected: draft.selectedFilter?.intensityPercent ?? 80,
                            optionLabel: { "\($0)%" }, onCommit: { value in
                                guard let selected = draft.selectedFilter else { return }
                                draft.selectedFilter = PhotoFilterSelection(preset: selected.preset, intensityPercent: value)
                            }, rowHeight: 26, enabled: draft.selectedFilter != nil)
            }
        }
    }

    private var frameCard: some View {
        EditorCard(title: "边框和水印") {
            EffectToggle(label: "开启", isOn: binding(\.photoFrameEnabled))
            EffectToggle(label: "边框", isOn: binding(\.photoFrameBorderEnabled), enabled: draft.photoFrameEnabled)
            if draft.photoFrameEnabled {
                DetentWheel(label: "边框", options: PhotoFramePreset.allCases,
                            selected: draft.photoFramePreset,
                            optionLabel: { frameName($0) }, onCommit: { draft.photoFramePreset = $0 }, rowHeight: 28)
            }
        }
    }

    private var watermarkCard: some View {
        EditorCard(title: "水印") {
            EffectToggle(label: "开启", isOn: binding(\.watermark.enabled), enabled: draft.photoFrameEnabled)
            TextField("水印文字", text: Binding(get: { draft.watermark.text }, set: { draft.watermark.text = String($0.prefix(PhotoFrameWatermark.maxTextLength)) }))
                .textFieldStyle(.plain)
                .padding(.horizontal, 12).frame(height: 42)
                .background(ZTransferColors.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                .disabled(!draft.photoFrameEnabled || !draft.watermark.enabled)
            DetentWheel(label: "字体", options: PhotoFrameWatermarkFont.allCases, selected: draft.watermark.font,
                        optionLabel: fontName, onCommit: { draft.watermark.font = $0 }, rowHeight: 28,
                        enabled: draft.photoFrameEnabled && draft.watermark.enabled)
            DetentWheel(label: "大小", options: Array(stride(from: 100, through: 1, by: -1)), selected: min(max(draft.watermark.sizePercent, 1), 100),
                        optionLabel: { "\($0)%" }, onCommit: { draft.watermark.sizePercent = $0 }, rowHeight: 26,
                        enabled: draft.photoFrameEnabled && draft.watermark.enabled)
            DetentWheel(label: "位置", options: PhotoFrameWatermarkPosition.allCases, selected: draft.watermark.position,
                        optionLabel: positionName, onCommit: { draft.watermark.position = $0 }, rowHeight: 28,
                        enabled: draft.photoFrameEnabled && draft.watermark.enabled)
            DetentWheel(label: "颜色", options: PhotoFrameWatermarkColor.allCases, selected: draft.watermark.color,
                        optionLabel: colorName, onCommit: { draft.watermark.color = $0 }, rowHeight: 28,
                        enabled: draft.photoFrameEnabled && draft.watermark.enabled)
            DetentWheel(label: "透明度", options: Array(stride(from: 100, through: 1, by: -1)), selected: min(max(draft.watermark.opacityPercent, 1), 100),
                        optionLabel: { "\($0)%" }, onCommit: { draft.watermark.opacityPercent = $0 }, rowHeight: 26,
                        enabled: draft.photoFrameEnabled && draft.watermark.enabled)
            DetentWheel(label: "可读性", options: PhotoFrameWatermarkEffect.allCases, selected: draft.watermark.effect,
                        optionLabel: effectName, onCommit: { draft.watermark.effect = $0 }, rowHeight: 28,
                        enabled: draft.photoFrameEnabled && draft.watermark.enabled)
        }
    }

    private var metadataCard: some View {
        EditorCard(title: "曝光信息") {
            EffectToggle(label: "日期格式", isOn: binding(\.metadata.showDate))
            EffectToggle(label: "时间格式", isOn: binding(\.metadata.showTime))
            EffectToggle(label: "焦距", isOn: binding(\.metadata.showFocalLength))
            EffectToggle(label: "曝光参数", isOn: binding(\.metadata.showExposure))
            EffectToggle(label: "品牌", isOn: binding(\.metadata.showBrand))
            EffectToggle(label: "型号", isOn: binding(\.metadata.showModel))
            EffectToggle(label: "镜头型号", isOn: binding(\.metadata.showLensModel))
            if showLocationFields {
                EffectToggle(label: "经纬度", isOn: binding(\.metadata.showCoordinates))
                EffectToggle(label: "海拔", isOn: binding(\.metadata.showAltitude))
            }
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<PhotoEffectsSettings, T>) -> Binding<T> {
        Binding(get: { draft[keyPath: keyPath] }, set: { draft[keyPath: keyPath] = $0 })
    }
    private func frameName(_ value: PhotoFramePreset) -> String {
        switch value {
        case .mist: return "雾白"; case .cinema: return "暗夜"; case .minimal: return "简白"; case .frosted: return "毛玻璃"
        case .plaque: return "铭牌"; case .immersive: return "沉浸"; case .brandInset: return "品牌内嵌"; case .brandGallery: return "品牌留白"
        case .classicSignature: return "经典签名"; case .galleryMat: return "艺术装裱"; case .colorArchive: return "色彩档案"; case .filmGallery: return "胶片画廊"; case .filmEdge: return "胶片边框"
        }
    }
    private func fontName(_ value: PhotoFrameWatermarkFont) -> String {
        switch value { case .signature: return "流畅签名"; case .elegant: return "编辑衬线"; case .calligraphy: return "窄体铭牌"; case .simple: return "简约"; case .bold: return "醒目" }
    }
    private func positionName(_ value: PhotoFrameWatermarkPosition) -> String {
        switch value {
        case .auto: return "边框·随样式"; case .left: return "边框·左侧"; case .center: return "边框·居中"; case .right: return "边框·右侧"
        case .photoTopLeft: return "图内·左上"; case .photoTopCenter: return "图内·中上"; case .photoTopRight: return "图内·右上"; case .photoCenter: return "图内·中央"
        case .photoBottomLeft: return "图内·左下"; case .photoBottomCenter: return "图内·中下"; case .photoBottomRight: return "图内·右下"
        }
    }
    private func colorName(_ value: PhotoFrameWatermarkColor) -> String {
        switch value { case .adaptive: return "自适应"; case .white: return "暖白"; case .black: return "石墨"; case .gold: return "香槟金"; case .mistBlue: return "雾霾蓝"; case .roseGold: return "玫瑰棕" }
    }
    private func effectName(_ value: PhotoFrameWatermarkEffect) -> String {
        switch value { case .auto: return "智能"; case .none: return "默认"; case .shadow: return "阴影"; case .outline: return "描边" }
    }
}

private struct EditorCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).zTransferText(size: ZTransferMetrics.body, weight: .semibold)
            Divider().opacity(0.35)
            content
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.55), lineWidth: 1))
    }
}

private struct EffectToggle: View {
    let label: String
    @Binding var isOn: Bool
    var enabled = true
    var body: some View {
        Button { if enabled { isOn.toggle() } } label: {
            HStack {
                Text(label).zTransferText(size: ZTransferMetrics.body)
                Spacer()
                Text(isOn ? "开启" : "关闭").zTransferText(size: ZTransferMetrics.caption, weight: .semibold)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? ZTransferColors.accentBlue : ZTransferColors.secondaryText)
            }
            .frame(minHeight: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}
