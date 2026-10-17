import SwiftUI
import UniformTypeIdentifiers

struct PhotoLUTChooser: View {
    @ObservedObject var store: PhotoLUTStore
    var onDisable: () -> Void
    var onSelect: (PhotoFilterSelection) -> Void = { _ in }
    var onIntensity: (Int) -> Void = { _ in }
    var onAdjustments: (LUTAdjustments) -> Void = { _ in }
    @StateObject private var request = LUTRequestController()
    @State private var showingFolder = false
    @State private var showingChooser = false
    @State private var folderAfterChooser = false
    @State private var folderFailure: String?
    @State private var files: [RemoteLUTFile] = []
    @State private var categorySelection = PhotoLUTCategorySelection()
    @State private var access = RemoteLUTFolderAccess(scope: .photo)
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(AppLocalized.resource("photo_effect_module_lut")).font(.headline); Spacer(); Button(AppLocalized.resource(store.folderBookmark == nil ? "lut_choose_folder" : "lut_change_folder")) { cancelPending(); showingFolder = true } }
            Button(AppLocalized.resource("lut_off")) { cancelPending(); onDisable() }
            if request.loading { ProgressView() }
            if let folderFailure { Text(AppLocalized.resource(folderFailure)).foregroundStyle(.secondary) }
            if files.isEmpty && folderFailure == nil {
                Text(AppLocalized.resource(RemoteLUTCatalog.photoFolderStatus(
                    hasFolder: store.folderBookmark != nil, loading: request.loading, failure: nil)))
                    .foregroundStyle(.secondary).font(.footnote)
            }
            DetentWheel(label: "LUT", options: selectionOptions,
                        selected: request.pendingIdentifier ?? store.selectedIdentifier,
                        optionLabel: { identifier in
                            guard let identifier else {
                                return selectionOptions.count == 1
                                    ? AppLocalized.resource(RemoteLUTCatalog.photoFolderStatus(
                                        hasFolder: store.folderBookmark != nil,
                                        loading: request.loading, failure: folderFailure))
                                    : AppLocalized.resource("lut_off")
                            }
                            return RemoteLUTCatalog.labels(files, uncategorized: AppLocalized.resource("lut_uncategorized"))[identifier]
                                ?? store.selectedName ?? AppLocalized.resource("lut_off")
                        }, onCommit: { identifier in
                            guard let identifier else { cancelPending(); onDisable(); return }
                            if let file = files.first(where: { $0.identifier == identifier }) { choose(file) }
                        }, rowHeight: 30, readOnly: request.loading, optionMaxLines: 2,
                        onActivated: selectionOptions.count == 1 ? {
                            cancelPending(); showingFolder = true
                        } : nil,
                        onLongClick: { openChooser() })
            if store.selectedIdentifier != nil {
                PhotoLUTParameterControl(label: AppLocalized.resource("photo_lut_concentration"),
                                         value: store.intensityPercent, range: 2...100, step: 2, suffix: "%") {
                    guard !request.loading else { return }
                    store.setIntensity($0)
                    onIntensity(store.intensityPercent)
                }.id(store.selectedIdentifier).disabled(request.loading)

                adjustmentControl("photo_lut_contrast", keyPath: \.contrast)
                adjustmentControl("photo_lut_saturation", keyPath: \.saturation)
                adjustmentControl("photo_lut_highlights", keyPath: \.highlights)
                adjustmentControl("photo_lut_shadows", keyPath: \.shadows)
            }
        }
        .fileImporter(isPresented: $showingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { scanFolder(nil); return }
            scanFolder(url)
        }
        .sheet(isPresented: $showingChooser, onDismiss: {
            if folderAfterChooser { folderAfterChooser = false; showingFolder = true }
        }) {
            VStack(spacing: 12) {
                HStack {
                    Button(AppLocalized.resource("lut_turn_off")) {
                        cancelPending(); onDisable(); showingChooser = false
                    }
                    Spacer()
                    Button(AppLocalized.resource("lut_folder")) {
                        cancelPending()
                        folderAfterChooser = true; showingChooser = false
                    }
                }
                if request.loading { ProgressView() }
                if let folderFailure { Text(AppLocalized.resource(folderFailure)) }
                if files.isEmpty && folderFailure == nil {
                    Text(AppLocalized.resource(RemoteLUTCatalog.photoFolderStatus(
                        hasFolder: store.folderBookmark != nil, loading: request.loading, failure: nil)))
                }
                categoryBrowser
            }.padding()
        }
        .onAppear { scanFolder(nil) }
        .onDisappear { cancelPending() }
        .onChange(of: files) { value in
            categorySelection.reconcile(files: value, selected: store.selectedIdentifier)
        }
        .onChange(of: store.selectedIdentifier) { value in
            categorySelection.reconcile(files: files, selected: value)
        }
    }

    private var selectionOptions: [String?] {
        var values: [String?] = [nil] + store.ordered(files).map { Optional($0.identifier) }
        // A restored private snapshot remains selectable until a successful
        // directory scan proves its original source was removed.
        if let selected = store.selectedIdentifier, !values.contains(selected) { values.append(selected) }
        return values
    }

    private func openChooser() {
        categorySelection = PhotoLUTCategorySelection()
        categorySelection.reconcile(files: files, selected: store.selectedIdentifier)
        showingChooser = true
        scanFolder(nil)
    }

    private var categoryBrowser: some View {
        let labels = RemoteLUTCatalog.labels(files, uncategorized: AppLocalized.resource("lut_uncategorized"))
        let categories = PhotoLUTCategorySelection.categories(in: files)
        let visible = store.ordered(files).filter { $0.category == categorySelection.category }
        return VStack {
            if categories.count > 1 {
                Picker("", selection: $categorySelection.category) {
                    ForEach(categories, id: \.self) { category in
                        Text(category ?? AppLocalized.resource("lut_uncategorized")).tag(category)
                    }
                }.labelsHidden().pickerStyle(.menu)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        ForEach(visible, id: \.identifier) { file in
                            HStack {
                                Button {
                                    choose(file); showingChooser = false
                                } label: { Text(labels[file.identifier] ?? file.label).lineLimit(2) }
                                Spacer()
                                Button { store.toggleFavorite(file.identifier) } label: {
                                    Image(systemName: store.favorites.contains(file.identifier) ? "star.fill" : "star")
                                }
                                if store.selectedIdentifier == file.identifier { Image(systemName: "checkmark.circle.fill") }
                            }.id(file.identifier)
                        }
                    }
                }
                .onAppear { scrollToCurrent(proxy, visible: visible) }
                .onChange(of: categorySelection.category) { _ in scrollToCurrent(proxy, visible: visible) }
            }.id(categorySelection.category)
        }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy, visible: [RemoteLUTFile]) {
        let target = visible.first { $0.identifier == store.selectedIdentifier } ?? visible.first
        if let target { proxy.scrollTo(target.identifier, anchor: .top) }
    }

    private func cancelPending() {
        request.cancel()
    }

    private func scanFolder(_ replacement: URL?) {
        let bookmark = access.bookmarkData
        if replacement == nil && bookmark == nil {
            cancelPending()
            files = []
            folderFailure = nil
            return
        }
        request.submit(action: { ticket in
            if let replacement {
                let previous = RemoteLUTFolderAccess.resolveBookmark(bookmark)
                let prepared = try RemoteLUTFolderAccess.prepareFolder(replacement, checkCancelled: ticket.checkCancellation)
                return (prepared, previous)
            }
            return (try RemoteLUTFolderAccess.prepareBookmark(bookmark, checkCancelled: ticket.checkCancellation), nil as URL?)
        }, onTimeout: {
            folderFailure = "lut_read_timeout"
        }, deliver: { result in
            switch result {
            case .success(let (prepared, previous)):
                access.commit(prepared)
                store.setFolderBookmark(access.bookmarkData)
                files = prepared.files
                folderFailure = nil
                if (replacement != nil && previous != replacement)
                    || !files.contains(where: { $0.identifier == store.selectedIdentifier }) { onDisable() }
            case .failure(let error):
                folderFailure = folderMessage(error)
                if replacement == nil, let failure = error as? RemoteLUTFolderAccessError,
                   failure == .missing || failure == .denied {
                    files = []
                    onDisable()
                }
            }
        })
    }

    private func folderMessage(_ error: Error) -> String {
        switch error as? RemoteLUTFolderAccessError {
        case .missing: return "lut_folder_missing"
        case .denied: return "lut_folder_denied"
        case .tooMany: return "lut_folder_too_many"
        default: return "lut_folder_read_failed"
        }
    }

    private func adjustmentControl(_ label: String, keyPath: WritableKeyPath<LUTAdjustments, Int>) -> some View {
        PhotoLUTParameterControl(label: AppLocalized.resource(label),
                                 value: store.adjustments[keyPath: keyPath], range: -100...100, step: 5) {
            guard !request.loading else { return }
            var value = store.adjustments
            value[keyPath: keyPath] = $0
            store.setAdjustments(value)
            onAdjustments(store.adjustments)
        }.id(store.selectedIdentifier).disabled(request.loading)
    }

    private func choose(_ file: RemoteLUTFile) {
        let bookmark = access.bookmarkData
        let directory = store.snapshotDirectory
        request.submit(selectionIdentifier: file.identifier, action: { ticket in
            let lut = try RemoteLUTFolderAccess.parseBookmark(bookmark, file: file,
                                                              checkCancelled: ticket.checkCancellation)
            return try PhotoLUTStore.prepareSelection(lut, directory: directory,
                                                      checkCancelled: ticket.checkCancellation)
        }, onTimeout: {
            folderFailure = "lut_read_timeout"
        }, deliver: { result in
            switch result {
            case .success(let prepared):
                let selection = store.acceptSelection(prepared, name: file.label.isEmpty ? file.name : file.label, sourceIdentifier: file.identifier)
                folderFailure = nil
                onSelect(selection)
            case .failure(let error):
                switch error as? CubeLUTFailure {
                case .invalid: folderFailure = "lut_invalid"
                case .unsupported: folderFailure = "lut_unsupported"
                case .tooLarge: folderFailure = "lut_too_large"
                default: folderFailure = "lut_read_failed"
                }
            }
        })
    }
}


// Android ReleaseCommitWheel: preview while tracking, commit once on release,
// discard a cancelled gesture. UIKit exposes cancellation separately from release.
private struct PhotoLUTParameterControl: View {
    let label: String
    let value: Int
    let range: ClosedRange<Int>
    let step: Int
    var suffix = ""
    let commit: (Int) -> Void
    @State private var preview: Int?

    var body: some View {
        HStack {
            Text(label)
            PhotoLUTReleaseSlider(value: value, range: range, step: step,
                                  label: label, preview: { preview = $0 }, commit: commit)
            Text("\(preview ?? value)\(suffix)").monospacedDigit()
        }
        .onChange(of: value) { _ in preview = nil }
    }
}

struct PhotoLUTReleaseSlider: UIViewRepresentable {
    let value: Int
    let range: ClosedRange<Int>
    let step: Int
    let label: String
    let preview: (Int?) -> Void
    let commit: (Int) -> Void

    func makeUIView(context: Context) -> ReleaseSlider {
        let slider = ReleaseSlider()
        slider.addTarget(slider, action: #selector(ReleaseSlider.changed), for: .valueChanged)
        return slider
    }

    func updateUIView(_ slider: ReleaseSlider, context: Context) {
        if slider.isEnabled && !context.environment.isEnabled {
            slider.cancelTracking(with: nil)
        }
        slider.isEnabled = context.environment.isEnabled
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        slider.step = step
        slider.savedValue = value
        slider.preview = preview
        slider.commit = commit
        slider.accessibilityLabel = label
        if !slider.isTracking { slider.value = Float(value) }
    }

    final class ReleaseSlider: UISlider {
        var step = 1
        var savedValue = 0
        var preview: (Int?) -> Void = { _ in }
        var commit: (Int) -> Void = { _ in }
        private var snapped: Int {
            let offset = (value - minimumValue) / Float(step)
            return min(Int(maximumValue), max(Int(minimumValue),
                Int(minimumValue) + Int(offset.rounded()) * step))
        }
        @objc func changed() { preview(snapped) }

        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            super.endTracking(touch, with: event)
            guard isEnabled else { return }
            let result = snapped
            preview(nil)
            commitIfChanged(result)
        }

        override func cancelTracking(with event: UIEvent?) {
            super.cancelTracking(with: event)
            value = Float(savedValue)
            preview(nil)
        }

        override func accessibilityIncrement() { adjust(step) }
        override func accessibilityDecrement() { adjust(-step) }
        private func adjust(_ delta: Int) {
            guard isEnabled else { return }
            value = Float(min(Int(maximumValue), max(Int(minimumValue), savedValue + delta)))
            commitIfChanged(snapped)
        }

        private func commitIfChanged(_ result: Int) {
            guard result != savedValue else { return }
            // Advance synchronously: repeated input may precede SwiftUI's next update.
            savedValue = result
            value = Float(result)
            commit(result)
        }
    }
}
