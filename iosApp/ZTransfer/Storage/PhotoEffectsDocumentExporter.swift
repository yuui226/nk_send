import SwiftUI
import UIKit

/// Batch Files export. The system owns the provider copy and returns only the URLs it accepted;
/// no success is inferred from presenting the picker.
struct PhotoEffectsDocumentExporter: UIViewControllerRepresentable {
    let files: [PhotoEffectsRenderedFile]
    let completion: ([URL]?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(files: files, completion: completion) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: context.coordinator.files.map(\.url), asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let files: [PhotoEffectsRenderedFile]
        private var completion: (([URL]?) -> Void)?

        init(files: [PhotoEffectsRenderedFile], completion: @escaping ([URL]?) -> Void) {
            self.files = files; self.completion = completion
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(nil) }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(urls)
        }

        private func finish(_ urls: [URL]?) {
            let callback = completion
            completion = nil
            callback?(urls)
        }
    }
}

struct PhotoEffectsShareSheet: UIViewControllerRepresentable {
    let files: [PhotoEffectsRenderedFile]
    let completion: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(files: files, completion: completion) }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let coordinator = context.coordinator
        let controller = UIActivityViewController(activityItems: coordinator.files.map(\.url), applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in coordinator.finish() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}

    final class Coordinator {
        let files: [PhotoEffectsRenderedFile]
        private var completion: (() -> Void)?
        init(files: [PhotoEffectsRenderedFile], completion: @escaping () -> Void) {
            self.files = files; self.completion = completion
        }
        func finish() {
            let callback = completion
            completion = nil
            callback?()
        }
    }
}
