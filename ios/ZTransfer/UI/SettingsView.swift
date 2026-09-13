import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject private var directory: DirectoryAccessStore
    @ObservedObject private var effectsStore: PhotoEffectsStore
    @State private var showingPicker = false
    @State private var feedbackHint = false
    @State private var showingEffectsEditor = false
    @AppStorage("organizeTransfersByDate") private var organizeByDate = false
    @AppStorage("autoTransferNewMedia") private var autoTransfer = false
    @AppStorage("deferTransferStart") private var deferStart = false
    @AppStorage("thumbnailColumns") private var columns = 3
    @AppStorage("collapseBurstPhotos") private var collapseBurst = false
    @AppStorage("tapToPreview") private var tapToPreview = false
    @AppStorage("hapticsEnabled") private var haptics = true
    @AppStorage("keepScreenOn") private var keepScreenOn = true
    @AppStorage("themeMode") private var themeMode = "自动"
    @AppStorage("appLanguage") private var appLanguage = "自动"
    @AppStorage("skinPreset") private var skinPreset = "毛玻璃"

    var showPhotoEffectsEntry: Bool = true
    var onClose: (() -> Void)? = nil

    init(showPhotoEffectsEntry: Bool = true, effectsStore: PhotoEffectsStore = PhotoEffectsStore(), directory: DirectoryAccessStore = DirectoryAccessStore(), onClose: (() -> Void)? = nil) {
        self.showPhotoEffectsEntry = showPhotoEffectsEntry
        self.onClose = onClose
        _effectsStore = ObservedObject(wrappedValue: effectsStore)
        _directory = ObservedObject(wrappedValue: directory)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 10) {
                    directoryCard
                    listCard
                    if showPhotoEffectsEntry { photoEffectsCard }
                    appearanceCard
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
        .background(ZTransferGlassSurface(cornerRadius: 26, kind: .connection))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(ZTransferColors.primaryText.opacity(0.16), lineWidth: 1))
        .sheet(isPresented: $showingPicker) { DirectoryPicker { url in directory.setDirectory(url); showingPicker = false } }
        .sheet(isPresented: $showingEffectsEditor) {
            PhotoEffectsEditorView(initial: effectsStore.settings) { effectsStore.update($0); showingEffectsEditor = false }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("设置").zTransferText(size: 28, weight: .bold)
            Button { feedbackHint = true } label: {
                Image(systemName: "lightbulb.fill").font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ZTransferColors.accentOrange)
            }.buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 18)).frame(width: 48, height: 48)
            Spacer()
            Button("续费") { }.buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 20)).frame(width: 58, height: 40)
            Text("高级版").zTransferTypography(.labelLarge, weight: .bold)
                .foregroundStyle(.black).frame(width: 82, height: 40)
                .background(Color.yellow.opacity(0.75), in: Capsule())
            Button { onClose?() } label: {
                Image(systemName: "xmark").font(.system(size: 25, weight: .medium))
                    .foregroundStyle(ZTransferColors.secondaryText)
            }.buttonStyle(.plain).frame(width: 48, height: 48)
        }
        .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 10)
    }

    private var directoryCard: some View {
        SettingsCard {
            HStack(spacing: 10) {
                Image(systemName: "location.fill").foregroundStyle(directory.directoryURL == nil ? ZTransferColors.accentOrange : .green)
                VStack(alignment: .leading, spacing: 3) {
                    Text("传输目录").zTransferText(size: ZTransferMetrics.caption, weight: .semibold)
                    Text(directory.directoryURL?.lastPathComponent ?? "未设置").zTransferText(size: ZTransferMetrics.caption).lineLimit(1)
                }
                Spacer()
                Button(directory.directoryURL == nil ? "选择目录" : "更改目录") { showingPicker = true }.buttonStyle(.bordered)
            }
            Divider().opacity(0.35)
            HStack(spacing: 8) {
                ToggleWheel(label: "按天保存", isOn: $organizeByDate, disabled: directory.directoryURL == nil)
                ToggleWheel(label: "实时传输", isOn: $autoTransfer, disabled: directory.directoryURL == nil)
                ToggleWheel(label: "选完再传", isOn: $deferStart, disabled: directory.directoryURL == nil)
            }
        }
    }

    private var listCard: some View {
        SettingsCard {
            HStack(spacing: 8) {
                DetentWheel(label: "每行数量", options: [2, 3, 4, 5], selected: columns, optionLabel: String.init, onCommit: { columns = $0 }, rowHeight: 30).frame(maxWidth: .infinity)
                ToggleWheel(label: "连拍成组", isOn: $collapseBurst).frame(maxWidth: .infinity)
            }
            Divider().opacity(0.35)
            DetentWheel(label: "照片列表操作", options: [false, true], selected: tapToPreview, optionLabel: { $0 ? "点击：预览\n长按：传输" : "点击：传输\n长按：预览" }, onCommit: { tapToPreview = $0 }, rowHeight: 32)
        }
    }

    private var appearanceCard: some View {
        SettingsCard {
            HStack(spacing: 8) {
                DetentWheel(label: "明暗", options: ["自动", "深色", "浅色"], selected: themeMode, optionLabel: { $0 }, onCommit: { themeMode = $0 }, rowHeight: 30)
                DetentWheel(label: "语言", options: ["自动", "English", "简体中文", "繁體中文"], selected: appLanguage, optionLabel: { $0 }, onCommit: { appLanguage = $0 }, rowHeight: 30)
                DetentWheel(label: "按钮风格", options: ["毛玻璃", "木纹", "相机按键", "钛合金"], selected: skinPreset, optionLabel: { $0 }, onCommit: { skinPreset = $0 }, rowHeight: 30)
            }
            Divider().opacity(0.35)
            HStack(spacing: 8) { ToggleWheel(label: "触感反馈", isOn: $haptics); ToggleWheel(label: "屏幕常亮", isOn: $keepScreenOn) }
        }
    }

    @ViewBuilder
    private var photoEffectsCard: some View {
        let settings = effectsStore.settings
        let filterSummary: String = {
            guard settings.photoFilterEnabled, let selection = settings.selectedFilter else {
                return "无滤镜"
            }
            return "\(selection.preset.name)\n强度 \(selection.intensityPercent)%"
        }()
        let frameSummary = settings.photoFrameEnabled && settings.photoFrameBorderEnabled
            ? settings.photoFramePreset.displayName : "关闭"
        let watermarkSummary: String = {
            guard settings.photoFrameEnabled, settings.watermark.enabled else { return "无水印" }
            switch settings.watermark.content {
            case .text: return settings.watermark.displayText
            case .image: return "Logo"
            }
        }()
        Button { showingEffectsEditor = true } label: {
            SettingsCard {
                HStack { Text("滤镜·边框·水印").zTransferText(size: ZTransferMetrics.body, weight: .semibold); Spacer(); Image(systemName: "chevron.right").foregroundStyle(ZTransferColors.secondaryText) }
                Divider().opacity(0.35)
                HStack(spacing: 8) {
                    Text("照片滤镜").zTransferText(size: ZTransferMetrics.caption, weight: .semibold)
                    Text(filterSummary).zTransferText(size: ZTransferMetrics.caption).multilineTextAlignment(.leading)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("边框和水印").zTransferText(size: ZTransferMetrics.caption, weight: .semibold)
                        Text("边框：\(frameSummary)").zTransferText(size: ZTransferMetrics.caption)
                        Text("水印：\(watermarkSummary)").zTransferText(size: ZTransferMetrics.caption)
                    }
                }
            }
        }.buttonStyle(.plain)
    }

    private var footer: some View {
        HStack {
            Text("Z传 v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.82")").zTransferTypography(.labelSmall, weight: .semibold)
            Spacer()
            Button("检查更新") { }
            Button("我要换机") { }
            Button("反馈") { UIPasteboard.general.string = "953000922"; feedbackHint = true }
        }
        .font(.system(size: ZTransferMetrics.caption, weight: .semibold))
        .alert("已复制 QQ 号 953000922\n请加 QQ 反馈", isPresented: $feedbackHint) { Button("确定", role: .cancel) {} }
    }
}

extension PhotoFramePreset {
    var displayName: String {
        switch self {
        case .mist: return "雾白"; case .cinema: return "暗夜"; case .minimal: return "简白"; case .frosted: return "毛玻璃"; case .plaque: return "铭牌"; case .immersive: return "沉浸"; case .brandInset: return "品牌内嵌"; case .brandGallery: return "品牌留白"; case .classicSignature: return "经典签名"; case .galleryMat: return "艺术装裱"; case .colorArchive: return "色彩档案"; case .filmGallery: return "胶片画廊"; case .filmEdge: return "胶片边框"
        }
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View { content.padding(16).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.55), lineWidth: 1)) }
}

private struct ToggleWheel: View {
    let label: String
    @Binding var isOn: Bool
    var disabled = false
    var body: some View {
        Button { isOn.toggle() } label: {
            VStack(spacing: 6) { Text(label).zTransferText(size: ZTransferMetrics.caption, weight: .semibold); Text(isOn ? "开启" : "关闭").zTransferText(size: ZTransferMetrics.body, weight: .semibold) }
                .frame(maxWidth: .infinity).frame(height: 92).background((isOn ? ZTransferColors.accentBlue : Color.black).opacity(isOn ? 0.10 : 0.035), in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.45 : 1)
    }
}
