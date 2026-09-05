import Foundation
import SwiftUI

struct ContentView: View {
    @ObservedObject private var appearance = AppAppearanceSettings.shared
    #if DEBUG
    @State private var showSharedComponents = false
    #endif
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("Z传")
                    .font(.largeTitle.bold())

                Text("iOS 共享工程已就绪")
                    .foregroundStyle(.secondary)

                Text("v\(version)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.tertiary)

                #if DEBUG
                Button("检查共享 Compose 组件") { showSharedComponents = true }
                    .sheet(isPresented: $showSharedComponents) {
                        NavigationStack {
                            SharedUiProbeView()
                                .toolbar { Button("关闭") { showSharedComponents = false } }
                        }
                    }
                Divider()
                CameraHandshakeProbeView()
                Divider()
                LocationProbeView()
                BluetoothProbeView()
                #endif
            }
            .padding(24)
        }
        .preferredColorScheme(appearance.colorScheme)
        .onAppear { appearance.start() }
    }
}

#Preview {
    ContentView()
}
