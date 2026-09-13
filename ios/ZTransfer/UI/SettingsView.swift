import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject private var directory: DirectoryAccessStore
    @ObservedObject private var effectsStore: PhotoEffectsStore
    @State private var showingPicker = false
    @State private var feedbackHint = false
    @State private var showingEffectsEditor = false
    @State private var showingHelp = false
    @AppStorage("organizeTransfersByDate") private var organizeByDate = false
    @AppStorage("autoTransferNewMedia") private var autoTransfer = false
    @AppStorage("deferTransferStart") private var deferStart = false
    @AppStorage("thumbnailColumns") private var columns = 3
    @AppStorage("collapseBurstPhotos") private var collapseBurst = false
    @AppStorage("tapToPreview") private var tapToPreview = false
    @AppStorage("hapticsEnabled") private var haptics = true
    @AppStorage("keepScreenOn") private var keepScreenOn = true
    @AppStorage("themeMode") private var themeMode = "自动"
    @AppStorage("appLanguage") private var appLanguage = "system"
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
        .onAppear {
            // Migrate the early preview value ("自动") to the same BCP-47
            // tags used by Android so the selection actually changes the app
            // locale instead of only changing the wheel label.
            if !["system", "en", "zh-Hans", "zh-Hant"].contains(appLanguage) {
                appLanguage = "system"
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            // Keep the title in one line.  The Android title occupies a single
            // titleLarge slot; allowing SwiftUI to compress it produces the
            // two-character vertical title seen in the old iOS panel.
            Text("设置")
                .zTransferText(size: ZTransferMetrics.title, weight: .bold)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Button { showingHelp = true } label: {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ZTransferColors.accentOrange)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 12))
            Spacer()
            // iOS does not yet have the Android purchase backend. Keep the
            // same compact badge footprint without exposing a dead renewal
            // action in the settings header.
            Text("高级版")
                .zTransferTypography(.labelLarge, weight: .bold)
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(Color.yellow.opacity(0.75), in: Capsule())
            Button { onClose?() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(ZTransferColors.secondaryText)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
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
                Button { showingPicker = true } label: {
                    Text(directory.directoryURL == nil ? "选择目录" : "更改目录")
                        .zTransferText(size: ZTransferMetrics.caption, weight: .semibold)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                }
                .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 12))
            }
            SettingsDivider()
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
                DetentWheel(label: "每行数量", options: [2, 3, 4], selected: columns, optionLabel: String.init, onCommit: { columns = $0 }, rowHeight: 18, wheelHeight: 50).frame(maxWidth: .infinity)
                ToggleWheel(label: "连拍成组", isOn: $collapseBurst).frame(maxWidth: .infinity)
            }
            SettingsDivider()
                DetentWheel(label: "照片列表操作", options: [false, true], selected: tapToPreview, optionLabel: { $0 ? "点击：预览\n长按：传输" : "点击：传输\n长按：预览" }, onCommit: { tapToPreview = $0 }, rowHeight: 32, wheelHeight: 56, optionMaxLines: 2, optionFontSize: 13)
        }
    }

    private var appearanceCard: some View {
        SettingsCard {
            HStack(spacing: 8) {
                DetentWheel(label: "明暗", options: ["自动", "深色", "浅色"], selected: themeMode, optionLabel: { $0 }, onCommit: { themeMode = $0 }, rowHeight: 16, wheelHeight: 42, optionFontSize: 13).frame(maxWidth: .infinity)
                DetentWheel(label: "语言", options: ["system", "en", "zh-Hans", "zh-Hant"], selected: appLanguage, optionLabel: { language in
                    switch language {
                    case "en": return "English"
                    case "zh-Hans": return "简体中文"
                    case "zh-Hant": return "繁體中文"
                    default: return "自动"
                    }
                }, onCommit: { appLanguage = $0; onClose?() }, rowHeight: 16, wheelHeight: 42, optionFontSize: 13).frame(maxWidth: .infinity)
                DetentWheel(label: "按钮风格", options: ["毛玻璃", "木纹", "相机按键", "钛合金"], selected: skinPreset, optionLabel: { $0 }, onCommit: { skinPreset = $0 }, rowHeight: 16, wheelHeight: 42, optionFontSize: 13).frame(maxWidth: .infinity)
            }
            SettingsDivider()
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
        HStack(spacing: 8) {
            VersionPlaque(text: "Z传 v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.82")")
            Spacer()
            SettingsFooterButton("反馈") { UIPasteboard.general.string = "953000922"; feedbackHint = true }
        }
        .alert("已复制 QQ 号 953000922\n请加 QQ 反馈", isPresented: $feedbackHint) { Button("确定", role: .cancel) {} }
        .alert("设置说明\n按天保存、实时传输和选完再传需要先设置传输目录。照片列表和外观选项会在松手后生效。", isPresented: $showingHelp) { Button("确定", role: .cancel) {} }
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
    var body: some View {
        // Materialize the builder as one vertical group before applying the
        // surface. Without this wrapper SwiftUI can propagate the background
        // proposal to tuple children, making each divider look like a second
        // empty rounded card in the popup.
        VStack(spacing: 0) { content }
            .padding(12)
            .background(ZTransferGlassSurface(cornerRadius: 14, kind: .button))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(ZTransferColors.primaryText.opacity(0.10), lineWidth: 1))
    }
}

private struct ToggleWheel: View {
    let label: String
    @Binding var isOn: Bool
    var disabled = false
    var body: some View {
        DetentWheel(
            label: label,
            options: [false, true],
            selected: isOn,
            optionLabel: { $0 ? "开启" : "关闭" },
            onCommit: { isOn = $0 },
            rowHeight: 18,
            wheelHeight: 50,
            enabled: !disabled,
            accentColor: isOn ? ZTransferColors.accentBlue : ZTransferColors.secondaryText,
            emphasized: isOn,
        )
        .frame(maxWidth: .infinity)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .overlay(ZTransferColors.primaryText.opacity(0.10))
            .padding(.vertical, 8)
    }
}

private struct SettingsFooterButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }
    var body: some View {
        Button(action: action) {
            Text(title)
                .zTransferText(size: ZTransferMetrics.caption, weight: .semibold)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(ZTransferGlassSurface(cornerRadius: 12, kind: .button))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(ZTransferColors.primaryText.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct VersionPlaque: View {
    let text: String
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(ZTransferColors.secondaryText.opacity(0.42)).frame(width: 3, height: 3)
            Text(text).zTransferTypography(.labelSmall, weight: .medium)
                .foregroundStyle(ZTransferColors.secondaryText.opacity(0.82))
                .lineLimit(1)
            Circle().fill(ZTransferColors.secondaryText.opacity(0.42)).frame(width: 3, height: 3)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(ZTransferColors.primaryText.opacity(0.035), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(ZTransferColors.primaryText.opacity(0.10), lineWidth: 1))
    }
}
