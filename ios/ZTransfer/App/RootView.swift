import SwiftUI

struct RootView: View {
    @StateObject private var connectionModel = ConnectionViewModel()
    @StateObject private var effectsStore = PhotoEffectsStore()
    @StateObject private var gpsCoordinator = GPSCoordinator()
    @StateObject private var directoryStore = DirectoryAccessStore()
    @State private var transferQueue = TransferQueue()
    @AppStorage("themeMode") private var themeMode = "自动"
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
