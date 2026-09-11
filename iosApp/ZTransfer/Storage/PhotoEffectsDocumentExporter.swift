import SwiftUI
import UIKit

/// Batch Files export. The system owns the provider copy and returns only the URLs it accepted;
/// no success is inferred from presenting the picker.
struct PhotoEffectsDocumentExporter: UIViewControllerRepresentable {
    let files: [URL]
    let completion: ([URL]?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: files, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private var completion: (([URL]?) -> Void)?

        init(completion: @escaping ([URL]?) -> Void) { self.completion = completion }

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
    let files: [URL]
    let completion: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: files, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in completion() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
