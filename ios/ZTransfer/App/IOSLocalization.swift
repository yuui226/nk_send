import Foundation

/// iOS-only copy that must not be written into AndroidLocalization.swift,
/// which is regenerated from Android resources. Platform-specific permission
/// guidance and setup steps live here so regeneration cannot remove them.
enum IOSLocalization {
    static let byResource: [String: [String: String]] = [
        "usb_permission_required": [
            "zh": "未获得相机访问权限，请到系统设置允许访问",
            "en": "Camera access was not granted. Allow access in Settings.",
            "hant": "未取得相機存取權限，請到系統設定允許存取",
        ],
        "usb_step_mode": [
            "zh": "相机 USB 设置选择 MTP/PTP",
            "en": "Set the camera USB mode to MTP/PTP",
            "hant": "相機 USB 設定選擇 MTP/PTP",
        ],
        "usb_step_cable": [
            "zh": "使用 USB 数据线连接；Lightning iPhone 需相机转接器",
            "en": "Connect with a USB data cable; Lightning iPhones require a camera adapter",
            "hant": "使用 USB 資料線連接；Lightning iPhone 需相機轉接器",
        ],
    ]
}
