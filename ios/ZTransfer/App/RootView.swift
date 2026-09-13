import SwiftUI

enum AppLocalized {
    static func text(_ value: String) -> String {
        let tag = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        let language: String
        if tag == "en" || (tag == "system" && Locale.current.language.languageCode?.identifier == "en") {
            language = "en"
        } else if tag == "zh-Hant" || (tag == "system" && Locale.current.language.script?.identifier == "Hant") {
            language = "zh-Hant"
        } else {
            language = "zh-Hans"
        }
        guard language != "zh-Hans" else { return value }
        let en: [String: String] = [
            "设置":"Settings", "传输目录":"Transfer folder", "未设置":"Not set", "未命名文件夹":"Untitled folder", "选择目录":"Choose folder", "更改目录":"Change folder", "按天保存":"Save by day", "实时传输":"Auto transfer", "选完再传":"Transfer after selection", "每行数量":"Items per row", "连拍成组":"Group bursts", "照片列表操作":"Photo list actions", "明暗":"Light & dark", "语言":"Language", "按钮风格":"Button style", "自动":"Auto", "深色":"Dark", "浅色":"Light", "毛玻璃":"Frosted Glass", "木纹":"Wood", "相机按键":"Camera Buttons", "钛合金":"Titanium", "开启":"On", "关闭":"Off", "触感反馈":"Haptic feedback", "屏幕常亮":"Keep screen on", "滤镜·边框·水印":"Filters · Frames · Watermarks", "照片滤镜":"Photo filter", "无滤镜":"No filter", "边框和水印":"Frame and watermark", "反馈":"Feedback", "确定":"OK", "点击：传输\n长按：预览":"Tap: transfer\nHold: preview", "点击：预览\n长按：传输":"Tap: preview\nHold: transfer"
        ]
        let hant: [String: String] = [
            "设置":"設定", "传输目录":"傳輸目錄", "未设置":"未設定", "未命名文件夹":"未命名資料夾", "选择目录":"選擇目錄", "更改目录":"變更目錄", "按天保存":"按天保存", "实时传输":"即時傳輸", "选完再传":"選完再傳", "每行数量":"每行數量", "连拍成组":"連拍成組", "照片列表操作":"照片列表操作", "明暗":"明暗", "语言":"語言", "按钮风格":"按鈕風格", "自动":"自動", "深色":"深色", "浅色":"淺色", "毛玻璃":"毛玻璃", "木纹":"木紋", "相机按键":"相機按鍵", "钛合金":"鈦合金", "开启":"開啟", "关闭":"關閉", "触感反馈":"觸覺回饋", "屏幕常亮":"保持螢幕開啟", "滤镜·边框·水印":"濾鏡·邊框·水印", "照片滤镜":"照片濾鏡", "无滤镜":"無濾鏡", "边框和水印":"邊框和水印", "反馈":"回饋", "确定":"確定", "点击：传输\n长按：预览":"點擊：傳輸\n長按：預覽", "点击：预览\n长按：传输":"點擊：預覽\n長按：傳輸"
        ]
        return (language == "en" ? en : hant)[value] ?? value
    }
}

struct RootView: View {
    @StateObject private var connectionModel = ConnectionViewModel()
    @StateObject private var effectsStore = PhotoEffectsStore()
    @StateObject private var gpsCoordinator = GPSCoordinator()
    @StateObject private var directoryStore = DirectoryAccessStore()
    @State private var transferQueue = TransferQueue()
    @AppStorage("themeMode") private var themeMode = "自动"
    @AppStorage("appLanguage") private var appLanguage = "system"

    private var locale: Locale {
        switch appLanguage {
        case "en": return Locale(identifier: "en")
        case "zh-Hans": return Locale(identifier: "zh-Hans")
        case "zh-Hant": return Locale(identifier: "zh-Hant")
        default: return .current
        }
    }
    var body: some View {
        Group {
            if let session = connectionModel.cameraSession {
                PhotoListView(session: session, queue: transferQueue, directory: directoryStore) {
                    Task { await connectionModel.disconnectCamera() }
                }
            } else {
                HomeWorkspacePagerIOS(connection: connectionModel, effectsStore: effectsStore, gpsCoordinator: gpsCoordinator, directory: directoryStore)
            }
        }
        .preferredColorScheme(themeMode == "深色" ? .dark : themeMode == "浅色" ? .light : nil)
        .environment(\.locale, locale)
        .task {
            connectionModel.startUSBDiscovery()
            connectionModel.startWiFiDiscovery()
        }
        .onDisappear {
            connectionModel.stopUSBDiscovery()
            connectionModel.stopWiFiDiscovery()
        }
    }
}


/// Android HomeWorkspacePager equivalent. The workbench is the page below the
/// connection page; it is never presented as a sheet or a modal route.
private struct HomeWorkspacePagerIOS: View {
    @ObservedObject var connection: ConnectionViewModel
    let effectsStore: PhotoEffectsStore
    @ObservedObject var gpsCoordinator: GPSCoordinator
    let directory: DirectoryAccessStore
    @State private var page = 0

    var body: some View {
        GeometryReader { proxy in
            TabView(selection: $page) {
                ConnectionPage(model: connection, effectsStore: effectsStore, gpsCoordinator: gpsCoordinator, directory: directory, onOpenWorkspace: {
                    withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.88)) { page = 1 }
                })
                    .rotationEffect(.degrees(-90))
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .tag(0)
                LocalPhotoEffectsView(onNavigateUp: {
                    withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.88)) { page = 0 }
                })
                    .rotationEffect(.degrees(-90))
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .tag(1)
            }
            .rotationEffect(.degrees(90))
            .frame(width: proxy.size.height, height: proxy.size.width)
            .offset(x: (proxy.size.width - proxy.size.height) / 2, y: (proxy.size.height - proxy.size.width) / 2)
            .background(ZTransferColors.background)
            .tabViewStyle(.page(indexDisplayMode: .never))
            .indexViewStyle(.page(backgroundDisplayMode: .never))
        }
        .background(ZTransferColors.background.ignoresSafeArea())
    }
}
