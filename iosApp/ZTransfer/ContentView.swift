import Foundation
import SwiftUI

@MainActor
struct ContentView: View {
    @ObservedObject private var appearance = AppAppearanceSettings.shared
    @StateObject private var workspace = CameraWorkspaceBridge()
    #if DEBUG
    @State private var showDiagnostics = false
    @State private var showSharedComponents = false
    #endif

    var body: some View {
        CameraWorkspace(bridge: workspace)
            .preferredColorScheme(appearance.colorScheme)
            .onAppear { appearance.start() }
            #if DEBUG
            .overlay(alignment: .topTrailing) {
                Button("开发诊断") { showDiagnostics = true }
                    .font(.caption).padding(8).disabled(workspace.session.running)
            }
            .sheet(isPresented: $showDiagnostics) {
                NavigationStack {
                    ScrollView {
                        VStack(spacing: 16) {
                            Button("检查共享 Compose 组件") { showSharedComponents = true }
                            CameraHandshakeProbeView(probe: workspace.session)
                            Divider(); LocationProbeView(); BluetoothProbeView()
                        }.padding()
                    }
                    .toolbar { Button("关闭") { showDiagnostics = false } }
                }
                .sheet(isPresented: $showSharedComponents) { SharedUiProbeView() }
            }
            #endif
    }
}

#Preview { ContentView() }
