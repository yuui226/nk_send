#if DEBUG
import SwiftUI

struct BluetoothProbeView: View {
    @State private var generation = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("开发诊断：GPS 蓝牙传输层").font(.headline)
            Text("仅扫描、连接和订阅 Nikon GPS 服务；不发送配对、控制器身份或坐标。GATT 就绪不等于 GPS 已认证。")
                .font(.caption).foregroundStyle(.secondary)
            BluetoothProbeSessionView().id(generation)
            Button("重置诊断连接") { generation = UUID() }.font(.caption)
        }
    }
}

private struct BluetoothProbeSessionView: View {
    @StateObject private var connection = NikonGpsGattConnection(driver: AppleNikonGpsGattDriver())
    @State private var error = ""
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("扫描 Nikon GPS") { attempt { try connection.scan() } }.disabled(connection.phase != .idle)
                Button("停止扫描") { connection.stopScan() }
                    .disabled(connection.phase != .starting && connection.phase != .scanning)
                Button("断开") { connection.close() }
            }.font(.caption)
            Text("蓝牙阶段：\(connection.phase.rawValue)").font(.caption)
            if let failure = connection.failure { Text("连接失败：\(String(describing: failure))").font(.caption) }
            if !error.isEmpty { Text(error).font(.caption) }
            ForEach(connection.candidates) { candidate in
                Button("\(candidate.name) · \(candidate.rssi) dBm") { attempt { try connection.connect(candidate.id) } }
                    .disabled(connection.phase != .scanning && connection.phase != .selecting)
                    .font(.caption)
            }
        }
        .onDisappear { connection.close() }
        .onChange(of: scenePhase) { if $0 == .background { connection.close() } }
    }
    private func attempt(_ operation: () throws -> Void) {
        do { try operation(); error = "" } catch { self.error = String(describing: error) }
    }
}
#endif
