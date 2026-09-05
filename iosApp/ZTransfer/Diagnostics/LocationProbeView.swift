#if DEBUG
import SwiftUI

struct LocationProbeView: View {
    @StateObject private var location = CameraLocationProvider()
    @State private var packetStatus = ""
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("开发诊断：定位 / GEO 编码").font(.headline)
            Text("仅验证手机定位和共享41字节编码；蓝牙认证及写入尚未连接。不会自动向相机发送位置。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("开启前台定位") { location.start(); packetStatus = "" }.disabled(location.running)
                Button("停止") { location.stop(); packetStatus = "" }.disabled(!location.running)
                Button("检查共享 GEO 编码") {
                    packetStatus = location.geoPayload().map { "已编码\($0.count)字节；未发送。" } ?? "尚无有效新鲜定位。"
                }.disabled(!location.running)
            }.font(.caption)
            Text(location.status).font(.caption)
            if let fix = location.latest {
                Text("\(fix.coordinate.latitude), \(fix.coordinate.longitude) · 精度\(fix.horizontalAccuracy)m").font(.caption)
            }
            if !packetStatus.isEmpty { Text(packetStatus).font(.caption) }
        }
        .onDisappear { location.stop() }
        .onChange(of: scenePhase) { if $0 == .background { location.stop() } }
    }
}
#endif
