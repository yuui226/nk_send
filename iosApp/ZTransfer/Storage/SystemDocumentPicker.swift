import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Reusable native system UI, not a second product page. Export always copies the original;
/// destination URLs are results of the provider, not a promise of ongoing access or cloud upload.
struct SystemDocumentPicker: UIViewControllerRepresentable {
    enum Purpose { case exportCopy(URL), chooseDirectory }
    let purpose: Purpose
    let completion: ([URL]?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker: UIDocumentPickerViewController
        switch purpose {
        case .exportCopy(let url): picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        case .chooseDirectory: picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        }
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private var completion: (([URL]?) -> Void)?
        init(completion: @escaping ([URL]?) -> Void) { self.completion = completion }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(nil) }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finish(urls) }
        private func finish(_ urls: [URL]?) {
            let callback = completion; completion = nil
            callback?(urls)
        }
    }
}
