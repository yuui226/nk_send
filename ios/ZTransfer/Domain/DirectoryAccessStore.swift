import Foundation
import SwiftUI
import UIKit

@MainActor
final class DirectoryAccessStore: ObservableObject {
    @Published private(set) var directoryURL: URL?
    private let defaults: UserDefaults
    // Android persists this setting under ztransfer/transfer_dir.  The value
    // is platform-specific (bookmark bytes on iOS, URI text on Android), but
    // the preference identity remains identical.
    private let bookmarkKey = "transfer_dir"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restore()
    }

    func setDirectory(_ url: URL) {
        directoryURL?.stopAccessingSecurityScopedResource()
        guard url.startAccessingSecurityScopedResource() else {
            directoryURL = nil
            defaults.removeObject(forKey: bookmarkKey)
            return
        }
        do {
            let bookmark = try url.bookmarkData(
                // iOS document-provider URLs carry their security scope in the
                // bookmark; the macOS-only withSecurityScope creation option is
                // unavailable on iOS.
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil,
            )
            defaults.set(bookmark, forKey: bookmarkKey)
            directoryURL = url
        } catch {
            url.stopAccessingSecurityScopedResource()
            directoryURL = nil
            defaults.removeObject(forKey: bookmarkKey)
        }
    }

    func clear() {
        directoryURL?.stopAccessingSecurityScopedResource()
        directoryURL = nil
        defaults.removeObject(forKey: bookmarkKey)
    }

    private func restore() {
        guard let data = defaults.data(forKey: bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale,
        ), url.startAccessingSecurityScopedResource() else {
            defaults.removeObject(forKey: bookmarkKey)
            return
        }
        if stale, let refreshed = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil,
        ) { defaults.set(refreshed, forKey: bookmarkKey) }
        directoryURL = url
        // Android sweeps stale transfer/frame parts while restoring the saved
        // directory. Keep the filesystem work off the main actor.
        Task.detached(priority: .utility) {
            _ = TransferDirectoryIndex.removeStaleTemporaryFiles(in: url)
        }
    }
}

struct DirectoryPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { if let url = urls.first { onPick(url) } }
    }
}
