import XCTest
import SwiftUI
@testable import ZTransfer

@MainActor final class RemoteToolMarkAndPresetTests: XCTestCase {
    func testToolPaletteAndTintUseAndroid180msAndReleaseIdleClock() {
        XCTAssertEqual(RemoteToolPalette.mark(skin: .titanium, dark: false, active: true, fixed: false), 0xFF005B83)
        XCTAssertEqual(RemoteToolPalette.mark(skin: .wood, dark: true, active: false, fixed: true), 0xFFF1D6A7)
        XCTAssertEqual(RemoteToolPalette.mark(skin: .cameraControls, dark: false, active: false, fixed: true), 0xFFBDD1DD)
        let motion = RemoteToolTintMotion(0xFF6E6E73)
        motion.update(0xFF6E6E73); XCTAssertFalse(motion.clockRunning)
        motion.update(0xFF0277BD); motion.stop()
        motion.advance(0); motion.advance(90_000_000)
        XCTAssertNotEqual(motion.value, 0xFF6E6E73); XCTAssertNotEqual(motion.value, 0xFF0277BD)
        motion.advance(180_000_000)
        XCTAssertEqual(motion.value, 0xFF0277BD); XCTAssertFalse(motion.clockRunning)
        for _ in 0..<120 { motion.update(0xFF0277BD) }
        XCTAssertFalse(motion.clockRunning)
        weak var released: RemoteToolTintMotion?
        do { let active = RemoteToolTintMotion(0xFF000000); released = active; active.update(0xFFFFFFFF) }
        XCTAssertNil(released, "A changing tool tint must not keep its detached page alive")
    }
    func testFolderPickerKeepsTargetAcrossBackgroundAndCancellation() {
        var picker = PictureControlFolderPickerState()
        picker.begin(slot: 209)
        XCTAssertTrue(picker.active)
        picker.complete(folder: nil)
        XCTAssertNil(picker.consume(resumed: false)); XCTAssertTrue(picker.didReturn)
        let cancelled = picker.consume(resumed: true)
        XCTAssertEqual(cancelled?.slot, 209); XCTAssertNil(cancelled?.folder)
        XCTAssertFalse(picker.didReturn); XCTAssertFalse(picker.active)
        XCTAssertNil(picker.consume(resumed: true))
        picker.begin(slot: 203)
        let folder = URL(fileURLWithPath: "/example/NP3")
        picker.complete(folder: folder)
        let result = picker.consume(resumed: true)
        XCTAssertEqual(result?.slot, 203); XCTAssertEqual(result?.folder, folder)
        XCTAssertNil(picker.consume(resumed: true))
    }
    func testEveryPresetPageFitsPortraitAndLandscapeWithoutFullHeightPlaceholder() {
        for (host, anchor, landscape) in [(CGSize(width: 320, height: 568), CGRect(x: 265, y: 150, width: 36, height: 36), false),
                                         (CGSize(width: 700, height: 250), CGRect(x: 620, y: 200, width: 36, height: 36), true)] {
            let layout = RemotePictureControlLayout(overview: Self.overview, categories: [], category: "",
                hostSize: host, anchor: anchor, landscape: landscape, scale: 3)
            for page in [RemotePictureControlPage.slots, .init(slot: 201), .init(slot: 201, confirmation: .clear), .init(slot: 201, confirmation: .folder)] {
                let size = layout.size(for: page)
                let placement = RemoteCameraToolMenuPlacement(host: host, anchor: anchor, landscape: landscape,
                    width: size.width, contentHeight: size.height)
                XCTAssertGreaterThan(size.width, 0); XCTAssertGreaterThan(size.height, 0)
                XCTAssertLessThanOrEqual(placement.frame.maxX, host.width - 8)
                XCTAssertLessThanOrEqual(placement.frame.maxY, host.height)
                XCTAssertLessThanOrEqual(size.height, placement.availableHeight)
                if page.slot != nil { XCTAssertEqual(size.width, 260) }
                if landscape { XCTAssertTrue(placement.opensAbove); XCTAssertLessThanOrEqual(placement.frame.maxY, anchor.minY - 6) }
            }
        }
    }
    func testMaterialVectorsUseRealAndroidGeometryAndAllToolbarMarksRender() throws {
        let volume = RemoteEditorIcon(kind: .volumeUp).path(in: CGRect(x: 0, y: 0, width: 24, height: 24))
        XCTAssertTrue(volume.contains(CGPoint(x: 5, y: 12)))
        XCTAssertTrue(volume.contains(CGPoint(x: 11, y: 5)))
        XCTAssertFalse(volume.contains(CGPoint(x: 2, y: 12)))
        let aspect = RemoteEditorIcon(kind: .aspectRatio).path(in: CGRect(x: 0, y: 0, width: 24, height: 24))
        XCTAssertEqual(aspect.boundingRect.minX, 1, accuracy: 0.0001)
        XCTAssertEqual(aspect.boundingRect.maxX, 23, accuracy: 0.0001)
        XCTAssertEqual(aspect.boundingRect.minY, 3, accuracy: 0.0001)
        XCTAssertEqual(aspect.boundingRect.maxY, 21, accuracy: 0.0001)
        for tool in RemoteTool.allCases {
            let image = try render(RemoteToolMark(tool: tool).environment(\.remoteToolTint, .black)
                .frame(width: 36, height: 36).background(.white))
            XCTAssertGreaterThan(coloredPixels(image) { $0[0] < 210 && $0[1] < 210 && $0[2] < 210 }, 15, tool.rawValue)
        }
        let chart = VStack(spacing: 12) {
            ForEach(0..<4) { row in
                HStack(spacing: 10) {
                    ForEach(Array(RemoteTool.allCases.dropFirst(row * 5).prefix(5))) { tool in
                        VStack { RemoteToolMark(tool: tool, histogramRGB: true, waveformRGB: true,
                            falseColor: true, grid: .thirds, locked: true).frame(width: 36, height: 36)
                            Text(tool.rawValue).font(.system(size: 9)) }
                    }
                }
            }
        }.padding(20).environment(\.remoteToolTint, .black).background(.white)
        attach(try render(chart), "all-tools-rgb-false-color")
    }
    func testPresetKeepsFourSwatchesThroughMaterialTreatment() throws {
        for skin in [ZTransferButtonSkin.frostedGlass, .liquidGlass, .titanium, .wood, .cameraControls] {
            for scheme in [ColorScheme.light, .dark] {
                let label = RemotePictureControlGlyph().environment(\.remoteToolTint, scheme == .dark ? .white : .black)
                    .frame(width: 36, height: 36)
                let style = ZTransferGlassButtonStyle(preserveContentColors: true)
                // Exercise the production treatment path independently of the platform's
                // liquid-glass backdrop capture, which ImageRenderer cannot represent.
                let image = try render(style.iconContent(label, skin: skin).environment(\.colorScheme, scheme)
                    .padding(4).background(scheme == .dark ? Color.black : .white))
                for rgb in [[223,102,114], [210,154,50], [53,164,124], [57,143,209]] {
                    XCTAssertGreaterThan(coloredPixels(image) { p in
                        abs(Int(p[0])-rgb[0]) < 12 && abs(Int(p[1])-rgb[1]) < 12 && abs(Int(p[2])-rgb[2]) < 12
                    }, 2, "\(skin)/\(scheme)/\(rgb)")
                }
                attach(image, "preset-\(skin)-\(scheme)")
            }
        }
    }
    func testHistogramWaveformAndExposureActuallyChangeColoredPixels() throws {
        for tool in [RemoteTool.histogram, .waveform, .exposure] {
            let mono = try render(RemoteToolMark(tool: tool).environment(\.remoteToolTint, .black).padding(8).background(.white))
            let colored = try render(RemoteToolMark(tool: tool, histogramRGB: true, waveformRGB: true, falseColor: true)
                .environment(\.remoteToolTint, .black).padding(8).background(.white))
            let vivid: ([UInt8]) -> Bool = { Int($0.max() ?? 0) - Int($0.min() ?? 0) > 60 }
            XCTAssertEqual(coloredPixels(mono, matching: vivid), 0)
            XCTAssertGreaterThan(coloredPixels(colored, matching: vivid), 40, tool.rawValue)
        }
    }
    func testZebraRoundCapsAreNotClippedToTheNineteenPointCanvas() throws {
        let image = try render(RemoteToolMark(tool: .exposure).environment(\.remoteToolTint, .black)
            .padding(8).background(.white))
        let cg = try XCTUnwrap(image.cgImage)
        var data = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(data: &data, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let xs = stride(from: 0, to: data.count, by: 4).filter { data[$0] < 100 }.map { ($0 / 4) % cg.width }
        // Android's first/last diagonal plus round caps extend beyond the nominal
        // 19dp mark, while staying comfortably inside the 36dp button.
        XCTAssertLessThan(try XCTUnwrap(xs.min()), 8 * 3)
        XCTAssertGreaterThan(try XCTUnwrap(xs.max()), (8 + 19) * 3)
    }
    func testUserNP3EmptyFolderGuidanceHasMeasuredContentHeight() {
        for message in ["Choose a folder containing .np3 files; one level of subfolders is supported as categories.",
                        "选择含 .np3 文件的文件夹，支持一层子文件夹作为分类。", "No .np3 files found"] {
            let layout = RemotePictureControlLayout(overview: Self.overview, categories: [], category: "",
                hostSize: CGSize(width: 393, height: 700), anchor: nil, landscape: false, scale: 3,
                emptyMessage: message)
            let size = layout.size(for: .init(slot: 201))
            XCTAssertGreaterThan(size.height, 46, "The folder guidance must not collapse to a header-only popup")
            XCTAssertLessThan(size.height, 700)
            XCTAssertEqual(size.width, 260)
        }
    }
    func testPresetTransitionRetainsOutgoingPageAndWaitsForSizeAndAlpha() {
        let motion = RemotePictureControlMotion()
        motion.configure(page: .slots, size: CGSize(width: 180, height: 324), scale: 3)
        XCTAssertTrue(motion.settled); XCTAssertFalse(motion.clockRunning)
        let editor = RemotePictureControlPage(slot: 201)
        motion.configure(page: editor, size: CGSize(width: 260, height: 560), scale: 3)
        XCTAssertFalse(motion.settled); XCTAssertEqual(motion.outgoing, .slots)
        motion.stop() // deterministic manual frame clock
        motion.advance(0); motion.advance(40_000_000)
        XCTAssertEqual(motion.incomingOpacity, 0)
        XCTAssertGreaterThan(motion.outgoingOpacity, 0)
        motion.advance(140_000_000)
        XCTAssertEqual(motion.outgoingOpacity, 0)
        XCTAssertGreaterThan(motion.incomingOpacity, 0)
        XCTAssertLessThan(motion.incomingOpacity, 1)
        XCTAssertFalse(motion.settled)
        motion.advance(220_000_000)
        XCTAssertEqual(motion.incomingOpacity, 1)
        motion.advance(2_000_000_000)
        XCTAssertTrue(motion.settled); XCTAssertNil(motion.outgoing); XCTAssertFalse(motion.clockRunning)
        XCTAssertEqual(motion.size, CGSize(width: 260, height: 560))
        motion.configure(page: editor, size: CGSize(width: 260, height: 560), scale: 3)
        XCTAssertFalse(motion.clockRunning)
    }
    func testFastMutationCanReturnToSlotsWithoutDroppingEarlierExit() {
        let motion = RemotePictureControlMotion()
        defer { motion.stop() }
        let confirm = RemotePictureControlPage(slot: 201, confirmation: .clear)
        motion.configure(page: confirm, size: CGSize(width: 260, height: 200), scale: 3)
        motion.configure(page: .init(slot: 201), size: CGSize(width: 260, height: 500), scale: 3)
        motion.stop(); motion.advance(0); motion.advance(80_000_000)
        let previousAlpha = motion.exits.first?.opacity
        motion.configure(page: .slots, size: CGSize(width: 180, height: 324), scale: 3)
        motion.stop()
        XCTAssertEqual(Set(motion.exits.map(\.page)), [confirm, .init(slot: 201)])
        XCTAssertEqual(motion.exits.first { $0.page == confirm }?.opacity, previousAlpha)
        XCTAssertFalse(motion.settled)
        motion.advance(80_000_000); motion.advance(2_000_000_000)
        XCTAssertTrue(motion.settled); XCTAssertTrue(motion.exits.isEmpty)
        XCTAssertEqual(motion.page, .slots); XCTAssertEqual(motion.size, CGSize(width: 180, height: 324))
    }
    func testPresetOpeningCloseCannotLaterPresentOrWriteAndFolderOwnerSurvives() async throws {
        let entered = GateTestLatch(), release = GateTestLatch()
        var dismissed = 0, writes = 0
        let folders = PictureControlFolderState()
        let model = PictureControlPanelModel(folders: folders, current: { true }, allowed: { true }, busy: { _ in true },
            readOverview: { _ in await entered.signal(); await release.wait(); return Self.overview },
            change: { _,_,_ in writes += 1 }, closesFolders: false)
        defer { model.close(); folders.close() }
        model.dismiss = { dismissed += 1; model.close() }
        model.open(); model.open(); await entered.wait()
        model.requestClose(); model.requestClose()
        XCTAssertEqual(dismissed, 1); XCTAssertTrue(model.closeRequested)
        model.act(.activate(201)); await release.signal()
        for _ in 0..<40 { if !model.loading { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.overview); XCTAssertEqual(writes, 0)
        let replacement = PictureControlPanelModel(folders: folders, current: { true }, allowed: { true }, busy: { _ in true },
            readOverview: { _ in Self.overview }, change: { _,_,_ in }, closesFolders: false)
        await replacement.refresh()
        XCTAssertTrue(replacement.canEdit(Self.overview.slots[0])); replacement.close()
    }
    func testBackgroundPickerAndClosingGatesCannotAcceptMutations() async {
        var changes = 0, feedback = 0
        let model = PictureControlPanelModel(folders: PictureControlFolderState(), current: { true }, allowed: { true }, busy: { _ in true },
            readOverview: { _ in Self.overview }, change: { _,_,_ in changes += 1 })
        defer { model.close() }
        model.feedback = { feedback += 1 }
        await model.refresh()
        model.interactionAllowed = false
        model.act(.activate(201)); model.act(.clear(201))
        XCTAssertFalse(model.canEdit(Self.overview.slots[0]))
        XCTAssertEqual(changes, 0); XCTAssertEqual(feedback, 0)
        model.interactionAllowed = true; model.requestClose()
        model.act(.activate(201))
        XCTAssertEqual(changes, 0); XCTAssertFalse(model.canBrowse)
    }
    func testActualPresetPopupOpensAtContentSizeAndSwitchesInsideSameHost() async throws {
        let folders = PictureControlFolderState()
        let model = PictureControlPanelModel(folders: folders, current: { true }, allowed: { true }, busy: { _ in true },
            readOverview: { _ in Self.overview }, change: { _,_,_ in XCTFail("Rendering must never mutate the camera") })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 700)
        let host = UIHostingController(rootView: RemotePictureControlPanel(model: model, folders: folders,
            anchor: CGRect(x: 170, y: 80, width: 36, height: 36), hostSize: window.bounds.size, dismiss: {}, chooseFolder: { _ in XCTFail("Unexpected picker") })
            .background(Color.gray).environment(\.colorScheme, .light))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { model.close(); window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertNotNil(model.overview); XCTAssertFalse(model.loading)
        XCTAssertNil(host.presentedViewController, "Preset UI must stay in the anchored monitor host")
        let slotsImage = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        attach(slotsImage, "preset-slots-host")
        try assertSelectedRowReachesShellEdges(slotsImage)
        model.editingSlot = 201
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertNil(host.presentedViewController)
        attach(UIGraphicsImageRenderer(size: window.bounds.size).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }, "preset-editor-host")
        model.editingSlot = nil
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(model.loading)
        model.requestClose()
    }
    /// The camera overview and provider scan are deterministic inputs. The real
    /// production popup, folder owner, categories and transitions render here;
    /// this does not simulate a security-scoped grant or perform a camera write.
    func testActualUserNP3PopupKeepsFolderAndSlotAcrossCancellationAndEmptyRefresh() async throws {
        let suite = "user-np3-panel-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folderURL = URL(fileURLWithPath: "/user-np3-panel-test")
        let files = [
            PresetFile(identifier: "neutral", name: "User Neutral.NP3", relativePath: "User Neutral.NP3", size: 834),
            PresetFile(identifier: "film", name: "User Film.NP3", relativePath: "My Files/User Film.NP3", size: 834),
        ]
        let source = UserPictureControlPanelFiles(files)
        let folders = PictureControlFolderState(defaults: defaults, queue: PresetIOQueue(), scan: { _, _, ticket in
            try ticket.checkCancellation()
            return .init(bookmark: Data([1]), files: source.read(), root: folderURL)
        })
        let model = PictureControlPanelModel(folders: folders, current: { true }, allowed: { true }, busy: { _ in true },
            readOverview: { _ in Self.overview }, change: { _, _, _ in XCTFail("Browsing must not mutate the camera") })
        model.editingSlot = 209
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 700)
        let host = UIHostingController(rootView: RemotePictureControlPanel(model: model, folders: folders,
            anchor: CGRect(x: 170, y: 80, width: 36, height: 36), hostSize: window.bounds.size,
            dismiss: {}, chooseFolder: { _ in XCTFail("The system picker is outside this component test") })
            .background(Color.gray).environment(\.colorScheme, .light))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { model.close(); window.isHidden = true; window.rootViewController = nil }
        func screenshot(_ name: String) {
            window.layoutIfNeeded()
            attach(UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }, name)
        }
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertNotNil(model.overview)
        XCTAssertNil(folders.folder)
        XCTAssertTrue(folders.files.isEmpty)
        XCTAssertEqual(model.editingSlot, 209)
        screenshot("user-np3-01-no-folder-guidance")

        folders.changeFolder(folderURL)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while folders.scanning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(folders.scanning)
        XCTAssertEqual(folders.files, files)
        XCTAssertEqual(Set(folders.catalog.categories), Set([nil, "My Files"]))
        XCTAssertNil(folders.failure)
        try await Task.sleep(for: .milliseconds(700))
        screenshot("user-np3-02-user-folder-categories")

        var picker = PictureControlFolderPickerState()
        picker.begin(slot: 209)
        picker.complete(folder: nil)
        XCTAssertNil(picker.consume(resumed: false))
        let returned = try XCTUnwrap(picker.consume(resumed: true))
        XCTAssertNil(returned.folder)
        model.editingSlot = returned.slot
        XCTAssertEqual(model.editingSlot, 209)
        XCTAssertEqual(folders.folder, folderURL)
        XCTAssertEqual(folders.files, files)
        XCTAssertNil(host.presentedViewController)

        source.replace([])
        folders.refresh()
        let refreshDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while folders.scanning && ContinuousClock.now < refreshDeadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(folders.scanning)
        XCTAssertTrue(folders.files.isEmpty)
        XCTAssertTrue(folders.hasSnapshot)
        XCTAssertEqual(folders.folder, folderURL)
        XCTAssertEqual(model.editingSlot, 209)
        try await Task.sleep(for: .milliseconds(700))
        screenshot("user-np3-03-empty-folder-guidance")
        XCTAssertNil(model.pending)
    }

    private static var overview: PictureControlOverview {
        .init(slots: (201...209).map { .init(slot: $0, availability: $0 == 201 ? .occupied : .empty, name: $0 == 201 ? "Standard" : nil) },
              selected: 201, canActivate: true, canEdit: true)
    }
    private func render<V: View>(_ view: V) throws -> UIImage {
        let renderer = ImageRenderer(content: view); renderer.scale = 3
        return try XCTUnwrap(renderer.uiImage)
    }
    private func assertSelectedRowReachesShellEdges(_ image: UIImage) throws {
        let cg = try XCTUnwrap(image.cgImage)
        var data = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(data: &data, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        var rows: [(y: Int, left: Int, right: Int)] = []
        for y in 0..<cg.height {
            var left = cg.width, right = -1, matching = 0
            for x in 0..<cg.width {
                let i = (y * cg.width + x) * 4, r = Int(data[i]), g = Int(data[i+1]), b = Int(data[i+2])
                if r > 210 && g-r > 4 && b-r > 10 { left = min(left, x); right = max(right, x); matching += 1 }
            }
            // Segment the filled row; pale antialiasing on the blue log text is
            // the same color range but occupies only a handful of pixels.
            if matching > cg.width / 10 { rows.append((y, left, right)) }
        }
        XCTAssertGreaterThan(rows.count, 20)
        let row = try XCTUnwrap(rows.dropLast(4).last)
        XCTAssertLessThanOrEqual(row.left, try XCTUnwrap(rows.map(\.left).min()) + 2,
            "Android clips only the shell's top corners; the selected row bottom stays rectangular")
        XCTAssertGreaterThanOrEqual(row.right, try XCTUnwrap(rows.map(\.right).max()) - 2)
    }
    private func attach(_ image: UIImage, _ name: String) {
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func coloredPixels(_ image: UIImage, matching: ([UInt8]) -> Bool) -> Int {
        guard let cg = image.cgImage else { return 0 }
        var data = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = CGContext(data: &data, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return stride(from: 0, to: data.count, by: 4).reduce(0) { $0 + (matching(Array(data[$1..<$1+3])) ? 1 : 0) }
    }
}

/// A scanner snapshot, not a document read or fake security-scoped permission.
private final class UserPictureControlPanelFiles: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [PresetFile]
    init(_ files: [PresetFile]) { self.files = files }
    func read() -> [PresetFile] { lock.lock(); defer { lock.unlock() }; return files }
    func replace(_ files: [PresetFile]) { lock.lock(); defer { lock.unlock() }; self.files = files }
}
