#if DEBUG
import SwiftUI
import UIKit
import ZTransferShared

struct SharedPhotoProbeRequest: Identifiable {
    let id = UUID()
    let png: Data
    let title: String
}

/// Development-only entry to the original shared single-photo component, with a frozen actual image.
struct SharedPhotoProbeView: UIViewControllerRepresentable {
    let request: SharedPhotoProbeRequest
    @Environment(\.dismiss) private var dismiss
    func makeUIViewController(context: Context) -> UIViewController {
        if let controller = SharedUiController.shared.singlePhotoPreview(data: request.png as NSData,
            title: request.title, rotationDescription: "Rotate photo", onBack: { dismiss(); return KotlinUnit() }) {
            return controller
        }
        let controller = UIViewController()
        let label = UILabel()
        label.text = "无法显示这张预览，请关闭后重试。"
        label.textAlignment = .center; label.numberOfLines = 0
        label.frame = controller.view.bounds; label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(label)
        return controller
    }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

struct SharedUiProbeView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { SharedUiController.shared.componentProbe() }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
#endif
