import XCTest
import SwiftUI
@testable import ZTransfer

@MainActor
final class QueueSummaryLayoutTests: XCTestCase {
    func testSuccessColorFramesReuseFilenameFitUntilGeometryChanges() throws {
        let label = TransferFileTitleLabel(frame: CGRect(x: 0, y: 0, width: 120, height: 20))
        let name = "A_LONG_CAMERA_FILENAME_123456789.JPG"
        label.configure(name: name, primary: .black, secondary: .gray)
        label.layoutIfNeeded()
        let initial = try XCTUnwrap(label.attributedText?.string)
        let count = label.fittingCount
        let naturalWidth = label.fullWidth
        XCTAssertTrue(initial.contains("…"))
        for frame in 1...30 {
            let color = UIColor(red: 0, green: CGFloat(frame) / 30, blue: 0, alpha: 1)
            label.configure(name: name, primary: color, secondary: color)
            label.layoutIfNeeded()
            XCTAssertEqual(label.attributedText?.string, initial)
            XCTAssertEqual(label.fullWidth, naturalWidth)
            XCTAssertEqual(label.attributedText?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor, color)
        }
        XCTAssertEqual(label.fittingCount, count, "Color animation must not repeat filename truncation")
        label.frame.size.width = 600
        label.setNeedsLayout(); label.layoutIfNeeded()
        XCTAssertEqual(label.attributedText?.string, name)
        XCTAssertEqual(label.fittingCount, count + 1)
        label.configure(name: name, primary: .green, secondary: .green, fontSize: 18)
        label.layoutIfNeeded()
        XCTAssertGreaterThan(label.fullWidth, naturalWidth)
        XCTAssertEqual(label.fittingCount, count + 2)
        label.configure(name: "SHORT.NEF", primary: .green, secondary: .green, fontSize: 18,
                        accessibilityName: "Original camera filename")
        label.layoutIfNeeded()
        XCTAssertEqual(label.attributedText?.string, "SHORT.NEF")
        XCTAssertLessThan(label.fullWidth, naturalWidth)
        XCTAssertEqual(label.accessibilityLabel, "Original camera filename")
    }

    @MainActor private final class Source: ObservableObject {
        @Published var items: [TransferQueueItem] = []
        @Published var transferring = false
        let progress = TransferQueueProgressViewModel()
    }
    private struct Host: View {
        @ObservedObject var source: Source
        let width: CGFloat
        let compact: Bool
        var body: some View {
            VStack(spacing: 16) {
                TransferQueueStatusGroup(presentation: .init(items: source.items, isTransferring: source.transferring),
                    tasks: source.items, progress: source.progress, width: width - 24, compact: compact)
                Spacer()
            }.padding(12).background(ZTransferColors.background).frame(width: width)
        }
    }
    private func task(_ id: UInt32, generating: Bool = false) -> TransferQueueItem {
        var item = TransferQueueItem(attemptOrder: UInt64(id), id: UUID(),
            file: CameraFile(id: id, storageID: 1, format: 0x3801, size: 28_343_091,
                fileName: "DSC_\(String(format: "%04d", id)).JPG", captureDate: nil, isProtected: false),
            status: generating ? .completed : .transferring)
        item.isGeneratingFrame = generating; item.progress = 0.35
        item.bytesPerSecond = 35 * 1024 * 1024
        if generating { item.frameGenerationStartedAtElapsedMs = PhotoGenerationClock.now() }
        return item
    }
    private func descendants<T: UIView>(_ view: UIView, _ type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type) }
    }
    private func host(_ source: Source, width: CGFloat, dark: Bool = false) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        addTeardownBlock { @MainActor in previous?.makeKeyAndVisible() }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 320)
        let root = Host(source: source, width: width, compact: true)
            .environment(\.colorScheme, dark ? .dark : .light).environment(\.scenePhase, .active)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible(); window.layoutIfNeeded()
        return window
    }
    private func capture(_ window: UIWindow, name: String) throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
            window.layer.render(in: context.cgContext)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("queue-summary-\(name).png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("QUEUE_SUMMARY_IMAGE \(url.path)")
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testActualCardsStayEqualHeightAcrossIdleBusyAndCompletedOnNarrowAndWideScreens() async throws {
        for (width, dark) in [(CGFloat(320), false), (CGFloat(600), true)] {
            let source = Source(), window = try host(source, width: width, dark: dark)
            defer { window.isHidden = true; window.rootViewController = nil }
            try await Task.sleep(for: .milliseconds(250))
            var surfaces = descendants(window, QueueSummarySurfaceView.self)
            XCTAssertEqual(surfaces.count, 2)
            let initial = surfaces.map { $0.convert($0.bounds, to: window) }.sorted { $0.minX < $1.minX }
            XCTAssertEqual(initial[0].height, initial[1].height, accuracy: 0.5)
            XCTAssertEqual(initial[1].minX - initial[0].maxX, 8, accuracy: 0.5)
            XCTAssertEqual(initial[1].maxX, width - 12, accuracy: 0.5)
            try capture(window, name: "\(Int(width))-idle")
            source.items = [task(1, generating: true), task(2, generating: true), task(3)]
            source.transferring = true
            let busyDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while descendants(window, TransferFileTitleLabel.self).count != 3, ContinuousClock.now < busyDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try await Task.sleep(for: .milliseconds(300))
            surfaces = descendants(window, QueueSummarySurfaceView.self)
            XCTAssertEqual(surfaces.map { $0.convert($0.bounds, to: window) }.sorted { $0.minX < $1.minX }, initial)
            let titles = descendants(window, TransferFileTitleLabel.self)
            XCTAssertEqual(titles.count, 3)
            for title in titles {
                let rect = title.convert(title.bounds, to: window)
                XCTAssertGreaterThan(rect.width, 20)
                XCTAssertLessThanOrEqual(rect.maxX, width - 12)
                XCTAssertNotNil(title.attributedText)
            }
            try capture(window, name: "\(Int(width))-busy")
            source.items = source.items.map { item in
                var done = item; done.status = .completed; done.isGeneratingFrame = false
                done.frameGenerationElapsedMs = item.isGeneratingFrame ? 1500 : nil
                done.frameGenerationStartedAtElapsedMs = nil; return done
            }
            source.transferring = false
            let idleDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !descendants(window, TransferFileTitleLabel.self).isEmpty, ContinuousClock.now < idleDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(descendants(window, TransferFileTitleLabel.self).isEmpty)
            XCTAssertEqual(descendants(window, QueueSummarySurfaceView.self).map { $0.convert($0.bounds, to: window) }.sorted { $0.minX < $1.minX }, initial)
        }
    }

    func testProductionQueueKeepsSummaryAboveHistoryOnPortraitAndCompactLayouts() async throws {
        let suite = "summary-page-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("en", forKey: "app_language")
        defer { defaults.removePersistentDomain(forName: suite) }
        for size in [CGSize(width: 390, height: 800), CGSize(width: 600, height: 320)] {
            let queue = TransferQueue(defaults: UserDefaults(suiteName: suite)!, premiumAccess: PremiumAccess(.lifetime))
            let model = TransferQueueViewModel(queue: queue)
            let directory = DirectoryAccessStore(defaults: defaults)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = UIHostingController(rootView: TransferQueueView(model: model, session: nil,
                directory: directory, showsTopControls: false, onNavigateBack: {})
                .environment(\.scenePhase, .active).environment(\.colorScheme, .light).defaultAppStorage(defaults))
            window.makeKeyAndVisible(); window.layoutIfNeeded()
            defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
            try await Task.sleep(for: .milliseconds(300))
            let bounds = descendants(window, QueueSummarySurfaceView.self).map { $0.convert($0.bounds, to: window) }.sorted { $0.minX < $1.minX }
            XCTAssertEqual(bounds.count, 2)
            if let first = bounds.first { XCTAssertGreaterThanOrEqual(first.minY, 64) }
            try capture(window, name: "page-\(Int(size.width))-empty")
            await queue.enqueue(task(3).file)
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while model.snapshot.items.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertEqual(model.snapshot.items.count, 1)
            XCTAssertEqual(descendants(window, QueueSummarySurfaceView.self).map { $0.convert($0.bounds, to: window) }.sorted { $0.minX < $1.minX }, bounds)
            try capture(window, name: "page-\(Int(size.width))-waiting")
        }
    }

    func testRunningLeafClocksDoNotRebuildSummaryGroupAndUnmountStopsAmbientAnimation() async throws {
        let source = Source(); source.items = [task(1, generating: true), task(2)]; source.transferring = true
        var renders = 0
        QueueSummaryRenderProbe.onRender = { if $0 == "group" { renders += 1 } }
        defer { QueueSummaryRenderProbe.onRender = nil }
        let window = try host(source, width: 390)
        try await Task.sleep(for: .milliseconds(350))
        let settled = renders
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(renders, settled, "200ms generation clocks and liquid/activity animation stay below the structural group")
        let surfaces = descendants(window, QueueSummarySurfaceView.self)
        func repeating(_ layer: CALayer) -> Int {
            (layer.animationKeys() ?? []).filter { layer.animation(forKey: $0)?.repeatCount == .infinity }.count +
                (layer.sublayers ?? []).reduce(0) { $0 + repeating($1) }
        }
        XCTAssertEqual(surfaces.reduce(0) { $0 + repeating($1.layer) }, 1)
        window.isHidden = true; window.rootViewController = nil
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(surfaces.reduce(0) { $0 + repeating($1.layer) }, 0)
    }
}

extension QueueSummaryLayoutTests {
    func testLastGenerationBadgeDoesNotExpandDepartingRowsAndNewWorkKeepsTheSlot() async throws {
        let source = Source(), item = task(1, generating: true)
        source.items = [item]
        let window = try host(source, width: 390)
        try await Task.sleep(for: .milliseconds(400)); window.layoutIfNeeded()
        let title = try XCTUnwrap(descendants(window, TransferFileTitleLabel.self).first)
        let before = title.convert(title.bounds, to: window)
        var done = item; done.isGeneratingFrame = false; done.frameGenerationElapsedMs = 500
        done.frameGenerationStartedAtElapsedMs = nil; source.items = [done]
        let end = ContinuousClock.now.advanced(by: .milliseconds(170))
        var samples = 0
        while ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(10)); window.layoutIfNeeded()
            for label in descendants(window, TransferFileTitleLabel.self) {
                XCTAssertEqual(label.bounds.width, before.width, accuracy: 0.5, "Zero count must not release badge width while the last row remains")
                samples += 1
            }
        }
        XCTAssertGreaterThan(samples, 0)
        try capture(window, name: "generation-last-hold")
        let next = task(2, generating: true); source.items = [done, next]
        try await Task.sleep(for: .milliseconds(450)); window.layoutIfNeeded()
        let nextTitle = try XCTUnwrap(descendants(window, TransferFileTitleLabel.self).first)
        XCTAssertEqual(nextTitle.bounds.width, before.width, accuracy: 0.5)
        try capture(window, name: "generation-reentry")
    }
}
