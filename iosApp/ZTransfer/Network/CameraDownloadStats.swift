import Foundation

struct CameraDownloadProgress: Sendable {
    let downloaded: Int64
    let total: Int64
    let bytesPerSecond: Int64
}

struct CameraDownloadStats {
    let bytes: Int64
    let transferred: Int64
    let elapsed: TimeInterval
    let bytesPerSecond: Int64
}

enum CameraDownloadError: Error, LocalizedError {
    case resumeUnavailable, rejected(Int32), incomplete(received: Int64, expected: Int64)
    var errorDescription: String? {
        switch self {
        case .resumeUnavailable: return "当前相机读取方式无法续传，需要从头重新下载。"
        case .rejected(let code): return String(format: "相机拒绝下载，响应 0x%04X。", code)
        case .incomplete(let received, let expected): return "相机数据不完整：收到 \(received) 字节，预期 \(expected) 字节。"
        }
    }
}
