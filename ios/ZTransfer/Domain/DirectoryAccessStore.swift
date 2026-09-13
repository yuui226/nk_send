import Foundation
import SwiftUI
import UIKit

@MainActor
final class DirectoryAccessStore: ObservableObject {
    @Published private(set) var directoryURL: URL?
    private let defaults: UserDefaults
    private let bookmarkKey = "transferDirectoryBookmark"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restore()
    }

    func setDirectory(_ url: URL) {
        directoryURL?.stopAccessingSecurityScopedResource()
        guard url.startAccessingSecurityScopedResource() else { directoryURL = nil; return }
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
        ), url.startAccessingSecurityScopedResource() else { return }
        if stale, let refreshed = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil,
        ) { defaults.set(refreshed, forKey: bookmarkKey) }
        directoryURL = url
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
