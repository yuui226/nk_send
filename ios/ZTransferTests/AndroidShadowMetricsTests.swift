import XCTest
import Metal
import MetalKit
import UIKit
@testable import ZTransfer

@MainActor
final class AndroidShadowPerformanceTests: XCTestCase {
    func testSharedAncestorSnapshotsAreLinearAndStableFramesDoNotChange() {
        let root = CALayer()
        var parent = root
        for _ in 0..<20 {
            let child = CALayer(); parent.addSublayer(child); parent = child
        }
        let leaves = (0..<100).map { _ in CALayer() }
        for leaf in leaves { parent.addSublayer(leaf) }
        let cache = AndroidShadowGeometryCache()
        cache.beginFrame()
        for leaf in leaves { XCTAssertTrue(cache.changed(leaf, relativeTo: root, presentation: false)) }
        XCTAssertEqual(cache.sampledLayerCount, 121)
        for _ in 0..<120 {
            cache.beginFrame()
            for leaf in leaves { XCTAssertFalse(cache.changed(leaf, relativeTo: root, presentation: false)) }
            XCTAssertEqual(cache.sampledLayerCount, 121, "Shared ancestors are sampled once, not 21 times per shadow")
        }
        parent.bounds.origin.y = 30 // UIScrollView-style ancestor movement.
        cache.beginFrame()
        for leaf in leaves { XCTAssertTrue(cache.changed(leaf, relativeTo: root, presentation: false)) }
        cache.beginFrame()
        for leaf in leaves { XCTAssertFalse(cache.changed(leaf, relativeTo: root, presentation: false)) }
        leaves[0].position.x = 12
        cache.beginFrame()
        XCTAssertTrue(cache.changed(leaves[0], relativeTo: root, presentation: false))
        for leaf in leaves.dropFirst() { XCTAssertFalse(cache.changed(leaf, relativeTo: root, presentation: false)) }
    }

    func testSnapshotInvalidatesForReparentTransformsVisibilityAndModelPresentationSwitch() {
        let root = CALayer(), first = CALayer(), second = CALayer(), leaf = CALayer()
        root.addSublayer(first); root.addSublayer(second); first.addSublayer(leaf)
        let cache = AndroidShadowGeometryCache()
        func frame(_ presentation: Bool = false) -> Bool {
            cache.beginFrame()
            return cache.changed(leaf, relativeTo: root, presentation: presentation)
        }
        XCTAssertTrue(frame()); XCTAssertFalse(frame())
        let mutations: [() -> Void] = [
            { first.isHidden = true }, { first.isHidden = false },
            { first.transform = CATransform3DMakeScale(0.8, 0.7, 1) },
            { first.sublayerTransform = CATransform3DMakeTranslation(3, 4, 0) },
            { leaf.anchorPoint = CGPoint(x: 0.2, y: 0.3) },
            { leaf.anchorPointZ = 3 }, { leaf.zPosition = 2 },
            { first.isGeometryFlipped = true },
            { var matrix = first.transform; matrix.m34 = -0.01; first.transform = matrix },
            { second.addSublayer(leaf) }, { leaf.bounds.size = CGSize(width: 40, height: 30) }
        ]
        for mutate in mutations { mutate(); XCTAssertTrue(frame()); XCTAssertFalse(frame()) }
        XCTAssertTrue(frame(true)); XCTAssertFalse(frame(true))
        XCTAssertTrue(frame(false), "Switching away from presentation geometry must validate again")
    }

    func testCacheDoesNotRetainLayersAndWindowSnapshotIsSharedOnlyWithinFrame() {
        let cache = AndroidShadowGeometryCache()
        weak var released: CALayer?
        autoreleasepool {
            let layer = CALayer()
            released = layer
            cache.beginFrame()
            XCTAssertTrue(cache.changed(layer, relativeTo: layer, presentation: false))
        }
        XCTAssertNil(released)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        cache.beginFrame()
        let first = cache.window(window).geometry
        for _ in 0..<120 { XCTAssertEqual(cache.window(window).geometry, first) }
        XCTAssertEqual(cache.sampledWindowCount, 1)
        cache.endFrame()
        XCTAssertEqual(cache.sampledWindowCount, 0)
        cache.clear()
        XCTAssertEqual(cache.sampledLayerCount, 0)
    }

    func testMountedShadowSkipsIdleConversionsButStillFollowsAncestorAnimationAndConfiguration() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        let controller = UIViewController()
        window.rootViewController = controller; window.isHidden = false
        defer { window.isHidden = true }
        let parent = UIView(frame: CGRect(x: 20, y: 80, width: 300, height: 120))
        controller.view.addSubview(parent)
        let host = AndroidShadowHost()
        host.frame = CGRect(x: 10, y: 10, width: 180, height: 48)
        host.cornerRadius = 18; host.elevation = 6
        parent.addSubview(host); host.layoutIfNeeded()
        let metal = try XCTUnwrap(host.subviews.compactMap { $0 as? MTKView }.first)
        try await Task.sleep(for: .milliseconds(180))
        let idle = host.geometryEvaluationCount
        for _ in 0..<120 { host.cornerRadius = 18; host.elevation = 6 }
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(host.geometryEvaluationCount, idle, "Stable frames/configuration must skip coordinate conversions")
        let motion = CABasicAnimation(keyPath: "position.y")
        motion.fromValue = parent.layer.position.y; motion.toValue = parent.layer.position.y + 150
        motion.duration = 0.8; motion.timingFunction = CAMediaTimingFunction(name: .linear)
        parent.layer.add(motion, forKey: "moving-parent")
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertGreaterThan(host.geometryEvaluationCount, idle + 2)
        XCTAssertNil(host.renderingError)
        parent.layer.removeAllAnimations(); CATransaction.flush()
        try await Task.sleep(for: .milliseconds(100))
        let before = metal.drawableSize
        host.elevation = 12
        host.layoutIfNeeded()
        XCTAssertNotEqual(metal.drawableSize, before)
        XCTAssertNil(host.renderingError)
        parent.isHidden = true
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(metal.isHidden)
        let hidden = host.geometryEvaluationCount
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(host.geometryEvaluationCount, hidden, "A hidden ancestor must not cause full validation every frame")
        parent.isHidden = false
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(metal.isHidden)
        host.removeFromSuperview()
        XCTAssertTrue(metal.isHidden)
        parent.addSubview(host)
        host.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(metal.isHidden)
        host.bounds.size = .zero
        host.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(metal.isHidden)
        let empty = host.geometryEvaluationCount
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(host.geometryEvaluationCount, empty)
        host.bounds.size = CGSize(width: 180, height: 48)
        host.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(metal.isHidden)
    }
}

final class AndroidShadowMetricsTests: XCTestCase {
    func testRotatedIdentityRectangleCoverageReflectionAndThinEdges() throws {
        typealias Renderer = ZTransferAndroidShadowRenderer
        for reflected in [false,true] { for width: Float in [20,0.25,0.005] {
            let sign: Float = reflected ? -1 : 1
            let transform = ZTransferShadowTransform(x: .init(0.8 * sign,-0.6,30),
                y: .init(0.6 * sign,0.8,30), perspective: .init(0,0,1))
            let caster = ZTransferAndroidShadowMetrics.Caster(minimum: .init(-width/2,-6), maximum: .init(width/2,6), radius: 0)
            let recipe = ZTransferShadowGeometry.BlurFallback(transform: transform,
                transformApplication: .drawingMatrix, sigma: 0, style: .fill)
            let vertices = try XCTUnwrap(recipe.rotatedIdentityRectangle(caster: caster))
            let scene = try XCTUnwrap(Renderer.resolve(.init(scene: nil, orderedComponents: [
                .init(component: .spot, alpha: 173, content: .blur(recipe))], skippedComponents: []), caster: caster))
            guard case .coverage = scene.layers.first?.content else { return XCTFail("missing rectilinear AA") }
            let fullScene = Renderer.ResolvedScene(origin: .zero, size: .init(64,64), layers: [
                .init(component: .spot, content: .coverage(.init(vertices: vertices,
                    indices: ZTransferShadowBlur.coverageRectangleIndices, alpha: 173)))])
            let full = try render([], width: 64, height: 64, resolved: fullScene)
            let crop = try render([], width: scene.size.x, height: scene.size.y, resolved: scene)
            if width >= 0.25 { XCTAssertTrue(crop.contains { $0 > 0 }) }
            let inverse = try XCTUnwrap(transform.inverted())
            for y in 0..<64 { for x in 0..<64 {
                let lx = x - Int(scene.origin.x), ly = y - Int(scene.origin.y)
                let actual = (0..<scene.size.x).contains(lx) && (0..<scene.size.y).contains(ly)
                    ? Int(crop[(ly * scene.size.x + lx) * 4 + 3]) : 0
                XCTAssertLessThanOrEqual(abs(actual - Int(full[(y * 64 + x) * 4 + 3])), 1)
                if width > 1 {
                    let point = inverse.map(.init(Float(x)+0.5,Float(y)+0.5))
                    let coverage = Float16(max(0,min(1,min(width/2 + 0.5 - abs(point.x),6.5 - abs(point.y)))))
                    let expected = Int((Float(coverage * Float16(Float(173)/255)) * 255).rounded())
                    XCTAssertLessThanOrEqual(abs(actual - expected), 1)
                }
            }}
        }}
    }

    func testRectangleProxyMappingRetainsGrQuadArithmeticOrder() throws {
        let matrix = ZTransferShadowTransform(x: .init(100_000_000,-100_000_000,1),
            y: .init(1,1,0.25), perspective: .init(0,0,1))
        let quad = try XCTUnwrap(matrix.rectangleQuad(bounds: .init(1,1,2,2)))
        XCTAssertEqual(matrix.map(.init(1,1)).x, 1)
        XCTAssertEqual(quad[0].x, 0, "GrQuad must group skew and translation before adding scale")
        XCTAssertEqual(quad.map(\.y), [2.25,3.25,3.25,4.25])
        let scale = ZTransferShadowTransform(x: .init(-2,0,7), y: .init(0,3,11), perspective: .init(0,0,1))
        XCTAssertEqual(try XCTUnwrap(scale.rectangleQuad(bounds: .init(1,2,4,6))),
            [.init(5,17), .init(5,29), .init(-1,17), .init(-1,29)])
        XCTAssertNil(scale.rectangleQuad(bounds: .init(1,2,1,6)))
        XCTAssertNil(ZTransferShadowTransform(x: .init(1,0,0), y: .init(0,1,0),
            perspective: .init(0.1,0,1)).rectangleQuad(bounds: .init(0,0,1,1)))
    }

    func testMatrixPredicatesMatchPinnedSkiaBodies() throws {
        struct Case: Decodable {
            let matrix: [Float]
            let similarity: Bool
            let rightAngles: Bool
        }
        struct Reference: Decodable { let cases: [Case] }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "android15-shadow-matrix-predicates", withExtension: "json"))
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        XCTAssertEqual(reference.cases.count, 2480)
        for (index, item) in reference.cases.enumerated() {
            let m = item.matrix
            let transform = ZTransferShadowTransform(x: .init(m[0],m[1],m[2]),
                y: .init(m[3],m[4],m[5]), perspective: .init(m[6],m[7],m[8]))
            XCTAssertEqual(transform.isSimilarity, item.similarity, "similarity case \(index): \(m)")
            XCTAssertEqual(transform.preservesRightAngles, item.rightAngles, "right angles case \(index): \(m)")
        }
    }

    func testRotatedRectangleFactorsAnisotropicScaleAndCropsOnGPU() throws {
        typealias Renderer = ZTransferAndroidShadowRenderer
        let caster = ZTransferAndroidShadowMetrics.Caster(minimum: .init(-10,-10), maximum: .init(10,10), radius: 0)
        let transform = ZTransferShadowTransform(x: .init(1.6,-0.3,50), y: .init(1.2,0.4,60), perspective: .init(0,0,1))
        XCTAssertTrue(transform.preservesRightAngles)
        XCTAssertFalse(transform.isSimilarity)
        let recipe = ZTransferShadowGeometry.BlurFallback(transform: transform,
            transformApplication: .drawingMatrix, sigma: 2, style: .fill)
        let rectangle = try XCTUnwrap(recipe.rotatedBlurredRectangle(caster: caster))
        XCTAssertEqual(rectangle.bounds, .init(-20,-5,20,5))
        XCTAssertEqual(rectangle.sigma, 2)
        let middle = rectangle.inverse.map(.init(50,60))
        XCTAssertEqual(middle.x, 0, accuracy: 0.00001)
        XCTAssertEqual(middle.y, 0, accuracy: 0.00001)
        let corner = rectangle.inverse.map(transform.map(.init(10,10)))
        XCTAssertEqual(corner.x, 20, accuracy: 0.00001)
        XCTAssertEqual(corner.y, 5, accuracy: 0.00001)
        let scene = try XCTUnwrap(Renderer.resolve(.init(scene: nil, orderedComponents: [
            .init(component: .spot, alpha: 173, content: .blur(recipe))], skippedComponents: []), caster: caster))
        XCTAssertEqual(scene.origin, .init(22,35))
        XCTAssertEqual(scene.size, .init(56,50))
        guard case .rectangle(let local) = scene.layers.first?.content else { return XCTFail("missing rectangle") }
        XCTAssertEqual(local.bounds, rectangle.bounds)
        XCTAssertEqual(local.proxy, rectangle.proxy.map { $0 - scene.origin })
        let fullScene = Renderer.ResolvedScene(origin: .zero, size: .init(100,100), layers: [
            .init(component: .spot, content: .rectangle(.init(bounds: rectangle.bounds, sigma: 2, alpha: 173,
                inverse: rectangle.inverse, proxy: rectangle.proxy)))])
        let full = try render([], width: 100, height: 100, resolved: fullScene)
        let crop = try render([], width: scene.size.x, height: scene.size.y, resolved: scene)
        XCTAssertTrue(crop.contains { $0 > 0 })
        for y in 0..<100 { for x in 0..<100 {
            let lx = x - 22, ly = y - 35
            let actual = (0..<56).contains(lx) && (0..<50).contains(ly) ? Int(crop[(ly * 56 + lx) * 4 + 3]) : 0
            XCTAssertLessThanOrEqual(abs(actual - Int(full[(y * 100 + x) * 4 + 3])), 1)
        }}
        XCTAssertNil(ZTransferShadowGeometry.BlurFallback(transform: transform,
            transformApplication: .pathBeforeStyle, sigma: 2, style: .strokeAndFill(width: 1)).rotatedBlurredRectangle(caster: caster))
        let shear = ZTransferShadowTransform(x: .init(1,0.1,0), y: .init(0,1,0), perspective: .init(0,0,1))
        XCTAssertFalse(shear.preservesRightAngles)
        XCTAssertNil(ZTransferShadowGeometry.BlurFallback(transform: shear,
            transformApplication: .drawingMatrix, sigma: 2, style: .fill).rotatedBlurredRectangle(caster: caster))
    }

    func testBlurredCircleRetainsRotatedProxyThroughSceneCrop() throws {
        typealias Renderer = ZTransferAndroidShadowRenderer
        let caster = ZTransferAndroidShadowMetrics.Caster(minimum: .init(-10,-10), maximum: .init(10,10), radius: 10)
        let transform = ZTransferShadowTransform(x: .init(0.8,-0.6,50), y: .init(0.6,0.8,60), perspective: .init(0,0,1))
        let recipe = ZTransferShadowGeometry.BlurFallback(transform: transform,
            transformApplication: .drawingMatrix, sigma: 2, style: .fill)
        let circle = try XCTUnwrap(recipe.rotatedBlurredCircle(caster: caster))
        XCTAssertEqual(circle.center, .init(50,60))
        XCTAssertEqual(circle.radius, 10)
        let quad = try XCTUnwrap(circle.proxy)
        let expected: [SIMD2<Float>] = [.init(46.8,37.6), .init(27.6,63.2), .init(72.4,56.8), .init(53.2,82.4)]
        for (actual, point) in zip(quad, expected) {
            XCTAssertEqual(actual.x, point.x, accuracy: 0.00001)
            XCTAssertEqual(actual.y, point.y, accuracy: 0.00001)
        }
        let scene = try XCTUnwrap(Renderer.resolve(.init(scene: nil, orderedComponents: [
            .init(component: .spot, alpha: 173, content: .blur(recipe))], skippedComponents: []), caster: caster))
        XCTAssertEqual(scene.origin, .init(27,37))
        XCTAssertEqual(scene.size, .init(46,46))
        guard case .circle(let local) = scene.layers.first?.content else { return XCTFail("missing circle") }
        XCTAssertEqual(local.proxy, quad.map { $0 - scene.origin })
        let full = try render([], width: 100, height: 100, resolved: .init(origin: .zero, size: .init(100,100), layers: [
            .init(component: .spot, content: .circle(.init(center: circle.center, radius: circle.radius,
                sigma: circle.sigma, alpha: 173, proxy: quad)))]))
        let crop = try render([], width: 46, height: 46, resolved: scene)
        XCTAssertTrue(crop.contains { $0 > 0 })
        for y in 0..<100 { for x in 0..<100 {
            let lx = x - 27, ly = y - 37
            let actual = (0..<46).contains(lx) && (0..<46).contains(ly) ? Int(crop[(ly * 46 + lx) * 4 + 3]) : 0
            XCTAssertLessThanOrEqual(abs(actual - Int(full[(y * 100 + x) * 4 + 3])), 1)
        }}
        XCTAssertNil(ZTransferShadowGeometry.BlurFallback(transform: transform,
            transformApplication: .pathBeforeStyle, sigma: 2, style: .fill).rotatedBlurredCircle(caster: caster))
    }

    func testIdentityCircleSimilarityRotationReflectionAndTolerance() throws {
        typealias Transform = ZTransferShadowTransform
        let caster = ZTransferAndroidShadowMetrics.Caster(minimum: .init(-10,-10), maximum: .init(10,10), radius: 10)
        let tolerance: Float = 1 / 4096
        let accepted: [Transform] = [
            .init(x: .init(0.8,-0.6,40), y: .init(0.6,0.8,50), perspective: .init(0,0,1)),
            .init(x: .init(0.8,0.6,40), y: .init(0.6,-0.8,50), perspective: .init(0,0,1)),
            .init(x: .init(1,0,40), y: .init(0,1 + tolerance,50), perspective: .init(0,0,1)),
            .init(x: .init(0.8,-0.6,40), y: .init(0.6,0.8 + tolerance,50), perspective: .init(0,0,1))]
        for transform in accepted {
            XCTAssertTrue(transform.isSimilarity)
            let recipe = ZTransferShadowGeometry.BlurFallback(transform: transform,
                transformApplication: .drawingMatrix, sigma: 0, style: .fill)
            let circle = try XCTUnwrap(recipe.identityCircle(caster: caster))
            XCTAssertEqual(circle.center, .init(40,50))
            XCTAssertEqual(circle.radius, 10, accuracy: 0.002)
            let scene = try XCTUnwrap(ZTransferAndroidShadowRenderer.resolve(.init(scene: nil, orderedComponents: [
                .init(component: .spot, alpha: 173, content: .blur(recipe))], skippedComponents: []), caster: caster))
            let pixels = try render([], width: scene.size.x, height: scene.size.y, resolved: scene)
            XCTAssertTrue(pixels.contains { $0 > 0 })
        }
        let rejected: [Transform] = [
            .init(x: .init(0.8,-0.6,0), y: .init(0.6,0.8 + 2 * tolerance,0), perspective: .init(0,0,1)),
            .init(x: .init(1,0,0), y: .init(0,1 + 2 * tolerance,0), perspective: .init(0,0,1)),
            .init(x: .init(tolerance,0,0), y: .init(0,tolerance,0), perspective: .init(0,0,1)),
            .init(x: .init(1,1,0), y: .init(1,1,0), perspective: .init(0,0,1)),
            .init(x: .init(1,0,0), y: .init(0,1,0), perspective: .init(0.001,0,1))]
        for transform in rejected {
            XCTAssertFalse(transform.isSimilarity)
            XCTAssertNil(ZTransferShadowGeometry.BlurFallback(transform: transform,
                transformApplication: .drawingMatrix, sigma: 0, style: .fill).identityCircle(caster: caster))
        }
        XCTAssertNil(ZTransferShadowGeometry.BlurFallback(transform: accepted[0],
            transformApplication: .pathBeforeStyle, sigma: 0, style: .fill).identityCircle(caster: caster))
    }

    func testIdentityCircleUsesOctagonCoverageAndResolvedCrop() throws {
        typealias Renderer = ZTransferAndroidShadowRenderer
        let center = SIMD2<Float>(20.25, 20.75)
        for radius: Float in [1 / 4096, 0.25, 0.5, 5.25, 12] { for sigma: Float in [0, 0.03] {
            let caster = ZTransferAndroidShadowMetrics.Caster(minimum: center - SIMD2(repeating: radius),
                maximum: center + SIMD2(repeating: radius), radius: radius)
            let recipe = ZTransferShadowGeometry.BlurFallback(transform: .identity,
                transformApplication: .drawingMatrix, sigma: sigma, style: .fill)
            let scene = try XCTUnwrap(Renderer.resolve(.init(scene: nil, orderedComponents: [
                .init(component: .spot, alpha: 173, content: .blur(recipe))], skippedComponents: []), caster: caster))
            guard case .filledCircle = scene.layers.first?.content else { return XCTFail("missing CircleOp fill route") }
            let vertices = ZTransferShadowBlur.coverageCircleVertices(center: center, radius: radius)
            XCTAssertEqual(vertices.count, 9)
            XCTAssertEqual(ZTransferShadowBlur.coverageCircleIndices.count, 24)
            let full = try render([], width: 48, height: 48, resolved: .init(origin: .zero, size: .init(48,48), layers: [
                .init(component: .spot, content: .filledCircle(.init(center: center, radius: radius, alpha: 173)))]))
            let crop = try render([], width: scene.size.x, height: scene.size.y, resolved: scene)
            XCTAssertTrue(crop.contains { $0 > 0 })
            for y in 0..<48 { for x in 0..<48 {
                let lx = x - Int(scene.origin.x), ly = y - Int(scene.origin.y)
                let actual = (0..<scene.size.x).contains(lx) && (0..<scene.size.y).contains(ly)
                    ? Int(crop[(ly * scene.size.x + lx) * 4 + 3]) : 0
                XCTAssertLessThanOrEqual(abs(actual - Int(full[(y * 48 + x) * 4 + 3])), 1)
                let dx = (Float(x) + 0.5 - center.x) / (radius + 0.5)
                let dy = (Float(y) + 0.5 - center.y) / (radius + 0.5)
                let coverage = Float16(max(0, min(1, (radius + 0.5) * (1 - sqrtf(dx * dx + dy * dy)))))
                let expected = Int((Float(coverage * Float16(Float(173) / 255)) * 255).rounded())
                XCTAssertLessThanOrEqual(abs(actual - expected), 1)
            }}
        }}
    }

    func testIdentityRoundedRectangleDirectCoverageAndCrop() throws {
        typealias Renderer = ZTransferAndroidShadowRenderer
        let bounds = SIMD4<Float>(10.25, 12.25, 35.25, 32.25)
        for radius: Float in [0.5, 1, 5.25, 10] { for sigma: Float in [0, 0.03] {
            let caster = ZTransferAndroidShadowMetrics.Caster(minimum: .init(bounds.x, bounds.y),
                maximum: .init(bounds.z, bounds.w), radius: radius)
            let recipe = ZTransferShadowGeometry.BlurFallback(transform: .identity,
                transformApplication: .drawingMatrix, sigma: sigma, style: .fill)
            let scene = try XCTUnwrap(Renderer.resolve(.init(scene: nil, orderedComponents: [
                .init(component: .spot, alpha: 173, content: .blur(recipe))], skippedComponents: []), caster: caster))
            guard case .filledRoundedRectangle = scene.layers.first?.content else { return XCTFail("missing direct rounded AA") }
            let full = try render([], width: 48, height: 48, resolved: .init(origin: .zero, size: .init(48, 48), layers: [
                .init(component: .spot, content: .filledRoundedRectangle(.init(bounds: bounds, radius: radius, alpha: 173)))]))
            let crop = try render([], width: scene.size.x, height: scene.size.y, resolved: scene)
            XCTAssertTrue(crop.contains { $0 > 0 })
            for y in 0..<48 { for x in 0..<48 {
                let lx = x - Int(scene.origin.x), ly = y - Int(scene.origin.y)
                let actual = (0..<scene.size.x).contains(lx) && (0..<scene.size.y).contains(ly)
                    ? Int(crop[(ly * scene.size.x + lx) * 4 + 3]) : 0
                XCTAssertLessThanOrEqual(abs(actual - Int(full[(y * 48 + x) * 4 + 3])), 1)
                let px = Float(x) + 0.5, py = Float(y) + 0.5
                let dx = max(0, max(bounds.x + radius - px, px - (bounds.z - radius)))
                let dy = max(0, max(bounds.y + radius - py, py - (bounds.w - radius)))
                let outer = radius + 0.5
                let coverage = Float16(max(0, min(1, outer * (1 - sqrtf((dx / outer) * (dx / outer) + (dy / outer) * (dy / outer))))))
                let alpha = Float(coverage * Float16(Float(173) / 255))
                XCTAssertLessThanOrEqual(abs(actual - Int((alpha * 255).rounded())), 1)
            }}
        }}
    }

    func testRoundedFallbackTransformStageAndResolvedGPUCrop() throws {
        typealias Renderer = ZTransferAndroidShadowRenderer
        let caster = ZTransferAndroidShadowMetrics.Caster(minimum: .zero, maximum: .init(30, 20), radius: 2.625)
        let transform = ZTransferShadowTransform(x: .init(2, 0, 20.25), y: .init(0, 2, 30.25), perspective: .init(0, 0, 1))
        let recipe = ZTransferShadowGeometry.BlurFallback(transform: transform,
            transformApplication: .drawingMatrix, sigma: 1, style: .fill)
        let plan = try XCTUnwrap(recipe.roundedRectanglePlan(caster: caster))
        XCTAssertEqual(plan.shaderCorner, 5.25)
        XCTAssertEqual(plan.roundedCorner, 6)
        XCTAssertEqual(plan.proxyRectangle, .init(17.25, 27.25, 83.25, 73.25))
        let scene = try XCTUnwrap(Renderer.resolve(.init(scene: nil, orderedComponents: [
            .init(component: .spot, alpha: 48, content: .blur(recipe))], skippedComponents: []), caster: caster))
        XCTAssertEqual(scene.origin, .init(17, 27))
        XCTAssertEqual(scene.size, .init(67, 47))
        guard case .roundedRectangle(let local, let alpha) = scene.layers.first?.content else { return XCTFail("missing rounded route") }
        XCTAssertEqual(alpha, 48)
        XCTAssertEqual(local.maskRectangle, plan.maskRectangle)
        XCTAssertEqual(local.textureSize, plan.textureSize)
        XCTAssertEqual(local.proxyRectangle, .init(0.25, 0.25, 66.25, 46.25))
        let fullScene = Renderer.ResolvedScene(origin: .zero, size: .init(100, 100), layers: [
            .init(component: .spot, content: .roundedRectangle(plan, 48))])
        let full = try render([], width: 100, height: 100, resolved: fullScene)
        let crop = try render([], width: 67, height: 47, resolved: scene)
        XCTAssertTrue(crop.contains { $0 > 0 })
        for y in 0..<100 { for x in 0..<100 {
            let lx = x - 17, ly = y - 27
            let actual = (0..<67).contains(lx) && (0..<47).contains(ly) ? Int(crop[(ly * 67 + lx) * 4 + 3]) : 0
            XCTAssertLessThanOrEqual(abs(actual - Int(full[(y * 100 + x) * 4 + 3])), 1)
        }}
        let quarter = ZTransferShadowTransform(x: .init(0, -2, 80), y: .init(2, 0, 30), perspective: .init(0, 0, 1))
        XCTAssertNil(ZTransferShadowGeometry.BlurFallback(transform: quarter,
            transformApplication: .drawingMatrix, sigma: 1, style: .fill).roundedRectanglePlan(caster: caster))
        XCTAssertNotNil(ZTransferShadowGeometry.BlurFallback(transform: quarter,
            transformApplication: .pathBeforeStyle, sigma: 1, style: .fill).roundedRectanglePlan(caster: caster))
        let ellipse = ZTransferShadowTransform(x: .init(2, 0, 0), y: .init(0, 1, 0), perspective: .init(0, 0, 1))
        XCTAssertNil(ZTransferShadowGeometry.BlurFallback(transform: ellipse,
            transformApplication: .drawingMatrix, sigma: 1, style: .fill).roundedRectanglePlan(caster: caster))
        XCTAssertNil(ZTransferShadowGeometry.BlurFallback(transform: transform,
            transformApplication: .pathBeforeStyle, sigma: 1, style: .strokeAndFill(width: 1)).roundedRectanglePlan(caster: caster))
    }

    func testCircleFallbackClassificationAndResolvedGPUCrop() throws {
        typealias Renderer = ZTransferAndroidShadowRenderer
        let caster = ZTransferAndroidShadowMetrics.Caster(minimum: .init(0, 0), maximum: .init(20, 20), radius: 10)
        let transforms: [ZTransferShadowTransform] = [
            .init(x: .init(2, 0, 30), y: .init(0, 2, 40), perspective: .init(0, 0, 1)),
            .init(x: .init(-2, 0, 70), y: .init(0, 2, 40), perspective: .init(0, 0, 1)),
            .init(x: .init(0, -2, 70), y: .init(2, 0, 40), perspective: .init(0, 0, 1))]
        for transform in transforms {
            let recipe = ZTransferShadowGeometry.BlurFallback(transform: transform,
                transformApplication: .drawingMatrix, sigma: 2, style: .fill)
            let circle = try XCTUnwrap(recipe.axisAlignedCircle(caster: caster))
            XCTAssertEqual(circle.center, .init(50, 60))
            XCTAssertEqual(circle.radius, 20)
            let scene = try XCTUnwrap(Renderer.resolve(.init(scene: nil, orderedComponents: [
                .init(component: .spot, alpha: 48, content: .blur(recipe))], skippedComponents: []), caster: caster))
            XCTAssertEqual(scene.origin, .init(24, 34))
            XCTAssertEqual(scene.size, .init(52, 52))
            guard case .circle = scene.layers.first?.content else { return XCTFail("missing circle route") }
            let fullScene = Renderer.ResolvedScene(origin: .zero, size: .init(100, 100), layers: [
                .init(component: .spot, content: .circle(.init(center: .init(50, 60), radius: 20, sigma: 2, alpha: 48)))])
            let full = try render([], width: 100, height: 100, resolved: fullScene)
            let crop = try render([], width: 52, height: 52, resolved: scene)
            for y in 0..<100 { for x in 0..<100 {
                let lx = x - 24, ly = y - 34
                let actual = (0..<52).contains(lx) && (0..<52).contains(ly) ? Int(crop[(ly * 52 + lx) * 4 + 3]) : 0
                XCTAssertLessThanOrEqual(abs(actual - Int(full[(y * 100 + x) * 4 + 3])), 1)
            }}
        }
        for transform: ZTransferShadowTransform in [
            .init(x: .init(2, 0, 0), y: .init(0, 1, 0), perspective: .init(0, 0, 1)),
            .init(x: .init(0.8, -0.6, 0), y: .init(0.6, 0.8, 0), perspective: .init(0, 0, 1)),
            .init(x: .init(1, 0, 0), y: .init(0, 1, 0), perspective: .init(0.01, 0, 1))] {
            XCTAssertNil(ZTransferShadowGeometry.BlurFallback(transform: transform,
                transformApplication: .drawingMatrix, sigma: 2, style: .fill).axisAlignedCircle(caster: caster))
        }
        XCTAssertNil(ZTransferShadowGeometry.BlurFallback(transform: .identity,
            transformApplication: .pathBeforeStyle, sigma: 2, style: .strokeAndFill(width: 1)).axisAlignedCircle(caster: caster))
        XCTAssertNil(ZTransferShadowGeometry.BlurFallback(transform: .identity,
            transformApplication: .drawingMatrix, sigma: 0.03, style: .fill).axisAlignedCircle(caster: caster))
    }

    func testIdentityRectangleFallbackCoverageAndHairlineCrop() throws {
        typealias Renderer = ZTransferAndroidShadowRenderer
        for bounds: SIMD4<Float> in [.init(10.25, 12.25, 35.75, 40.75),
                                    .init(10.25, 12.25, 10.5, 40.75), .init(10.25, 12.25, 10.5, 12.5)] {
            for sigma: Float in [0, 0.03] {
                let caster = ZTransferAndroidShadowMetrics.Caster(minimum: .init(bounds.x, bounds.y),
                    maximum: .init(bounds.z, bounds.w), radius: 0)
                let recipe = ZTransferShadowGeometry.BlurFallback(transform: .identity,
                    transformApplication: .drawingMatrix, sigma: sigma, style: .fill)
                let scene = try XCTUnwrap(Renderer.resolve(.init(scene: nil, orderedComponents: [
                    .init(component: .spot, alpha: 173, content: .blur(recipe))], skippedComponents: []), caster: caster))
                let fullScene = Renderer.ResolvedScene(origin: .zero, size: .init(48, 48), layers: [
                    .init(component: .spot, content: .filledRectangle(.init(bounds: bounds, alpha: 173)))])
                let full = try render([], width: 48, height: 48, resolved: fullScene)
                let crop = try render([], width: scene.size.x, height: scene.size.y, resolved: scene)
                var visible = 0
                for y in 0..<48 { for x in 0..<48 {
                    let lx = x - Int(scene.origin.x), ly = y - Int(scene.origin.y)
                    let actual = (0..<scene.size.x).contains(lx) && (0..<scene.size.y).contains(ly)
                        ? Int(crop[(ly * scene.size.x + lx) * 4 + 3]) : 0
                    let expected = Int(full[(y * 48 + x) * 4 + 3])
                    XCTAssertLessThanOrEqual(abs(actual - expected), 1)
                    if actual > 0 { visible += 1 }
                    if bounds.z - bounds.x > 1 && bounds.w - bounds.y > 1 {
                        let px = Float(x) + 0.5, py = Float(y) + 0.5
                        let coverage = max(0, min(1, min(min(px - bounds.x + 0.5, bounds.z + 0.5 - px),
                            min(py - bounds.y + 0.5, bounds.w + 0.5 - py))))
                        let alpha = Float(Float16(coverage) * Float16(Float(173) / 255))
                        XCTAssertLessThanOrEqual(abs(expected - Int((alpha * 255).rounded())), 1)
                    }
                }}
                XCTAssertGreaterThan(visible, 0)
            }
        }
    }

    func testResolvedShadowIncludesFallbackBoundsAndPreservesComponents() throws {
        typealias Renderer = ZTransferAndroidShadowRenderer
        let caster = ZTransferAndroidShadowMetrics.Caster(minimum: .init(40.25, 30.5),
            maximum: .init(75.25, 65.5), radius: 0)
        let mesh = Renderer.TessellatedLayer(vertices: [
            .init(position: .init(8, 9), alpha: 255), .init(position: .init(50, 9), alpha: 160),
            .init(position: .init(8, 55), alpha: 0)], indices: [0, 1, 2], alpha: 90)
        let recipe = ZTransferShadowGeometry.BlurFallback(transform: .identity,
            transformApplication: .drawingMatrix, sigma: 2, style: .fill)
        let items: [Renderer.PreparedComponent] = [
            .init(component: .ambient, alpha: 90, content: .mesh(mesh)),
            .init(component: .spot, alpha: 180, content: .blur(recipe))]
        let preparation = Renderer.TessellatedPreparation(scene: nil, orderedComponents: items, skippedComponents: [])
        let scene = try XCTUnwrap(Renderer.resolve(preparation, caster: caster))
        XCTAssertEqual(scene.origin, .init(8, 9))
        XCTAssertEqual(scene.size, .init(74, 63))
        XCTAssertEqual(scene.layers.map(\.component), [.ambient, .spot])
        let fullScene = Renderer.ResolvedScene(origin: .zero, size: .init(96, 96), layers: [
            .init(component: .ambient, content: .mesh(mesh)),
            .init(component: .spot, content: .rectangle(.init(bounds: .init(40.25, 30.5, 75.25, 65.5), sigma: 2, alpha: 180)))])
        let full = try render([], width: 96, height: 96, resolved: fullScene)
        let cropped = try render([], width: scene.size.x, height: scene.size.y, resolved: scene)
        var visible = 0
        for y in 0..<96 { for x in 0..<96 {
            let localX = x - Int(scene.origin.x), localY = y - Int(scene.origin.y)
            let actual = (0..<scene.size.x).contains(localX) && (0..<scene.size.y).contains(localY)
                ? Int(cropped[(localY * scene.size.x + localX) * 4 + 3]) : 0
            let expected = Int(full[(y * 96 + x) * 4 + 3])
            XCTAssertLessThanOrEqual(abs(actual - expected), 1)
            if actual > 0 { visible += 1 }
        }}
        XCTAssertGreaterThan(visible, 1000)
        XCTAssertNil(try Renderer.resolve(.init(scene: nil, orderedComponents: [], skippedComponents: [.spot]), caster: caster))
        let rounded = ZTransferAndroidShadowMetrics.Caster(minimum: caster.minimum, maximum: caster.maximum, radius: 4)
        let roundedScene = try XCTUnwrap(Renderer.resolve(preparation, caster: rounded))
        guard case .roundedRectangle = roundedScene.layers.last?.content else { return XCTFail("missing rounded fallback") }
        let identityBlur = ZTransferShadowGeometry.BlurFallback(transform: .identity,
            transformApplication: .drawingMatrix, sigma: 0, style: .fill)
        let identityScene = try XCTUnwrap(Renderer.resolve(.init(scene: nil, orderedComponents: [
            items[0], .init(component: .spot, alpha: 180, content: .blur(identityBlur))], skippedComponents: []), caster: caster))
        guard case .filledRectangle = identityScene.layers.last?.content else { return XCTFail("identity must draw direct coverage") }
    }

    func testTessellatedSceneCropMatchesFullWindowOnGPU() throws {
        typealias Metrics = ZTransferAndroidShadowMetrics
        typealias Renderer = ZTransferAndroidShadowRenderer
        let light = try XCTUnwrap(Metrics.materialLighting(displayPixels: .init(400, 800), density: 1))
        let caster = Metrics.Caster(minimum: .zero, maximum: .init(80, 40), radius: 16)
        let transforms = [
            ZTransferShadowTransform(x: .init(0.8, -0.6, 60), y: .init(0.6, 0.8, 70), perspective: .init(0, 0, 1)),
            .init(x: .init(1.1, 0.2, 40), y: .init(-0.1, 0.7, 80), perspective: .init(0, 0, 1)),
            .init(x: .init(1, 0.2, 60), y: .init(-0.1, 1, 70), perspective: .init(0.001, -0.001, 1))
        ]
        for transform in transforms {
            for nodeAlpha: Float in [1, 0.5] {
                let preparation = try Renderer.tessellatedScene(caster: caster, elevation: 6, lighting: light,
                    transform: transform, nodeAlpha: nodeAlpha)
                XCTAssertTrue(preparation.failedComponents.isEmpty)
                XCTAssertEqual(preparation.orderedComponents.map(\.component), [.ambient, .spot])
                XCTAssertEqual(preparation.orderedComponents.map(\.alpha), nodeAlpha == 1 ? [9, 48] : [4, 24])
                if let crop = preparation.scene {
                    for (ordered, local) in zip(preparation.orderedComponents, crop.layers) {
                        guard case .mesh(let world) = ordered.content else { return XCTFail("unexpected blur") }
                        XCTAssertEqual(world.alpha, ordered.alpha)
                        XCTAssertEqual(world.indices, local.indices)
                        XCTAssertEqual(world.vertices.count, local.vertices.count)
                        for (a, b) in zip(world.vertices, local.vertices) {
                            XCTAssertEqual(a.position.x - crop.origin.x, b.position.x)
                            XCTAssertEqual(a.position.y - crop.origin.y, b.position.y)
                            XCTAssertEqual(a.alpha, b.alpha)
                        }
                    }
                }
                let scene = try XCTUnwrap(preparation.scene)
                let opacity = try XCTUnwrap(Metrics.opacity(lighting: light, nodeAlpha: nodeAlpha, outlineAlpha: 1))
                let pair = try XCTUnwrap(ZTransferShadowGeometry.roundedRect(minimum: caster.minimum,
                    maximum: caster.maximum, radii: .init(repeating: caster.radius), transform: transform,
                    heightPlane: .init(0, 0, 6), light: light.center, lightRadius: light.radius,
                    transparent: opacity.transparentOccluder))
                let layers = try [(pair.ambient, opacity.ambient), (pair.spot, opacity.spot)].map { mesh, alpha in
                    let mesh = try XCTUnwrap(mesh)
                    return Renderer.TessellatedLayer(vertices: zip(mesh.points, mesh.alphas).map {
                        .init(position: $0.0, alpha: $0.1)
                    }, indices: mesh.indices, alpha: alpha)
                }
                let full = try render([], width: 200, height: 200, tessellated: layers)
                let legacyCrop = try render([], width: scene.size.x, height: scene.size.y, tessellated: scene.layers)
                let resolved = try XCTUnwrap(Renderer.resolve(preparation, caster: caster))
                XCTAssertEqual(resolved.origin, scene.origin)
                XCTAssertEqual(resolved.size, scene.size)
                let cropped = try render([], width: resolved.size.x, height: resolved.size.y, resolved: resolved)
                XCTAssertEqual(cropped, legacyCrop, "resolved mesh passes must preserve the original composition")
                XCTAssertLessThan(scene.size.x * scene.size.y, 200 * 200)
                var difference = 0, visible = 0
                for y in 0..<200 {
                    for x in 0..<200 {
                        let localX = x - Int(scene.origin.x), localY = y - Int(scene.origin.y)
                        let expected = Int(full[(y * 200 + x) * 4 + 3])
                        let actual = (0..<scene.size.x).contains(localX) && (0..<scene.size.y).contains(localY)
                            ? Int(cropped[(localY * scene.size.x + localX) * 4 + 3]) : 0
                        difference = max(difference, abs(actual - expected))
                        if expected > 0 { visible += 1 }
                    }
                }
                XCTAssertGreaterThan(visible, 100)
                XCTAssertLessThanOrEqual(difference, 1)
            }
        }
        let partial = try Renderer.tessellatedScene(caster: caster, elevation: 500, lighting: light, transform: transforms[2])
        XCTAssertTrue(partial.failedComponents.isEmpty)
        XCTAssertEqual(partial.skippedComponents, [.spot])
        XCTAssertEqual(partial.scene?.layers.count, 1)
        XCTAssertEqual(partial.orderedComponents.map(\.component), [.ambient])
        let pendingBlur = try Renderer.tessellatedScene(caster: caster, elevation: 6,
            lighting: .init(center: .init(201, -50, 500), radius: 0, ambientAlpha: 9, spotAlpha: 48),
            transform: transforms[0])
        XCTAssertEqual(pendingBlur.failedComponents, [.spot])
        XCTAssertTrue(pendingBlur.skippedComponents.isEmpty)
        XCTAssertEqual(pendingBlur.blurFallbacks[.spot]?.sigma, 0)
        XCTAssertEqual(pendingBlur.blurFallbacks[.spot]?.style, .fill)
        XCTAssertEqual(pendingBlur.scene?.layers.count, 1)
        XCTAssertEqual(pendingBlur.orderedComponents.map(\.component), [.ambient, .spot])
        XCTAssertEqual(pendingBlur.orderedComponents.map(\.alpha), [9, 48])
        guard case .mesh = pendingBlur.orderedComponents[0].content,
              case .blur(let spotRecipe) = pendingBlur.orderedComponents[1].content else {
            return XCTFail("ambient mesh must precede the pending spot blur")
        }
        XCTAssertEqual(spotRecipe.sigma, 0)
        let invisible = try Renderer.tessellatedScene(caster: caster, elevation: 6, lighting: light,
            transform: transforms[0], nodeAlpha: 0)
        XCTAssertTrue(invisible.orderedComponents.isEmpty)
        let empty = try Renderer.tessellatedScene(caster: .init(minimum: .zero, maximum: .init(0, 40), radius: 4),
            elevation: 6, lighting: light, transform: .identity)
        XCTAssertNil(empty.scene)
        XCTAssertTrue(empty.failedComponents.isEmpty)
        XCTAssertNil(try Renderer.tessellatedScene(caster: caster, elevation: 0, lighting: light, transform: .identity).scene)
        XCTAssertNil(try Renderer.tessellatedScene(caster: caster, elevation: 6, lighting: light, transform: .identity, nodeAlpha: 0).scene)
    }
    func testIntegratedGeometryMatchesPinnedSkiaReference() throws {
        struct Mesh: Decodable {
            let valid: Bool
            let vertices: [[Float]]
            let indices: [UInt16]
        }
        struct Case: Decodable {
            let bounds, radii, matrix, plane, light: [Float]
            let lightRadius: Float
            let transparent: Bool
            let ambient, spot: Mesh
        }
        struct Fixture: Decodable { let cases: [Case] }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "android15-shadow-integrated", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.cases.count, 123)
        var independentFailures = 0, emptyPairs = 0
        for (index, item) in fixture.cases.enumerated() {
            let m = item.matrix
            let transform = ZTransferShadowTransform(x: .init(m[0], m[1], m[2]), y: .init(m[3], m[4], m[5]),
                perspective: .init(m[6], m[7], m[8]))
            let result = try XCTUnwrap(ZTransferShadowGeometry.roundedRect(minimum: .init(item.bounds[0], item.bounds[1]),
                maximum: .init(item.bounds[2], item.bounds[3]), radii: .init(item.radii[0], item.radii[1]),
                transform: transform, heightPlane: .init(item.plane[0], item.plane[1], item.plane[2]),
                light: .init(item.light[0], item.light[1], item.light[2]), lightRadius: item.lightRadius,
                transparent: item.transparent))
            for (actual, expected) in [(result.ambient, item.ambient), (result.spot, item.spot)] {
                XCTAssertEqual(actual != nil, expected.valid, "valid \(index)")
                guard let actual else { continue }
                XCTAssertEqual(actual.points, expected.vertices.map { .init($0[0], $0[1]) }, "vertices \(index)")
                XCTAssertEqual(actual.alphas, expected.vertices.map { UInt8($0[2]) }, "alpha \(index)")
                XCTAssertEqual(actual.indices, expected.indices, "indices \(index)")
            }
            if result.ambient != nil && result.spot == nil { independentFailures += 1 }
            if result.ambient?.points.isEmpty == true && result.spot?.points.isEmpty == true { emptyPairs += 1 }
        }
        XCTAssertGreaterThanOrEqual(independentFailures, 2)
        XCTAssertEqual(emptyPairs, 1)
    }
    func testRoundedRectPathMatchesPinnedSkiaReference() throws {
        struct Case: Decodable {
            let bounds, radii, weights: [Float]
            let clockwise: Bool
            let start: Int?
            let verbs: [Int]
            let points: [[Float]]
        }
        struct Fixture: Decodable { let cases: [Case] }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "android15-shadow-rrect-paths", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.cases.count, 504)
        for (index, item) in fixture.cases.enumerated() {
            let path = try XCTUnwrap(ZTransferShadowPath.roundedRect(minimum: .init(item.bounds[0], item.bounds[1]),
                maximum: .init(item.bounds[2], item.bounds[3]), radii: .init(item.radii[0], item.radii[1]),
                clockwise: item.clockwise, startIndex: item.start))
            var verbs: [Int] = [], points: [SIMD2<Float>] = [], weights: [Float] = []
            for element in path {
                switch element {
                case .move(let p): verbs.append(0); points.append(p)
                case .line(let p): verbs.append(1); points.append(p)
                case .quadratic(let c, let p): verbs.append(2); points.append(contentsOf: [c, p])
                case .conic(let c, let p, let weight): verbs.append(3); points.append(contentsOf: [c, p]); weights.append(weight)
                case .cubic(let a, let b, let p): verbs.append(4); points.append(contentsOf: [a, b, p])
                case .close: verbs.append(5)
                }
            }
            XCTAssertEqual(verbs, item.verbs, "verbs \(index)")
            XCTAssertEqual(points, item.points.map { .init($0[0], $0[1]) }, "points \(index)")
            XCTAssertEqual(weights, item.weights, "weights \(index)")
        }
    }
    func testSpotProjectionMatchesPinnedSkiaReference() throws {
        struct Case: Decodable {
            let bounds, matrix, plane, light, projected: [Float]
            let radius, outset: Float
            let directional, valid: Bool
        }
        struct Fixture: Decodable { let cases: [Case] }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "android15-shadow-projections", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.cases.count, 245)
        var rejected = 0
        for (index, item) in fixture.cases.enumerated() {
            let m = item.matrix
            let transform = ZTransferShadowTransform(x: .init(m[0], m[1], m[2]), y: .init(m[3], m[4], m[5]),
                perspective: .init(m[6], m[7], m[8]))
            let result = ZTransferShadowProjection.spot(boundsMinimum: .init(item.bounds[0], item.bounds[1]),
                boundsMaximum: .init(item.bounds[2], item.bounds[3]), transform: transform,
                heightPlane: .init(item.plane[0], item.plane[1], item.plane[2]),
                light: .init(item.light[0], item.light[1], item.light[2]), lightRadius: item.radius, directional: item.directional)
            XCTAssertEqual(result != nil, item.valid, "case \(index)")
            guard let result else { rejected += 1; continue }
            let actual = [result.transform.x, result.transform.y, result.transform.perspective].flatMap { [$0.x, $0.y, $0.z] }
            XCTAssertEqual(actual, item.projected, "matrix \(index)")
            XCTAssertEqual(result.outset, item.outset, "radius \(index)")
        }
        XCTAssertGreaterThan(rejected, 10)
    }
    func testPathAssemblyMatchesPinnedSkiaReference() throws {
        struct Element: Decodable {
            let verb: Int
            let points: [[Float]]
            let weight: Float?
            init(from decoder: Decoder) throws {
                var values = try decoder.unkeyedContainer()
                verb = try values.decode(Int.self)
                points = try values.decode([[Float]].self)
                weight = values.isAtEnd ? nil : try values.decode(Float.self)
            }
            var native: ZTransferShadowPath.Element {
                let p = points.map { SIMD2<Float>($0[0], $0[1]) }
                switch verb {
                case 0: return .move(p[0])
                case 1: return .line(p[0])
                case 2: return .quadratic(p[0], p[1])
                case 3: return .conic(p[0], p[1], weight: weight!)
                case 4: return .cubic(p[0], p[1], p[2])
                default: return .close
                }
            }
        }
        struct Case: Decodable {
            let elements: [Element]
            let matrix: [Float]
            let clipMatrix: [Float]?
            let valid, convex: Bool
            let points, clip: [[Float]]
            let centroid: [Float?]
            let area, direction: Float
        }
        struct Fixture: Decodable { let cases: [Case] }
        func transform(_ values: [Float]) -> ZTransferShadowTransform {
            .init(x: .init(values[0], values[1], values[2]), y: .init(values[3], values[4], values[5]),
                  perspective: .init(values[6], values[7], values[8]))
        }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "android15-shadow-paths", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.cases.count, 144)
        for (index, item) in fixture.cases.enumerated() {
            let result = ZTransferShadowPath.prepare(item.elements.map(\.native), transform: transform(item.matrix),
                clipTransform: item.clipMatrix.map(transform))
            XCTAssertEqual(result != nil, item.valid, "case \(index)")
            guard let result else { continue }
            XCTAssertEqual(result.polygon.points, item.points.map { .init($0[0], $0[1]) }, "points \(index)")
            XCTAssertEqual(result.clip, item.clip.map { .init($0[0], $0[1]) }, "clip \(index)")
            XCTAssertEqual(result.polygon.isConvex, item.convex, "convex \(index)")
            XCTAssertEqual(result.polygon.doubledArea, item.area, "area \(index)")
            XCTAssertEqual(result.polygon.direction, item.direction, "direction \(index)")
            for axis in 0..<2 {
                if let expected = item.centroid[axis] { XCTAssertEqual(result.polygon.centroid[axis], expected, "centroid \(index)") }
                else { XCTAssertFalse(result.polygon.centroid[axis].isFinite, "centroid \(index)") }
            }
        }
        let zeroPlane = ZTransferShadowTransform(x: .init(1, 0, 0), y: .init(0, 1, 0), perspective: .zero)
        XCTAssertEqual(zeroPlane.map(.init(10, 20)), .zero)
        XCTAssertNil(ZTransferShadowPath.prepare([.move(.zero), .line(.init(.infinity, 1))], transform: .identity))
    }
    func testConvexMeshMatchesPinnedSkiaReference() throws {
        struct Case: Decodable {
            let points: [[Float]]
            let centroid: [Float]
            let direction, inset, outset: Float
            let transparent, valid: Bool
            let clip: [[Float]]?
            let vertices: [[Float]]
            let indices: [UInt16]
        }
        struct Fixture: Decodable { let cases: [Case] }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "android15-shadow-convex-meshes", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.cases.count, 1056)
        var failedInnerRings = 0
        for (index, item) in fixture.cases.enumerated() {
            let polygon = ZTransferShadowPolygon(points: item.points.map { .init($0[0], $0[1]) },
                centroid: .init(item.centroid[0], item.centroid[1]), doubledArea: -item.direction,
                isConvex: true, direction: item.direction)
            if item.inset > 1 / 4096,
               let adjusted = ZTransferShadowUmbra.prepare(polygon: polygon, inset: item.inset),
               !ZTransferShadowInset.inset(polygon.points, by: adjusted.inset).isValid {
                failedInnerRings += 1
            }
            let result = ZTransferShadowConvexMesh.make(polygon: polygon, inset: item.inset,
                outset: item.outset, transparent: item.transparent,
                clip: item.clip?.map { .init($0[0], $0[1]) })
            XCTAssertEqual(result != nil, item.valid, "case \(index)")
            guard let result else { continue }
            XCTAssertEqual(result.points, item.vertices.map { .init($0[0], $0[1]) }, "vertices \(index)")
            XCTAssertEqual(result.alphas, item.vertices.map { UInt8($0[2]) }, "alphas \(index)")
            XCTAssertEqual(result.indices, item.indices, "indices \(index)")
        }
        XCTAssertGreaterThan(failedInnerRings, 0)
        let square = try XCTUnwrap(ZTransferShadowPolygon.prepare([.zero, .init(10, 0), .init(10, 10), .init(0, 10)]))
        XCTAssertNil(ZTransferShadowConvexMesh.make(polygon: square, inset: 1, outset: .infinity, transparent: false))
        XCTAssertNil(ZTransferShadowConvexMesh.make(polygon: square, inset: 1, outset: 1, transparent: false, clip: []))
    }
    func testConvexInsetMatchesPinnedSkiaReference() throws {
        struct Case: Decodable {
            let input, points: [[Float]]
            let inset: Float
            let valid: Bool
        }
        struct Fixture: Decodable { let cases: [Case] }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "android15-shadow-insets", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(fixture.cases.count, 600)
        var reduced = 0, failures = 0
        for (index, item) in fixture.cases.enumerated() {
            let input = item.input.map { SIMD2<Float>($0[0], $0[1]) }
            let expected = item.points.map { SIMD2<Float>($0[0], $0[1]) }
            let actual = ZTransferShadowInset.inset(input, by: item.inset)
            XCTAssertEqual(actual.isValid, item.valid, "case \(index)")
            XCTAssertEqual(actual.points, expected, "case \(index)")
            if actual.isValid && actual.points.count < input.count { reduced += 1 }
            if !actual.isValid { failures += 1 }
        }
        XCTAssertGreaterThan(reduced, 5)
        XCTAssertGreaterThan(failures, 100)
        let square: [SIMD2<Float>] = [.zero, .init(10, 0), .init(10, 10), .init(0, 10)]
        for invalid in [Float.nan, .infinity, -.infinity] {
            XCTAssertFalse(ZTransferShadowInset.inset(square, by: invalid).isValid)
        }
        XCTAssertFalse(ZTransferShadowInset.inset([.zero, .init(.infinity, 0), .init(0, 1)], by: 1).isValid)
        XCTAssertFalse(ZTransferShadowInset.inset(Array(repeating: .zero, count: 65_536), by: 0).isValid)
        // The original near-zero shortcut precedes convexity checking.
        XCTAssertTrue(ZTransferShadowInset.inset(Array(repeating: .zero, count: 65_535), by: 0).isValid)
    }
    func testUmbraCollapseMatchesPinnedSkiaReference() throws {
        struct Case: Decodable {
            let points: [[Float]]
            let centroid: [Float]
            let inset, adjustedInset: Float
            let alpha: UInt8
        }
        struct Fixture: Decodable { let cases: [Case] }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "android15-shadow-umbra", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(fixture.cases.count, 50)
        var collapsed = 0
        for item in fixture.cases {
            let polygon = ZTransferShadowPolygon(points: item.points.map { .init($0[0], $0[1]) },
                centroid: .init(item.centroid[0], item.centroid[1]), doubledArea: 1,
                isConvex: true, direction: 1)
            let result = try XCTUnwrap(ZTransferShadowUmbra.prepare(polygon: polygon, inset: item.inset))
            XCTAssertEqual(result.inset, item.adjustedInset)
            XCTAssertEqual(result.alpha, item.alpha)
            if result.alpha < 255 { collapsed += 1 }
        }
        XCTAssertGreaterThan(collapsed, 20)
        let degenerate = try XCTUnwrap(ZTransferShadowPolygon.prepare([.zero, .init(1, 0), .init(2, 0)]))
        XCTAssertNil(ZTransferShadowUmbra.prepare(polygon: degenerate, inset: 1))
        let square = try XCTUnwrap(ZTransferShadowPolygon.prepare([.zero, .init(10, 0), .init(10, 10), .init(0, 10)]))
        XCTAssertNil(ZTransferShadowUmbra.prepare(polygon: square, inset: .infinity))
        XCTAssertNil(ZTransferShadowUmbra.prepare(polygon: square, inset: -1))
    }
    private struct Fixture: Decodable {
        let rows: [[Float]]
        let falloff: [UInt8]
        let meshes: [Mesh]
        let circles: [Mesh]
    }
    private struct Mesh: Decodable {
        let radius, blur, inset: Float
        let kind: Int
        let vertices: [[Float]]
        let indices: [UInt16]
    }
    func testProjectionMatchesPinnedSkiaReference() throws {
        let fixture = try load()
        XCTAssertEqual(fixture.rows.count, 24)
        for row in fixture.rows {
            let result = ZTransferAndroidShadowMetrics.projection(height: row[0], lightX: row[1],
                lightY: row[2], lightZ: row[3], lightRadius: row[4])
            let actual = [result.ambientOutset, result.ambientBlurWidth, result.spotOutset,
                          result.spotScale, result.spotTranslationX, result.spotTranslationY]
            for (value, expected) in zip(actual, row[5...]) {
                XCTAssertEqual(value, expected, accuracy: 0.00001, "height=\(row[0]), lightX=\(row[1])")
            }
            XCTAssertEqual(result.spotBlurWidth, 2 * row[7], accuracy: 0.00001)
        }
    }
    func testFalloffMatchesAll128ReferenceBytes() throws {
        let fixture = try load()
        XCTAssertEqual(fixture.falloff.count, 128)
        XCTAssertEqual(ZTransferAndroidShadowMetrics.falloff, fixture.falloff)
    }
    func testRoundedRectMeshesMatchPinnedSkiaVerticesAndTopology() throws {
        let fixture = try load()
        XCTAssertEqual(fixture.meshes.count, 54)
        XCTAssertEqual(Set(fixture.meshes.map(\.kind)), [0, 1, 2])
        for expected in fixture.meshes {
            let actual = try XCTUnwrap(ZTransferAndroidShadowMetrics.roundedRectMesh(
                left: -7, top: 13, right: 193, bottom: 93, radius: expected.radius,
                blurWidth: expected.blur, insetWidth: expected.inset))
            XCTAssertEqual(actual.kind.rawValue, expected.kind)
            XCTAssertEqual(actual.indices, expected.indices)
            XCTAssertEqual(actual.vertices.count, expected.vertices.count)
            for (vertex, reference) in zip(actual.vertices, expected.vertices) {
                let components = [vertex.position.x, vertex.position.y, vertex.offset.x,
                                  vertex.offset.y, vertex.distanceCorrection]
                for (value, expectedValue) in zip(components, reference) {
                    XCTAssertEqual(value, expectedValue, accuracy: 0.00001)
                }
            }
        }
    }

    func testCircleMeshesMatchPinnedSkiaVerticesAndTopology() throws {
        let fixture = try load()
        XCTAssertEqual(fixture.circles.count, 60)
        XCTAssertEqual(Set(fixture.circles.map(\.kind)), [0, 1])
        for expected in fixture.circles {
            let actual = try XCTUnwrap(ZTransferAndroidShadowMetrics.circleMesh(
                center: .init(17, -13), radius: expected.radius,
                blurWidth: expected.blur, insetWidth: expected.inset))
            XCTAssertEqual(actual.kind.rawValue, expected.kind)
            XCTAssertEqual(actual.indices, expected.indices)
            XCTAssertEqual(actual.vertices.count, expected.vertices.count)
            for (vertex, reference) in zip(actual.vertices, expected.vertices) {
                let components = [vertex.position.x, vertex.position.y, vertex.offset.x,
                                  vertex.offset.y, vertex.distanceCorrection]
                for (value, expectedValue) in zip(components, reference) {
                    XCTAssertEqual(value, expectedValue, accuracy: 0.00001)
                }
            }
        }
    }

    func testMetalFalloffSamplingAndLayerComposition() throws {
        typealias Metrics = ZTransferAndroidShadowMetrics
        let vertices: [Metrics.Vertex] = [
            .init(position: .init(0, 0), offset: .zero, distanceCorrection: 0),
            .init(position: .init(128, 0), offset: .zero, distanceCorrection: 1),
            .init(position: .init(128, 8), offset: .zero, distanceCorrection: 1),
            .init(position: .init(0, 8), offset: .zero, distanceCorrection: 0)
        ]
        let mesh = Metrics.RoundedRectMesh(kind: .fill, vertices: vertices, indices: [0,1,2, 0,2,3])
        let reference = try load().falloff
        for alpha: UInt8 in [255, 128] {
            let layers = Array(repeating: ZTransferAndroidShadowRenderer.Layer(mesh: mesh, alpha: alpha),
                               count: alpha == 255 ? 1 : 2)
            let pixels = try render(layers, width: 128, height: 8)
            for y in 0..<8 {
                for x in 0..<128 {
                    let offset = (y * 128 + x) * 4
                    XCTAssertEqual(Array(pixels[offset..<offset+3]), [0, 0, 0])
                    let a = Float(reference[x]) / 255 * Float(alpha) / 255
                    let expected = (alpha == 255 ? a : a + a * (1 - a)) * 255
                    XCTAssertEqual(Float(pixels[offset+3]), expected, accuracy: 2,
                                   "x=\(x), y=\(y), alpha=\(alpha)")
                }
            }
        }
    }

    func testMetalCircleFillAndStrokeKeepDistinctCenters() throws {
        for inset: Float in [4, 21] {
            let mesh = try XCTUnwrap(ZTransferAndroidShadowMetrics.circleMesh(
                center: .init(24, 24), radius: 20, blurWidth: 4, insetWidth: inset))
            let pixels = try render([.init(mesh: mesh, alpha: 255)], width: 48, height: 48)
            let alpha = { (x: Int, y: Int) in pixels[(y * 48 + x) * 4 + 3] }
            XCTAssertEqual(alpha(0, 0), 0)
            XCTAssertEqual(alpha(24, 24), inset == 4 ? 0 : 250)
            XCTAssertGreaterThan(alpha(24, 5), 0)
            XCTAssertEqual(alpha(24, 47), 0)
        }
    }

    func testProjectedGeometryTracksLightAndPreservesTransparentFill() throws {
        typealias Metrics = ZTransferAndroidShadowMetrics
        let caster = Metrics.Caster(minimum: .init(20, 30), maximum: .init(120, 90), radius: 10)
        let left = try XCTUnwrap(Metrics.shadowGeometry(caster: caster, height: 10,
            light: .init(0, 0, 100), lightRadius: 90, transparent: false))
        let right = try XCTUnwrap(Metrics.shadowGeometry(caster: caster, height: 10,
            light: .init(90, 0, 100), lightRadius: 90, transparent: false))
        XCTAssertEqual(left.ambient.caster.minimum, .init(15, 25))
        XCTAssertEqual(left.ambient.caster.maximum, .init(125, 95))
        XCTAssertEqual(left.ambient.caster.radius, 15)
        XCTAssertEqual(left.ambient.blurWidth, 5.390625)
        XCTAssertEqual(left.ambient.insetWidth, 5)
        XCTAssertEqual(left.spot.blurWidth, 20, accuracy: 0.00001)
        // Moving the light 90px right moves the spot 10px left, with no
        // change in ambient geometry. This tests the coordinate convention.
        XCTAssertEqual(right.spot.caster.minimum.x - left.spot.caster.minimum.x, -10, accuracy: 0.00001)
        XCTAssertEqual(right.spot.caster.minimum.y, left.spot.caster.minimum.y)
        XCTAssertEqual(right.ambient.caster.minimum, left.ambient.caster.minimum)
        let transparent = try XCTUnwrap(Metrics.shadowGeometry(caster: caster, height: 10,
            light: .init(0, 0, 100), lightRadius: 90, transparent: true))
        XCTAssertEqual(try XCTUnwrap(transparent.ambient.mesh()).kind, .fill)
        XCTAssertEqual(try XCTUnwrap(transparent.spot.mesh()).kind, .fill)
        XCTAssertEqual(try XCTUnwrap(left.ambient.mesh()).kind, .stroke)
    }

    func testProjectionScaleTranslationAndCircleRoundoff() throws {
        typealias Metrics = ZTransferAndroidShadowMetrics
        let caster = Metrics.Caster(minimum: .init(0, 0), maximum: .init(40, 40), radius: 20)
        let pair = try XCTUnwrap(Metrics.shadowGeometry(caster: caster, height: 10,
            light: .init(90, 0, 100), lightRadius: 90, scale: 2,
            translation: .init(100, 200), transparent: false))
        XCTAssertEqual(pair.ambient.caster.minimum, .init(95, 195))
        XCTAssertEqual(pair.ambient.caster.maximum, .init(185, 285))
        XCTAssertEqual(pair.ambient.insetWidth, 10)
        XCTAssertEqual(pair.ambient.blurWidth, 5.390625)
        XCTAssertEqual(pair.spot.caster.minimum.x, 91.11111, accuracy: 0.00002)
        XCTAssertEqual(pair.spot.caster.minimum.y, 212.22222, accuracy: 0.00002)
        XCTAssertTrue(pair.spot.isCircle)
        XCTAssertEqual(try XCTUnwrap(pair.spot.mesh()).vertices.count, 16)
        XCTAssertNil(Metrics.shadowGeometry(caster: caster, height: 0,
            light: .init(0, 0, 100), lightRadius: 90, transparent: false))
        XCTAssertNil(Metrics.shadowGeometry(caster: caster, height: 10,
            light: .init(0, 0, 100), lightRadius: 90, scale: 0, transparent: false))
    }

    func testMaterialLightUsesDisplayWindowAndDensity() throws {
        typealias Metrics = ZTransferAndroidShadowMetrics
        let portrait = try XCTUnwrap(Metrics.materialLighting(displayPixels: .init(900, 1800), density: 2,
                                                              windowOriginPixels: .init(30, 50)))
        XCTAssertEqual(portrait.center, .init(420, -50, 1000))
        XCTAssertEqual(portrait.radius, 1600)
        XCTAssertEqual(portrait.ambientAlpha, 9)
        XCTAssertEqual(portrait.spotAlpha, 48)
        let landscape = try XCTUnwrap(Metrics.materialLighting(displayPixels: .init(1800, 900), density: 2))
        XCTAssertEqual(landscape.center, .init(900, 0, 1000))
        let small = try XCTUnwrap(Metrics.materialLighting(displayPixels: .init(720, 1600), density: 2))
        XCTAssertEqual(small.center.z, 933.3333, accuracy: 0.0001)
        XCTAssertNil(Metrics.materialLighting(displayPixels: .init(900, 1800), density: 0))
    }

    func testShadowOpacityQuantizesBeforeCasterOpacity() throws {
        typealias Metrics = ZTransferAndroidShadowMetrics
        let light = try XCTUnwrap(Metrics.materialLighting(displayPixels: .init(900, 1800), density: 2))
        let opaque = try XCTUnwrap(Metrics.opacity(lighting: light, nodeAlpha: 1, outlineAlpha: 1))
        XCTAssertEqual(opaque.ambient, 9)
        XCTAssertEqual(opaque.spot, 48)
        XCTAssertFalse(opaque.transparentOccluder)
        let faded = try XCTUnwrap(Metrics.opacity(lighting: light, nodeAlpha: 0.5, outlineAlpha: 0.5))
        XCTAssertEqual(faded.ambient, 2)
        XCTAssertEqual(faded.spot, 12)
        XCTAssertTrue(faded.transparentOccluder)
        let hidden = try XCTUnwrap(Metrics.opacity(lighting: light, nodeAlpha: 0, outlineAlpha: 1))
        XCTAssertEqual(hidden.ambient, 0)
        XCTAssertEqual(hidden.spot, 0)
        XCTAssertNil(Metrics.opacity(lighting: light, nodeAlpha: .nan, outlineAlpha: 1))
    }

    func testQueueCardShadowAppliesColorAlphaAfterMaterialLighting() throws {
        typealias Metrics = ZTransferAndroidShadowMetrics
        let light = try XCTUnwrap(Metrics.materialLighting(displayPixels: .init(900, 1800), density: 2,
            shadowColors: .init(ambientAlpha: 20, spotAlpha: 31)))
        let opaque = try XCTUnwrap(Metrics.opacity(lighting: light, nodeAlpha: 1, outlineAlpha: 1))
        // Android15 multiplyAlpha: uint8((9/255)*20), uint8((48/255)*31).
        XCTAssertEqual(opaque.ambient, 0)
        XCTAssertEqual(opaque.spot, 5)
        XCTAssertFalse(opaque.transparentOccluder, "Color alpha does not make the caster transparent")
        let faded = try XCTUnwrap(Metrics.opacity(lighting: light, nodeAlpha: 0.5, outlineAlpha: 1))
        XCTAssertEqual(faded.spot, 2)
        XCTAssertTrue(faded.transparentOccluder)
    }

    func testCroppedSceneMatchesFullWindowRendering() throws {
        typealias Metrics = ZTransferAndroidShadowMetrics
        typealias Renderer = ZTransferAndroidShadowRenderer
        let light = try XCTUnwrap(Metrics.materialLighting(displayPixels: .init(400, 800), density: 1))
        let caster = Metrics.Caster(minimum: .init(60.25, 70.5), maximum: .init(140.25, 110.5), radius: 20)
        for nodeAlpha: Float in [1, 0.5] {
            let scene = try XCTUnwrap(Renderer.scene(caster: caster, elevation: 6,
                                                     lighting: light, nodeAlpha: nodeAlpha))
            let opacity = try XCTUnwrap(Metrics.opacity(lighting: light, nodeAlpha: nodeAlpha, outlineAlpha: 1))
            let pair = try XCTUnwrap(Metrics.shadowGeometry(caster: caster, height: 6,
                light: light.center, lightRadius: light.radius, transparent: opacity.transparentOccluder))
            let windowLayers: [Renderer.Layer] = [
                .init(mesh: try XCTUnwrap(pair.ambient.mesh()), alpha: opacity.ambient),
                .init(mesh: try XCTUnwrap(pair.spot.mesh()), alpha: opacity.spot)
            ]
            let full = try render(windowLayers, width: 200, height: 180)
            let cropped = try render(scene.layers, width: scene.size.x, height: scene.size.y)
            XCTAssertLessThan(scene.size.x * scene.size.y, 200 * 180)
            let originX = Int(scene.origin.x), originY = Int(scene.origin.y)
            var maximumDifference = 0
            var visiblePixels = 0
            for y in 0..<180 {
                for x in 0..<200 {
                    let localX = x - originX, localY = y - originY
                    let expected = Int(full[(y * 200 + x) * 4 + 3])
                    let actual: Int
                    if (0..<scene.size.x).contains(localX), (0..<scene.size.y).contains(localY) {
                        actual = Int(cropped[(localY * scene.size.x + localX) * 4 + 3])
                    } else {
                        actual = 0
                    }
                    maximumDifference = max(maximumDifference, abs(actual - expected))
                    if expected > 0 { visiblePixels += 1 }
                }
            }
            XCTAssertGreaterThan(visiblePixels, 100)
            XCTAssertLessThanOrEqual(maximumDifference, 1, "crop must retain the projected footprint")
        }
        XCTAssertNil(try Renderer.scene(caster: caster, elevation: 0, lighting: light))
        XCTAssertNil(try Renderer.scene(caster: caster, elevation: 6, lighting: light, nodeAlpha: 0))
        XCTAssertThrowsError(try Renderer.scene(caster: caster, elevation: 6, lighting: light, scale: -1))
    }

    @MainActor
    func testWindowShadowHostExpandsBoundsAndHandlesVisibility() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let controller = UIViewController()
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        let host = AndroidShadowHost()
        host.frame = CGRect(x: 80, y: 200, width: 200, height: 40)
        host.cornerRadius = 22
        host.elevation = 6
        controller.view.addSubview(host)
        host.setNeedsLayout()
        host.layoutIfNeeded()
        XCTAssertNil(host.renderingError)
        let metal = try XCTUnwrap(host.subviews.compactMap { $0 as? MTKView }.first)
        XCTAssertFalse(metal.isHidden)
        XCTAssertLessThan(metal.frame.minX, 0)
        XCTAssertLessThan(metal.frame.minY, 0)
        XCTAssertGreaterThan(metal.frame.maxX, host.bounds.width)
        XCTAssertGreaterThan(metal.frame.maxY, host.bounds.height)
        XCTAssertEqual(metal.drawableSize.width, (metal.frame.width * window.screen.scale).rounded(), accuracy: 0.001)
        let before = metal.frame
        host.frame.origin.y += 100
        host.setNeedsLayout()
        host.layoutIfNeeded()
        XCTAssertNil(host.renderingError)
        XCTAssertGreaterThan(metal.frame.maxY, before.maxY)
        host.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        host.setNeedsLayout()
        host.layoutIfNeeded()
        XCTAssertNil(host.renderingError)
        XCTAssertFalse(metal.isHidden)
        XCTAssertEqual(metal.drawableSize.width, metal.frame.width * window.screen.scale * 0.8, accuracy: 0.1)
        XCTAssertEqual(metal.drawableSize.height, metal.frame.height * window.screen.scale * 0.8, accuracy: 0.1)
        let globalOrigin = metal.convert(CGPoint.zero, to: window)
        XCTAssertEqual(globalOrigin.x * window.screen.scale,
                       (globalOrigin.x * window.screen.scale).rounded(), accuracy: 0.01)
        XCTAssertEqual(globalOrigin.y * window.screen.scale,
                       (globalOrigin.y * window.screen.scale).rounded(), accuracy: 0.01)
        let affineTransforms = [CGFloat.pi / 2, CGFloat.pi, -CGFloat.pi / 2, 0.17, 0.0001].map {
            CGAffineTransform(rotationAngle: $0).scaledBy(x: 0.8, y: 0.8)
        } + [CGAffineTransform(scaleX: 0.8, y: 0.7), CGAffineTransform(scaleX: -0.8, y: 0.7),
             CGAffineTransform(scaleX: 1, y: 1 + 1 / 8192),
             CGAffineTransform(a: 0, b: 1 + 1 / 8192, c: -1, d: 0, tx: 0, ty: 0),
             CGAffineTransform(a: 1, b: 0.1, c: 0.2, d: 0.8, tx: 0, ty: 0)]
        host.bounds.origin = CGPoint(x: 4, y: 7)
        for transform in affineTransforms {
            host.transform = transform
            host.setNeedsLayout()
            host.layoutIfNeeded()
            XCTAssertNil(host.renderingError)
            XCTAssertFalse(metal.isHidden)
            let start = metal.convert(CGPoint.zero, to: window)
            let across = metal.convert(CGPoint(x: metal.bounds.width, y: 0), to: window)
            let down = metal.convert(CGPoint(x: 0, y: metal.bounds.height), to: window)
            XCTAssertEqual((across.x - start.x) * window.screen.scale, metal.drawableSize.width, accuracy: 0.1)
            XCTAssertEqual(across.y, start.y, accuracy: 0.001)
            XCTAssertEqual((down.y - start.y) * window.screen.scale, metal.drawableSize.height, accuracy: 0.1)
            XCTAssertEqual(down.x, start.x, accuracy: 0.001)
            let sourceOrigin = host.convert(host.bounds.origin, to: window)
            let matrix = ZTransferShadowTransform(
                x: .init(Float(transform.a), Float(transform.c), Float(sourceOrigin.x * window.screen.scale)),
                y: .init(Float(transform.b), Float(transform.d), Float(sourceOrigin.y * window.screen.scale)),
                perspective: .init(0, 0, 1))
            if matrix.supportsAnalyticShadow {
                let density = window.screen.scale
                let windowOrigin = window.convert(CGPoint.zero, to: window.screen.coordinateSpace)
                let lighting = try XCTUnwrap(ZTransferAndroidShadowMetrics.materialLighting(
                    displayPixels: .init(Float(window.screen.bounds.width * density), Float(window.screen.bounds.height * density)),
                    density: Float(density), windowOriginPixels: .init(Float(windowOrigin.x * density), Float(windowOrigin.y * density))))
                let expected = try XCTUnwrap(ZTransferAndroidShadowRenderer.scene(
                    caster: .init(minimum: .zero, maximum: .init(Float(host.bounds.width * density), Float(host.bounds.height * density)),
                                  radius: Float(min(host.cornerRadius, min(host.bounds.width, host.bounds.height) * 0.5) * density)),
                    elevation: Float(host.elevation * density), lighting: lighting, transform: matrix))
                XCTAssertEqual(metal.drawableSize.width, CGFloat(expected.size.x))
                XCTAssertEqual(metal.drawableSize.height, CGFloat(expected.size.y))
                XCTAssertEqual(start.x * density, CGFloat(expected.origin.x), accuracy: 0.01)
                XCTAssertEqual(start.y * density, CGFloat(expected.origin.y), accuracy: 0.01)
            }
        }
        host.transform = CGAffineTransform(scaleX: 0, y: 0.7)
        host.setNeedsLayout()
        host.layoutIfNeeded()
        XCTAssertNotNil(host.renderingError)
        XCTAssertTrue(metal.isHidden)
        host.transform = .identity
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 500
        host.layer.transform = CATransform3DRotate(perspective, 0.2, 0, 1, 0)
        host.setNeedsLayout()
        host.layoutIfNeeded()
        XCTAssertNotNil(host.renderingError)
        XCTAssertTrue(metal.isHidden)
        host.layer.transform = CATransform3DIdentity
        host.elevation = 0
        host.setNeedsLayout()
        host.layoutIfNeeded()
        XCTAssertNil(host.renderingError)
        XCTAssertTrue(metal.isHidden)
    }

    func testQuarterTurnProjectionRotatesLightAndKeepsBlurInDeviceSpace() throws {
        typealias Metrics = ZTransferAndroidShadowMetrics
        let caster = Metrics.Caster(minimum: .init(10, 20), maximum: .init(90, 60), radius: 12)
        let light = SIMD2<Float>(120, -70)
        let reference = try XCTUnwrap(Metrics.shadowGeometry(caster: caster, height: 6,
            light: .init(light.x, light.y, 500), lightRadius: 800, scale: 1.25, transparent: false))
        for rotation in Metrics.QuarterTurn.allCases {
            let reflectedLight = rotation.apply(.init(-light.x, light.y))
            let result = try XCTUnwrap(Metrics.shadowGeometry(caster: caster, height: 6,
                light: .init(reflectedLight.x, reflectedLight.y, 500), lightRadius: 800, scale: 1.25,
                rotation: rotation, reflected: true, transparent: false))
            for (actual, expected) in [(result.ambient, reference.ambient), (result.spot, reference.spot)] {
                let a = rotation.apply(.init(-expected.caster.minimum.x, expected.caster.minimum.y))
                let b = rotation.apply(.init(-expected.caster.maximum.x, expected.caster.maximum.y))
                XCTAssertEqual(actual.caster.minimum, .init(min(a.x, b.x), min(a.y, b.y)))
                XCTAssertEqual(actual.caster.maximum, .init(max(a.x, b.x), max(a.y, b.y)))
                XCTAssertEqual(actual.blurWidth, expected.blurWidth)
                XCTAssertEqual(actual.insetWidth, expected.insetWidth)
            }
        }
        for rotation in Metrics.QuarterTurn.allCases {
            let turnedLight = rotation.apply(light)
            let result = try XCTUnwrap(Metrics.shadowGeometry(caster: caster, height: 6,
                light: .init(turnedLight.x, turnedLight.y, 500), lightRadius: 800,
                scale: 1.25, rotation: rotation, transparent: false))
            for (actual, expected) in [(result.ambient, reference.ambient), (result.spot, reference.spot)] {
                let a = rotation.apply(expected.caster.minimum)
                let b = rotation.apply(expected.caster.maximum)
                XCTAssertEqual(actual.caster.minimum, .init(min(a.x, b.x), min(a.y, b.y)))
                XCTAssertEqual(actual.caster.maximum, .init(max(a.x, b.x), max(a.y, b.y)))
                XCTAssertEqual(actual.caster.radius, expected.caster.radius)
                XCTAssertEqual(actual.blurWidth, expected.blurWidth)
                XCTAssertEqual(actual.insetWidth, expected.insetWidth)
                XCTAssertNotNil(actual.mesh())
            }
        }
        let translated = try XCTUnwrap(Metrics.shadowGeometry(
            caster: .init(minimum: .zero, maximum: .init(40, 20), radius: 4), height: 10,
            light: .init(90, 0, 100), lightRadius: 90, scale: 2,
            translation: .init(100, 200), rotation: .clockwise, transparent: false))
        XCTAssertEqual(translated.spot.caster.minimum.x, 46.66667, accuracy: 0.00003)
        XCTAssertEqual(translated.spot.caster.minimum.y, 212.22222, accuracy: 0.00003)
        XCTAssertEqual(translated.spot.caster.maximum.x, 111.11111, accuracy: 0.00003)
        XCTAssertEqual(translated.spot.caster.maximum.y, 321.11111, accuracy: 0.00003)
    }

    func testTessellatedGaussianInterpolatesVertexAlphaWithoutLookupTexture() throws {
        typealias Renderer = ZTransferAndroidShadowRenderer
        let vertices: [Renderer.TessellatedVertex] = [
            .init(position: .init(0, 0), alpha: 0),
            .init(position: .init(256, 0), alpha: 255),
            .init(position: .init(256, 8), alpha: 255),
            .init(position: .init(0, 8), alpha: 0)
        ]
        for alpha: UInt8 in [255, 48] {
            let layer = Renderer.TessellatedLayer(vertices: vertices, indices: [0,1,2, 0,2,3], alpha: alpha)
            let pixels = try render([], width: 256, height: 8, tessellated: [layer])
            for x in 0..<256 {
                // GrFragmentProcessors android-15: exp(-4*(1-a)^2)-0.018.
                // Evaluate independently in Double; allow target half/UNORM rounding.
                let a = (Double(x) + 0.5) / 256
                let expected = (exp(-4 * (1-a) * (1-a)) - 0.018) * Double(alpha)
                for y in 0..<8 {
                    XCTAssertEqual(Double(pixels[(y * 256 + x) * 4 + 3]), expected, accuracy: 1)
                }
            }
        }
    }

    func testPolygonPreparationMatchesOriginalSkiaFunctions() throws {
        struct Case: Decodable {
            let input, points: [[Float]]
            let area, direction: Float
            let convex: Bool
            let centroid: [Float?]
        }
        struct Reference: Decodable { let cases: [Case] }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "android15-shadow-polygons", withExtension: "json"))
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        XCTAssertEqual(reference.cases.count, 14)
        for test in reference.cases {
            let actual = try XCTUnwrap(ZTransferShadowPolygon.prepare(test.input.map { .init($0[0], $0[1]) }))
            XCTAssertEqual(actual.points, test.points.map { .init($0[0], $0[1]) })
            XCTAssertEqual(actual.doubledArea, test.area, accuracy: 0.00001)
            XCTAssertEqual(actual.direction, test.direction)
            XCTAssertEqual(actual.isConvex, test.convex)
            for (value, expected) in zip([actual.centroid.x, actual.centroid.y], test.centroid) {
                if let expected { XCTAssertEqual(value, expected, accuracy: 0.00001) }
                else { XCTAssertFalse(value.isFinite) }
            }
        }
        XCTAssertNil(ZTransferShadowPolygon.prepare([.init(.infinity, 0)]))
    }

    func testBezierSubdivisionMatchesPinnedGaneshFunctions() throws {
        struct Case: Decodable { let input, points: [[Float]]; let limit: Int }
        struct Reference: Decodable { let cases: [Case] }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "android15-shadow-curves", withExtension: "json"))
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        XCTAssertEqual(reference.cases.count, 10)
        XCTAssertTrue(reference.cases.contains { $0.limit == 1024 })
        for test in reference.cases {
            let p: [SIMD2<Float>] = test.input.map { .init($0[0], $0[1]) }
            let actual = try XCTUnwrap(p.count == 3
                ? ZTransferShadowCurve.quadratic(p[0], p[1], p[2])
                : ZTransferShadowCurve.cubic(p[0], p[1], p[2], p[3]))
            XCTAssertEqual(actual.count, test.points.count)
            XCTAssertLessThanOrEqual(actual.count, 1024)
            for (point, expected) in zip(actual, test.points) {
                XCTAssertEqual(point, SIMD2<Float>(expected[0], expected[1]))
            }
        }
        XCTAssertNil(ZTransferShadowCurve.quadratic(.zero, .init(.nan, 1), .init(2, 0)))
    }

    func testConicQuadraticsAndPolylineMatchPinnedSkia() throws {
        struct Case: Decodable {
            let points, quads, line: [[Float]]
            let weight: Float
            let level: Int
        }
        struct Reference: Decodable { let cases: [Case] }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "android15-shadow-conics", withExtension: "json"))
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        XCTAssertEqual(reference.cases.count, 19)
        XCTAssertTrue(reference.cases.contains { $0.level == 5 && $0.quads.count == 5 })
        for test in reference.cases {
            let p: [SIMD2<Float>] = test.points.map { .init($0[0], $0[1]) }
            let quads = try XCTUnwrap(ZTransferShadowConic.quadratics(p[0], p[1], p[2], weight: test.weight))
            let line = try XCTUnwrap(ZTransferShadowConic.polyline(p[0], p[1], p[2], weight: test.weight))
            XCTAssertEqual(quads, test.quads.map { .init($0[0], $0[1]) })
            XCTAssertEqual(line, test.line.map { .init($0[0], $0[1]) })
            XCTAssertLessThanOrEqual(quads.count, 65)
        }
        XCTAssertNil(ZTransferShadowConic.quadratics(.zero, .init(1, 0), .init(1, 1), weight: -1))
        XCTAssertNil(ZTransferShadowConic.quadratics(.zero, .init(.infinity, 0), .init(1, 1), weight: 1))
    }

    @MainActor
    func testShadowFollowsPausedAncestorPresentationAndAnimationRemoval() async throws {
        let windowScene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        let controller = UIViewController()
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        let parent = UIView(frame: CGRect(x: 30, y: 100, width: 240, height: 80))
        controller.view.addSubview(parent)
        let host = AndroidShadowHost()
        host.frame = CGRect(x: 20, y: 15, width: 160, height: 40)
        host.cornerRadius = 18
        host.elevation = 6
        parent.addSubview(host)
        host.layoutIfNeeded()
        let metal = try XCTUnwrap(host.subviews.compactMap { $0 as? MTKView }.first)
        let originalSize = metal.drawableSize
        let originalCenter = metal.center
        let originalY = parent.layer.position.y
        // A fixed presentation time gives deterministic geometry while the model
        // remains at its old position. No host layout is requested after adding it.
        for progress in [0.25, 0.75] {
            let motion = CABasicAnimation(keyPath: "position.y")
            motion.fromValue = originalY
            motion.toValue = originalY + 400
            motion.duration = 1
            motion.speed = 0
            motion.timeOffset = progress
            motion.timingFunction = CAMediaTimingFunction(name: .linear)
            parent.layer.add(motion, forKey: "shadow-parent-position")
            let scale = CABasicAnimation(keyPath: "transform")
            scale.fromValue = CATransform3DIdentity
            scale.toValue = CATransform3DMakeScale(0.6, 0.6, 1)
            scale.duration = 1
            scale.speed = 0
            scale.timeOffset = progress
            scale.timingFunction = CAMediaTimingFunction(name: .linear)
            parent.layer.add(scale, forKey: "shadow-parent-scale")
            CATransaction.flush()
            var matched = false
            var observed = "no presentation tree"
            for _ in 0..<60 {
                try await Task.sleep(for: .milliseconds(20))
                observed = "parent=\(String(describing: parent.layer.presentation()?.position)), window=\(window.layer.presentation() != nil), host=\(host.layer.presentation() != nil)"
                guard let source = host.layer.presentation(), let target = window.layer.presentation(),
                      let displayedParent = parent.layer.presentation(),
                      abs(displayedParent.position.y - (originalY + 400 * progress)) < 0.01,
                      abs(displayedParent.transform.m11 - (1 - 0.4 * progress)) < 0.001 else { continue }
                let origin = source.convert(source.bounds.origin, to: target)
                let x = source.convert(CGPoint(x: source.bounds.maxX, y: source.bounds.minY), to: target)
                let y = source.convert(CGPoint(x: source.bounds.minX, y: source.bounds.maxY), to: target)
                let basisX = CGPoint(x: (x.x - origin.x) / source.bounds.width, y: (x.y - origin.y) / source.bounds.width)
                let basisY = CGPoint(x: (y.x - origin.x) / source.bounds.height, y: (y.y - origin.y) / source.bounds.height)
                let density = window.screen.scale
                let windowOrigin = window.convert(CGPoint.zero, to: window.screen.coordinateSpace)
                let lighting = try XCTUnwrap(ZTransferAndroidShadowMetrics.materialLighting(
                    displayPixels: .init(Float(window.screen.bounds.width * density), Float(window.screen.bounds.height * density)),
                    density: Float(density), windowOriginPixels: .init(Float(windowOrigin.x * density), Float(windowOrigin.y * density))))
                let expected = try XCTUnwrap(ZTransferAndroidShadowRenderer.scene(
                    caster: .init(minimum: .zero, maximum: .init(Float(host.bounds.width * density), Float(host.bounds.height * density)), radius: Float(18 * density)),
                    elevation: Float(6 * density), lighting: lighting,
                    transform: .init(x: .init(Float(basisX.x), Float(basisY.x), Float(origin.x * density)), y: .init(Float(basisX.y), Float(basisY.y), Float(origin.y * density)), perspective: .init(0, 0, 1))))
                let local = metal.layer.convert(metal.bounds.origin, to: host.layer)
                let displayed = source.convert(local, to: target)
                matched = metal.drawableSize == CGSize(width: expected.size.x, height: expected.size.y)
                    && abs(displayed.x * density - CGFloat(expected.origin.x)) < 0.02
                    && abs(displayed.y * density - CGFloat(expected.origin.y)) < 0.02
                observed += "; actual=\(metal.drawableSize) @ \(displayed), expected=\(expected.size) @ \(expected.origin)"
                if matched { break }
            }
            XCTAssertTrue(matched, "shadow must follow ancestor presentation at \(progress): \(observed)")
            XCTAssertNil(host.renderingError)
            XCTAssertTrue(metal.drawableSize != originalSize || metal.center != originalCenter)
        }
        parent.layer.removeAnimation(forKey: "shadow-parent-position")
        parent.layer.removeAnimation(forKey: "shadow-parent-scale")
        CATransaction.flush()
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(20))
            if metal.drawableSize == originalSize { break }
        }
        XCTAssertEqual(metal.drawableSize, originalSize)
        XCTAssertEqual(metal.center.x, originalCenter.x, accuracy: 0.01)
        XCTAssertEqual(metal.center.y, originalCenter.y, accuracy: 0.01)
        XCTAssertNil(host.renderingError)
        host.removeFromSuperview()
        XCTAssertTrue(metal.isHidden)
    }

    @MainActor
    func testShadowFrameClockDoesNotRetainRemovedHost() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = UIViewController()
        window.isHidden = false
        defer { window.isHidden = true }
        weak var weakHost: AndroidShadowHost?
        autoreleasepool {
            let host = AndroidShadowHost()
            weakHost = host
            host.frame = CGRect(x: 0, y: 0, width: 100, height: 40)
            host.elevation = 6
            window.rootViewController?.view.addSubview(host)
            host.layoutIfNeeded()
            host.removeFromSuperview()
        }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertNil(weakHost)
    }

    func testNearSimilaritySceneCropMatchesWindowOnGPU() throws {
        typealias Metrics = ZTransferAndroidShadowMetrics
        typealias Renderer = ZTransferAndroidShadowRenderer
        let lighting = try XCTUnwrap(Metrics.materialLighting(displayPixels: .init(400, 800), density: 1))
        let caster = Metrics.Caster(minimum: .zero, maximum: .init(40, 40), radius: 20)
        let near: Float = 1 + 1 / 8192
        for transform in [
            ZTransferShadowTransform(x: .init(1, 0, 90.125), y: .init(0, near, 80.5), perspective: .init(0, 0, 1)),
            ZTransferShadowTransform(x: .init(0, -1, 150.25), y: .init(near, 0, 80.5), perspective: .init(0, 0, 1))
        ] {
            for alpha: Float in [1, 0.5] {
                let scene = try XCTUnwrap(Renderer.scene(caster: caster, elevation: 6,
                    lighting: lighting, nodeAlpha: alpha, transform: transform))
                let opacity = try XCTUnwrap(Metrics.opacity(lighting: lighting, nodeAlpha: alpha, outlineAlpha: 1))
                let pair = try XCTUnwrap(Metrics.shadowGeometry(caster: caster, height: 6,
                    light: lighting.center, lightRadius: lighting.radius, transform: transform,
                    transparent: opacity.transparentOccluder))
                let full = try render([
                    .init(mesh: try XCTUnwrap(pair.ambient.mesh()), alpha: opacity.ambient),
                    .init(mesh: try XCTUnwrap(pair.spot.mesh()), alpha: opacity.spot)
                ], width: 240, height: 200)
                let cropped = try render(scene.layers, width: scene.size.x, height: scene.size.y)
                var visible = 0, maximumDifference = 0
                for y in 0..<200 {
                    for x in 0..<240 {
                        let localX = x - Int(scene.origin.x), localY = y - Int(scene.origin.y)
                        let expected = Int(full[(y * 240 + x) * 4 + 3])
                        let actual = (0..<scene.size.x).contains(localX) && (0..<scene.size.y).contains(localY)
                            ? Int(cropped[(localY * scene.size.x + localX) * 4 + 3]) : 0
                        maximumDifference = max(maximumDifference, abs(actual - expected))
                        if expected > 0 { visible += 1 }
                    }
                }
                XCTAssertGreaterThan(visible, 100)
                XCTAssertLessThanOrEqual(maximumDifference, 1)
            }
        }
    }

    func testLargeSigmaRescalePlansMatchPinnedSkia() throws {
        struct Case: Decodable {
            let size, destination, rescaled, blurBounds: [Int]
            let sigma, scale, scaledSigma, reexpandBounds: [Float]
            let steps: [[Int]]
            let padded: Bool
        }
        struct Reference: Decodable { let cases: [Case] }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "android15-shadow-rescale", withExtension: "json"))
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        XCTAssertEqual(reference.cases.count, 120)
        for (index, test) in reference.cases.enumerated() {
            let b = test.destination
            let plan = try XCTUnwrap(ZTransferShadowBlur.rescalePlan(sourceSize: .init(test.size[0], test.size[1]),
                destinationBounds: .init(b[0], b[1], b[2], b[3]), sigma: .init(test.sigma[0], test.sigma[1]), paddedUpscale: test.padded))
            XCTAssertEqual(plan.size, SIMD2(test.rescaled[0], test.rescaled[1]), "case \(index)")
            XCTAssertEqual(plan.paddedSize, SIMD2(test.rescaled[0] + 2, test.rescaled[1] + 2))
            XCTAssertEqual(plan.scale, SIMD2(test.scale[0], test.scale[1]))
            XCTAssertEqual(plan.sigma, SIMD2(test.scaledSigma[0], test.scaledSigma[1]))
            XCTAssertEqual(plan.blurBounds, SIMD4(test.blurBounds[0], test.blurBounds[1], test.blurBounds[2], test.blurBounds[3]))
            XCTAssertEqual(plan.reexpandBounds, SIMD4(test.reexpandBounds[0], test.reexpandBounds[1], test.reexpandBounds[2], test.reexpandBounds[3]))
            XCTAssertEqual(plan.repeatedLinearSizes, test.steps.map { .init($0[0], $0[1]) })
        }
        let tiny = try XCTUnwrap(ZTransferShadowBlur.rescalePlan(sourceSize: .init(1, 1), destinationBounds: .init(0, 0, 1, 1), sigma: .init(800, 1200), paddedUpscale: false))
        XCTAssertEqual(tiny.sigma, .init(800, 1200), "raw rescale stage preserves sigma; GaussianBlur must first normalize one-pixel clamp axes")
        XCTAssertNil(ZTransferShadowBlur.rescalePlan(sourceSize: .zero, destinationBounds: .init(0, 0, 1, 1), sigma: .init(8, 8), paddedUpscale: false))
        XCTAssertNil(ZTransferShadowBlur.rescalePlan(sourceSize: .init(10, 10), destinationBounds: .init(0, 0, 10, 10), sigma: .init(4, 4), paddedUpscale: false))
    }

    func testMaskCoverageCompositionClipAndPreservedTarget() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try ZTransferAndroidShadowRenderer(device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        func texture(_ w: Int, _ h: Int, _ format: MTLPixelFormat, _ usage: MTLTextureUsage) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.storageMode = .shared; d.usage = usage
            return try XCTUnwrap(device.makeTexture(descriptor: d))
        }
        let first = try texture(4, 4, .r8Unorm, .shaderRead)
        let second = try texture(3, 2, .r8Unorm, .shaderRead)
        // Padding is opaque on purpose: it must never expand the drawn content.
        let a: [UInt8] = [0, 255, 255, 255, 128, 64, 255, 255, 255, 128, 255, 255, 255, 255, 255, 255]
        let b: [UInt8] = [255, 128, 0, 64, 192, 255]
        a.withUnsafeBytes { first.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 4) }
        b.withUnsafeBytes { second.replace(region: MTLRegionMake2D(0, 0, 3, 2), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 3) }
        func read(_ target: MTLTexture) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 7 * 6 * 4)
            bytes.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 28, from: MTLRegionMake2D(0, 0, 7, 6), mipmapLevel: 0) }
            return bytes
        }
        for preserve in [false, true] {
            for (alphaA, alphaB): (UInt8, UInt8) in [(9, 48), (128, 255)] {
                let layers: [ZTransferAndroidShadowRenderer.MaskLayer] = [
                    .init(texture: first, size: .init(2, 3), origin: .init(-1, 2), alpha: alphaA),
                    .init(texture: second, size: .init(3, 2), origin: .init(0, 2), alpha: alphaB)]
                var results: [[UInt8]] = []
                for separate in [false, true] {
                    let target = try texture(7, 6, .bgra8Unorm, [.renderTarget, .shaderRead])
                    let initial = Array(repeating: [UInt8](arrayLiteral: 40, 20, 10, 128), count: 42).flatMap { $0 }
                    initial.withUnsafeBytes { target.replace(region: MTLRegionMake2D(0, 0, 7, 6), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 28) }
                    let command = try XCTUnwrap(queue.makeCommandBuffer())
                    if separate {
                        try renderer.encodeMasks(layers: [layers[0]], destination: target, preserveContents: preserve, commandBuffer: command)
                        try renderer.encodeMasks(layers: [layers[1]], destination: target, preserveContents: true, commandBuffer: command)
                    } else {
                        try renderer.encodeMasks(layers: layers, destination: target, preserveContents: preserve, commandBuffer: command)
                    }
                    command.commit(); command.waitUntilCompleted()
                    XCTAssertEqual(command.status, .completed)
                    results.append(read(target))
                }
                XCTAssertEqual(results[0], results[1], "separate mask passes must preserve previous coverage")
                var expected = [UInt8](repeating: 0, count: 168)
                for y in 0..<6 { for x in 0..<7 {
                    var pixel: [Float] = preserve ? [40, 20, 10, 128] : [0, 0, 0, 0]
                    for (i, layer) in layers.enumerated() {
                        let sx = x - layer.origin.x, sy = y - layer.origin.y
                        guard sx >= 0, sy >= 0, sx < layer.size.x, sy < layer.size.y else { continue }
                        let coverage = i == 0 ? a[sy * 4 + sx] : b[sy * 3 + sx]
                        let alpha = Float(Float16(Float(coverage) / 255) * Float16(Float(layer.alpha) / 255))
                        for channel in 0..<3 { pixel[channel] = (pixel[channel] * (1 - alpha)).rounded() }
                        pixel[3] = (alpha * 255 + pixel[3] * (1 - alpha)).rounded()
                    }
                    for channel in 0..<4 { expected[(y * 7 + x) * 4 + channel] = UInt8(pixel[channel]) }
                } }
                XCTAssertLessThanOrEqual(zip(results[0], expected).map { abs(Int($0) - Int($1)) }.max() ?? 0, 1)
            }
        }
        let target = try texture(7, 6, .bgra8Unorm, .renderTarget)
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertThrowsError(try renderer.encodeMasks(layers: [.init(texture: first, size: .init(5, 1), origin: .zero, alpha: 255)],
            destination: target, commandBuffer: command))
        // Reusing the same command after invalid input must still be possible.
        try renderer.encodeMasks(layers: [], destination: target, commandBuffer: command)
        command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        XCTAssertTrue(read(target).allSatisfy { $0 == 0 })
    }

    func testTessellatedLayerCanFollowMaskWithoutErasingIt() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try ZTransferAndroidShadowRenderer(device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let maskDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
        maskDescriptor.storageMode = .shared; maskDescriptor.usage = .shaderRead
        let mask = try XCTUnwrap(device.makeTexture(descriptor: maskDescriptor))
        var white: UInt8 = 255
        mask.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &white, bytesPerRow: 1)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 7, height: 6, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = .renderTarget
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        try renderer.encodeMasks(layers: [.init(texture: mask, size: .init(1, 1), origin: .init(0, 2), alpha: 255)],
            destination: target, commandBuffer: command)
        let triangle = ZTransferAndroidShadowRenderer.TessellatedLayer(vertices: [
            .init(position: .init(4, 0), alpha: 255), .init(position: .init(7, 0), alpha: 255),
            .init(position: .init(7, 3), alpha: 255)], indices: [0, 1, 2], alpha: 255)
        try renderer.encodeTessellated(layers: [triangle], destination: target, preserveContents: true, commandBuffer: command)
        command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        var pixels = [UInt8](repeating: 0, count: 168)
        pixels.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 28,
            from: MTLRegionMake2D(0, 0, 7, 6), mipmapLevel: 0) }
        XCTAssertEqual(pixels[(2 * 7) * 4 + 3], 255)
        XCTAssertGreaterThan(pixels[6 * 4 + 3], 0)
        XCTAssertEqual(pixels[3], 0)
    }

    func testDirectRectangleBlurPixelsAndPreservedComposition() throws {
        struct Case: Decodable { let sigma: Float; let pixels: [UInt8] }
        struct Fixture: Decodable { let cases: [Case] }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "android15-shadow-integral", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try ZTransferAndroidShadowRenderer(device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let bounds: [SIMD4<Float>] = [.init(7.25, 8.25, 25.25, 26.25), .init(14.25, 8, 14.75, 26),
                                      .init(14.25, 15.25, 14.75, 15.75), .init(-8, -3, 10, 19)]
        for sigma: Float in [1, 4, 16] {
            let table = try XCTUnwrap(fixture.cases.first { $0.sigma == sigma }).pixels
            func lookup(_ distance: Float) -> Float16 {
                let t = max(0, min(Float(table.count - 1), Float(Float16(distance)) * (Float(table.count) / (6 * sigma)) - 0.5))
                let i = Int(floor(t)), j = min(i + 1, table.count - 1), fraction = t - Float(i)
                return Float16((Float(table[i]) * (1 - fraction) + Float(table[j]) * fraction) / 255)
            }
            for rect in bounds {
                for preserve in [false, true] {
                    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 32, height: 32, mipmapped: false)
                    descriptor.storageMode = .shared; descriptor.usage = .renderTarget
                    let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
                    let initial: [UInt8] = (0..<1024).flatMap { _ in [40, 20, 10, 128] as [UInt8] }
                    initial.withUnsafeBytes { target.replace(region: MTLRegionMake2D(0, 0, 32, 32), mipmapLevel: 0,
                        withBytes: $0.baseAddress!, bytesPerRow: 128) }
                    let command = try XCTUnwrap(queue.makeCommandBuffer())
                    try renderer.encodeBlurredRectangles(layers: [.init(bounds: rect, sigma: sigma, alpha: 48)],
                        destination: target, preserveContents: preserve, commandBuffer: command)
                    command.commit(); command.waitUntilCompleted()
                    XCTAssertEqual(command.status, .completed)
                    var pixels = [UInt8](repeating: 0, count: 4096)
                    pixels.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 128,
                        from: MTLRegionMake2D(0, 0, 32, 32), mipmapLevel: 0) }
                    let radius = 3 * sigma
                    let fast = rect.x + radius <= rect.z - radius && rect.y + radius <= rect.w - radius
                    for y in 0..<32 { for x in 0..<32 {
                        let px = Float(x) + 0.5, py = Float(y) + 0.5
                        var alpha: Float = 0
                        if px >= rect.x - radius && px < rect.z + radius && py >= rect.y - radius && py < rect.w + radius {
                            let l = rect.x + radius - px, r = px - (rect.z - radius)
                            let t = rect.y + radius - py, b = py - (rect.w - radius)
                            let cx: Float16 = fast ? lookup(max(l, r)) : 1 - lookup(l) - lookup(r)
                            let cy: Float16 = fast ? lookup(max(t, b)) : 1 - lookup(t) - lookup(b)
                            alpha = max(0, min(1, Float((cx * cy) * Float16(Float(48) / 255))))
                        }
                        let old = preserve ? [40, 20, 10, 128] : [0, 0, 0, 0]
                        for c in 0..<4 {
                            let expected = Int((Float(old[c]) * (1 - alpha) + (c == 3 ? alpha * 255 : 0)).rounded())
                            XCTAssertLessThanOrEqual(abs(Int(pixels[(y * 32 + x) * 4 + c]) - expected), 2,
                                "sigma=\(sigma), rect=\(rect), preserve=\(preserve), pixel=\(x),\(y), channel=\(c)")
                        }
                    } }
                }
            }
        }
    }

    func testDirectCircleBlurUsesOriginalProfileAndHalfCoordinates() throws {
        struct Case: Decodable {
            let radius: Float; let sigma: Float
            let solidRadius: Float; let textureRadius: Float; let pixels: [UInt8]
        }
        struct Fixture: Decodable { let cases: [Case] }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "android15-shadow-circle-profile", withExtension: "json"))
        let cases = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).cases.filter { $0.radius <= 32 }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try ZTransferAndroidShadowRenderer(device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        for item in cases {
            for center: SIMD2<Float> in [.init(16.25, 15.75), .init(-2.5, 4.5)] {
                for preserve in [false, true] {
                    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 32, height: 32, mipmapped: false)
                    descriptor.storageMode = .shared; descriptor.usage = .renderTarget
                    let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
                    let initial: [UInt8] = (0..<1024).flatMap { _ in [40, 20, 10, 128] as [UInt8] }
                    initial.withUnsafeBytes { target.replace(region: MTLRegionMake2D(0, 0, 32, 32), mipmapLevel: 0,
                        withBytes: $0.baseAddress!, bytesPerRow: 128) }
                    let command = try XCTUnwrap(queue.makeCommandBuffer())
                    try renderer.encodeBlurredCircles(layers: [.init(center: center, radius: item.radius, sigma: item.sigma, alpha: 255)],
                        destination: target, preserveContents: preserve, commandBuffer: command)
                    command.commit(); command.waitUntilCompleted()
                    XCTAssertEqual(command.status, .completed)
                    var pixels = [UInt8](repeating: 0, count: 4096)
                    pixels.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 128,
                        from: MTLRegionMake2D(0, 0, 32, 32), mipmapLevel: 0) }
                    let cx = Float(Float16(center.x)), cy = Float(Float16(center.y))
                    let inverse = Float16(1 / item.textureRadius), solid = Float16(item.solidRadius)
                    let extent = item.radius + 3 * item.sigma
                    for y in 0..<32 { for x in 0..<32 {
                        let px = Float(x) + 0.5, py = Float(y) + 0.5
                        var alpha: Float = 0
                        var alphaRange: ClosedRange<Float> = 0...0
                        if px >= center.x - extent && px < center.x + extent && py >= center.y - extent && py < center.y + extent {
                            let vx = Float16((px - cx) * Float(inverse)), vy = Float16((py - cy) * Float(inverse))
                            let distance = Float16(sqrtf(Float(vx * vx + vy * vy))) + (Float16(0.5) - solid) * inverse
                            let index = max(0, min(511, Int(floor(Float(distance) * 512))))
                            alpha = Float(Float16(Float(item.pixels[index]) / 255))
                            // One half ULP in length can straddle a nearest-texel boundary.
                            // Bound the coordinate error, rather than allowing arbitrary
                            // three-byte errors across the entire rendered image.
                            let low = max(0, min(511, Int(floor(Float(distance.nextDown) * 512))))
                            let high = max(0, min(511, Int(floor(Float(distance.nextUp) * 512))))
                            let samples = item.pixels[low...high].map { Float(Float16(Float($0) / 255)) }
                            alphaRange = samples.min()!...samples.max()!
                        }
                        let old = preserve ? [40, 20, 10, 128] : [0, 0, 0, 0]
                        for c in 0..<4 {
                            let expected = Int((Float(old[c]) * (1 - alpha) + (c == 3 ? alpha * 255 : 0)).rounded())
                            let endpoints = [alphaRange.lowerBound, alphaRange.upperBound].map { a in
                                Int((Float(old[c]) * (1 - a) + (c == 3 ? a * 255 : 0)).rounded())
                            }
                            let actual = Int(pixels[(y * 32 + x) * 4 + c])
                            XCTAssertTrue(actual >= endpoints.min()! - 2 && actual <= endpoints.max()! + 2,
                                "radius=\(item.radius), sigma=\(item.sigma), pixel=\(x),\(y), c=\(c), actual=\(actual), central=\(expected)")
                        }
                    } }
                }
            }
        }
    }

    func testRoundedRectangleMaskCacheRespectsCommandLifetimeAndBudget() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let blur = try ZTransferShadowBlurRenderer(device: device, maximumCachedMaskBytes: 600)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        func plan(_ radius: Float, sigma: Float = 1, offset: Float = 0) throws -> ZTransferShadowBlur.RoundedRectanglePlan {
            try XCTUnwrap(ZTransferShadowBlur.roundedRectanglePlan(
                bounds: .init(offset, offset, offset + 80, offset + 96), radius: radius, sigma: sigma))
        }
        let firstPlan = try plan(1.25)
        let pending = try XCTUnwrap(queue.makeCommandBuffer())
        let first = try blur.roundedRectangleMask(plan: firstPlan, maximumSurfaceBytes: 4096, commandBuffer: pending)
        let shifted = try plan(1.75, sigma: 1.1, offset: 12)
        XCTAssertNotEqual(firstPlan.proxyRectangle, shifted.proxyRectangle)
        XCTAssertNotEqual(firstPlan.sigma, shifted.sigma)
        XCTAssertTrue(first === (try blur.roundedRectangleMask(plan: shifted, maximumSurfaceBytes: 0, commandBuffer: pending)))

        // The first command is deliberately never submitted. A different command
        // must generate its own mask rather than reading undefined GPU contents.
        let submitted = try XCTUnwrap(queue.makeCommandBuffer())
        let second = try blur.roundedRectangleMask(plan: firstPlan, maximumSurfaceBytes: 4096, commandBuffer: submitted)
        XCTAssertFalse(first === second)
        submitted.commit(); submitted.waitUntilCompleted()
        XCTAssertEqual(submitted.status, .completed)
        let next = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(second === (try blur.roundedRectangleMask(plan: shifted, maximumSurfaceBytes: 0, commandBuffer: next)))
        let other = try blur.roundedRectangleMask(plan: plan(0.75), maximumSurfaceBytes: 4096, commandBuffer: next)
        XCTAssertFalse(other === second)
        // Refresh the first entry, then exceed the 600-byte retained pixel budget.
        XCTAssertTrue(second === (try blur.roundedRectangleMask(plan: firstPlan, maximumSurfaceBytes: 0, commandBuffer: next)))
        _ = try blur.roundedRectangleMask(plan: plan(2.25), maximumSurfaceBytes: 4096, commandBuffer: next)
        XCTAssertThrowsError(try blur.roundedRectangleMask(plan: firstPlan, maximumSurfaceBytes: 0, commandBuffer: next))
        let recreated = try blur.roundedRectangleMask(plan: firstPlan, maximumSurfaceBytes: 4096, commandBuffer: next)
        XCTAssertFalse(recreated === second)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,
            width: second.width, height: second.height, mipmapped: false)
        descriptor.storageMode = .shared
        let oldRead = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let newRead = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let blit = try XCTUnwrap(next.makeBlitCommandEncoder())
        for (source, destination) in [(second, oldRead), (recreated, newRead)] {
            blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
                sourceSize: .init(width: source.width, height: source.height, depth: 1),
                to: destination, destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init(x: 0, y: 0, z: 0))
        }
        blit.endEncoding()
        next.commit(); next.waitUntilCompleted()
        XCTAssertEqual(next.status, .completed)
        func pixels(_ texture: MTLTexture) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: texture.width * texture.height)
            bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: texture.width,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0) }
            return bytes
        }
        XCTAssertEqual(pixels(oldRead), pixels(newRead))
        XCTAssertTrue(pixels(newRead).contains { $0 > 0 })
    }

    func testRoundedRectangleDrawProxyRoundsOutWithoutChangingSamplingBounds() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try ZTransferAndroidShadowRenderer(device: device)
        let plan = try XCTUnwrap(ZTransferShadowBlur.roundedRectanglePlan(
            bounds: .init(4.75, 4.75, 20.25, 24.25), radius: 2, sigma: 0.04))
        XCTAssertEqual(plan.proxyRectangle, .init(4.75, 4.75, 20.25, 24.25))
        XCTAssertEqual(plan.drawRectangle, .init(4, 4, 21, 25))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,
            width: plan.textureSize.x, height: plan.textureSize.y, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = .shaderRead
        let mask = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let bytes = [UInt8](repeating: 255, count: mask.width * mask.height)
        bytes.withUnsafeBytes { mask.replace(region: MTLRegionMake2D(0, 0, mask.width, mask.height),
            mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: mask.width) }
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: 32, height: 32, mipmapped: false)
        targetDescriptor.storageMode = .shared; targetDescriptor.usage = .renderTarget
        let target = try XCTUnwrap(device.makeTexture(descriptor: targetDescriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue()), command = try XCTUnwrap(queue.makeCommandBuffer())
        try renderer.encodeRoundedRectangleMasks(layers: [.init(plan: plan, mask: mask, alpha: 255)],
            destination: target, commandBuffer: command)
        command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        pixels.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 128,
            from: MTLRegionMake2D(0, 0, 32, 32), mipmapLevel: 0) }
        for y in 0..<32 { for x in 0..<32 {
            XCTAssertEqual(pixels[(y * 32 + x) * 4 + 3], (4..<21).contains(x) && (4..<25).contains(y) ? 255 : 0)
        }}
    }

    func testRoundedRectangleMaskBlurAndNinePatchSampling() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let blur = try ZTransferShadowBlurRenderer(device: device)
        let renderer = try ZTransferAndroidShadowRenderer(device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        for sigma: Float in [0.04, 1, 8] { for radius: Float in [1, 5.25] {
            let plan = try XCTUnwrap(ZTransferShadowBlur.roundedRectanglePlan(bounds: .init(4.25, 4.25, 68.25, 84.25), radius: radius, sigma: sigma))
            let n = plan.textureSize.x
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            XCTAssertEqual(plan.sigma, sigma)
            XCTAssertThrowsError(try blur.encodeRoundedRectangleMask(plan: plan,
                maximumSurfaceBytes: 2 * n * n - 1, commandBuffer: command))
            let maskTexture = try blur.roundedRectangleMask(plan: plan,
                maximumSurfaceBytes: 2 * n * n, commandBuffer: command)
            XCTAssertEqual(maskTexture.width, n)
            XCTAssertEqual(maskTexture.height, n)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 80, height: 96, mipmapped: false)
            descriptor.storageMode = .shared; descriptor.usage = .renderTarget
            let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            try renderer.encodeRoundedRectangleMasks(layers: [.init(plan: plan, mask: maskTexture, alpha: 255)],
                destination: target, commandBuffer: command)
            let readDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: n, height: n, mipmapped: false)
            readDescriptor.storageMode = .shared
            let readback = try XCTUnwrap(device.makeTexture(descriptor: readDescriptor))
            let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
            blit.copy(from: maskTexture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
                sourceSize: .init(width: n, height: n, depth: 1), to: readback, destinationSlice: 0,
                destinationLevel: 0, destinationOrigin: .init(x: 0, y: 0, z: 0))
            blit.endEncoding(); command.commit(); command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed)
            var mask = [UInt8](repeating: 0, count: n * n), pixels = [UInt8](repeating: 0, count: 80 * 96 * 4)
            mask.withUnsafeMutableBytes { readback.getBytes($0.baseAddress!, bytesPerRow: n, from: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0) }
            pixels.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 320, from: MTLRegionMake2D(0, 0, 80, 96), mipmapLevel: 0) }
            XCTAssertTrue(mask.contains { $0 > 0 })
            let proxy = plan.proxyRectangle
            let edge = Float16(2) * Float16(plan.blurRadius) + Float16(plan.shaderCorner) + Float16(0.5)
            func coordinate(_ pixel: Float, _ low: Float, _ high: Float) -> Int {
                let center = (high - low) * 0.5
                let relative = pixel - low - center
                let sign: Float16 = relative < 0 ? -1 : relative > 0 ? 1 : 0
                let d = max(Float16(0), Float16(abs(relative) - (center - Float(edge))))
                let uv = (d * sign + edge) / (2 * edge)
                return max(0, min(n - 1, Int(floor(Float(uv) * Float(n)))))
            }
            for y in 0..<96 { for x in 0..<80 {
                let px = Float(x) + 0.5, py = Float(y) + 0.5
                let inside = px >= floor(proxy.x) && px < ceil(proxy.z) && py >= floor(proxy.y) && py < ceil(proxy.w)
                let expected = inside ? Int(mask[coordinate(py, proxy.y, proxy.w) * n + coordinate(px, proxy.x, proxy.z)]) : 0
                XCTAssertLessThanOrEqual(abs(Int(pixels[(y * 80 + x) * 4 + 3]) - expected), 2,
                    "sigma=\(sigma), radius=\(radius), pixel=\(x),\(y)")
                XCTAssertEqual(pixels[(y * 80 + x) * 4], 0)
            } }
        } }
    }

    func testCircularRoundedRectangleCoverageAndMaskPadding() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try ZTransferShadowBlurRenderer(device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        for radius: Float in [0.5, 1, 5, 5.25, 7.5] {
            for origin: SIMD2<Int> in [.zero, .init(-17, 31)] {
                let command = try XCTUnwrap(queue.makeCommandBuffer())
                let surface = try renderer.makeMaskSurface(deviceBounds: .init(origin.x, origin.y, origin.x + 24, origin.y + 20),
                    maximumWorkingBytes: 1024, commandBuffer: command)
                let rect = SIMD4<Float>(4.25, 3.25, 24.25, 18.25)
                let shift = SIMD4<Float>(Float(origin.x), Float(origin.y), Float(origin.x), Float(origin.y))
                try renderer.encodeCoverageRoundedRectangle(deviceBounds: rect + shift, radius: radius, surface: surface, commandBuffer: command)
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 32, height: 32, mipmapped: false)
                descriptor.storageMode = .shared
                let readback = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
                let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
                blit.copy(from: surface.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
                    sourceSize: .init(width: 32, height: 32, depth: 1), to: readback, destinationSlice: 0,
                    destinationLevel: 0, destinationOrigin: .init(x: 0, y: 0, z: 0))
                blit.endEncoding(); command.commit(); command.waitUntilCompleted()
                XCTAssertEqual(command.status, .completed)
                var pixels = [UInt8](repeating: 255, count: 1024)
                pixels.withUnsafeMutableBytes { readback.getBytes($0.baseAddress!, bytesPerRow: 32,
                    from: MTLRegionMake2D(0, 0, 32, 32), mipmapLevel: 0) }
                for y in 0..<32 { for x in 0..<32 {
                    // Independent scalar edge distance, not production triangle interpolation.
                    let px = Float(x) + 0.5, py = Float(y) + 0.5
                    let dx = max(0, max(rect.x + radius - px, px - (rect.z - radius)))
                    let dy = max(0, max(rect.y + radius - py, py - (rect.w - radius)))
                    let outer = radius + 0.5
                    let coverage = Float(Float16(max(0, min(1, outer * (1 - sqrtf((dx / outer) * (dx / outer) + (dy / outer) * (dy / outer)))))))
                    let expected = x < 24 && y < 20 ? Int((coverage * 255).rounded()) : 0
                    XCTAssertLessThanOrEqual(abs(Int(pixels[y * 32 + x]) - expected), 1,
                        "radius=\(radius), origin=\(origin), pixel=\(x),\(y)")
                } }
            }
        }
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let surface = try renderer.makeMaskSurface(deviceBounds: .init(0, 0, 24, 20), maximumWorkingBytes: 1024, commandBuffer: command)
        for radius: Float in [0.49, .nan, .infinity, 11] {
            XCTAssertThrowsError(try renderer.encodeCoverageRoundedRectangle(deviceBounds: .init(0, 0, 20, 20), radius: radius,
                surface: surface, commandBuffer: command))
        }
        try renderer.encodeCoverageRoundedRectangle(deviceBounds: .init(1, 1, 19, 19), radius: 5,
            surface: surface, commandBuffer: command)
        command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
    }

    func testRoundedRectanglePlansMatchPinnedSkiaAndStrictInterior() throws {
        struct Case: Decodable {
            let bounds: [Float]; let radius: Float; let sigma: Float; let accepted: Bool
            let size: [Int]?; let mask: [Float]?; let corner: Float?
        }
        struct Fixture: Decodable { let cases: [Case] }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "android15-shadow-rrect-plan", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.cases.count, 99)
        for item in fixture.cases {
            let b = item.bounds, bounds = SIMD4(b[0], b[1], b[2], b[3])
            let plan = ZTransferShadowBlur.roundedRectanglePlan(bounds: bounds, radius: item.radius, sigma: item.sigma)
            XCTAssertEqual(plan != nil, item.accepted, "\(item.bounds), r=\(item.radius), s=\(item.sigma)")
            if let plan {
                XCTAssertEqual(plan.textureSize, SIMD2(item.size![0], item.size![1]))
                XCTAssertEqual(plan.maskRectangle, SIMD4(item.mask![0], item.mask![1], item.mask![2], item.mask![3]))
                XCTAssertEqual(Float(plan.roundedCorner), item.corner)
                XCTAssertEqual(plan.shaderCorner, item.radius)
                XCTAssertEqual(plan.proxyRectangle, bounds + SIMD4(-Float(plan.blurRadius), -Float(plan.blurRadius), Float(plan.blurRadius), Float(plan.blurRadius)))
            }
        }
        XCTAssertNil(ZTransferShadowBlur.roundedRectanglePlan(bounds: .init(0, 0, 16, 20), radius: 5, sigma: 1))
        XCTAssertNotNil(ZTransferShadowBlur.roundedRectanglePlan(bounds: .init(0, 0, Float(16).nextUp, 20), radius: 5, sigma: 1))
        XCTAssertNil(ZTransferShadowBlur.roundedRectanglePlan(bounds: .init(0, 0, 20, 20), radius: 10, sigma: 0.04))
        XCTAssertNil(ZTransferShadowBlur.roundedRectanglePlan(bounds: .init(0, 0, 20, 20), radius: 0, sigma: 1))
        XCTAssertNil(ZTransferShadowBlur.roundedRectanglePlan(bounds: .init(0, 0, 20, 20), radius: .infinity, sigma: 1))
        XCTAssertNil(ZTransferShadowBlur.roundedRectanglePlan(bounds: .init(0, 0, 20, 20), radius: 1, sigma: .nan))
    }

    func testCircleProfileCacheKeepsGeometryIndependentAndEvictsOldTextures() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try ZTransferAndroidShadowRenderer(device: device)
        let (small, first) = try renderer.circleProfileTexture(radius: 10, sigma: 0.5)
        let (large, shared) = try renderer.circleProfileTexture(radius: 20, sigma: 1)
        XCTAssertTrue(first === shared)
        XCTAssertEqual(small.solidRadius, 8.5)
        XCTAssertEqual(large.solidRadius, 17)
        XCTAssertEqual(small.textureRadius, 3)
        XCTAssertEqual(large.textureRadius, 6)
        let (circle, original) = try renderer.circleProfileTexture(radius: 1, sigma: 1)
        let (scaled, same) = try renderer.circleProfileTexture(radius: 2, sigma: 2)
        XCTAssertTrue(original === same)
        XCTAssertEqual(circle.textureRadius, 4)
        XCTAssertEqual(scaled.textureRadius, 8)
        XCTAssertThrowsError(try renderer.circleProfileTexture(radius: 0, sigma: 1))
        for i in 0..<63 { _ = try renderer.circleProfileTexture(radius: 1, sigma: 0.2 + Float(i) * 0.01) }
        // Touching this entry keeps it alive when the next insertion evicts the oldest.
        XCTAssertTrue(try renderer.circleProfileTexture(radius: 1, sigma: 1).1 === original)
        _ = try renderer.circleProfileTexture(radius: 1, sigma: 0.99)
        XCTAssertTrue(try renderer.circleProfileTexture(radius: 1, sigma: 1).1 === original)
        for i in 0..<64 { _ = try renderer.circleProfileTexture(radius: 1, sigma: 2 + Float(i) / 32) }
        let recreated = try renderer.circleProfileTexture(radius: 1, sigma: 1).1
        XCTAssertFalse(recreated === original)
        func bytes(_ texture: MTLTexture) -> [UInt8] {
            var result = [UInt8](repeating: 0, count: 512)
            result.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: 512,
                from: MTLRegionMake2D(0, 0, 512, 1), mipmapLevel: 0) }
            return result
        }
        XCTAssertEqual(bytes(recreated), bytes(original), "eviction does not mutate retained textures")
    }

    func testCircleProfilesMatchPinnedSkiaBytesAndQuantization() throws {
        struct Case: Decodable {
            let radius: Float; let sigma: Float; let key: Int
            let solidRadius: Float; let textureRadius: Float; let pixels: [UInt8]
        }
        struct Fixture: Decodable { let cases: [Case] }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "android15-shadow-circle-profile", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.cases.count, 12)
        for item in fixture.cases {
            let profile = try XCTUnwrap(ZTransferShadowBlur.circleProfile(radius: item.radius, sigma: item.sigma, maximumWorkingBytes: 16384))
            XCTAssertEqual(profile.key, item.key)
            XCTAssertEqual(profile.solidRadius, item.solidRadius)
            XCTAssertEqual(profile.textureRadius, item.textureRadius)
            XCTAssertEqual(profile.pixels, item.pixels, "radius=\(item.radius), sigma=\(item.sigma)")
            XCTAssertNil(ZTransferShadowBlur.circleProfile(radius: item.radius, sigma: item.sigma, maximumWorkingBytes: 511))
        }
        for radius: Float in [.nan, .infinity, 0, -1, (Float(1) / 4096).nextDown] {
            XCTAssertNil(ZTransferShadowBlur.circleProfile(radius: radius, sigma: 1, maximumWorkingBytes: 16384))
        }
        for sigma: Float in [.nan, .infinity, 0, 0.03, Float(128).nextUp] {
            XCTAssertNil(ZTransferShadowBlur.circleProfile(radius: 10, sigma: sigma, maximumWorkingBytes: 16384))
        }
    }

    func testIntegralProfileCacheReusesWidthWithoutMergingSigma() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try ZTransferAndroidShadowRenderer(device: device)
        let first = try renderer.integralProfileTexture(sigma: 1)
        XCTAssertTrue(first === (try renderer.integralProfileTexture(sigma: 2)))
        var widths: Set<Int> = []
        var textures: [MTLTexture] = []
        for sigma: Float in [1, 4, 8, 16, 32, 64, 128] {
            let texture = try renderer.integralProfileTexture(sigma: sigma)
            widths.insert(texture.width); textures.append(texture)
            XCTAssertEqual(texture.width, ZTransferShadowBlur.integralTableWidth(sigma: sigma))
            let expected = try XCTUnwrap(ZTransferShadowBlur.integralTable(sigma: sigma, maximumWorkingBytes: 2048))
            var bytes = [UInt8](repeating: 0, count: texture.width)
            bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: texture.width,
                from: MTLRegionMake2D(0, 0, texture.width, 1), mipmapLevel: 0) }
            XCTAssertEqual(bytes, expected)
        }
        XCTAssertEqual(widths, [32, 64, 128, 256, 512, 1024, 2048])
        XCTAssertEqual(widths.reduce(0, +), 4064)
        for sigma: Float in [.nan, .infinity, 0.03, Float(128).nextUp] {
            XCTAssertThrowsError(try renderer.integralProfileTexture(sigma: sigma))
        }
        XCTAssertTrue(first === (try renderer.integralProfileTexture(sigma: 1)))
        XCTAssertEqual(Set(textures.map { ObjectIdentifier($0) }).count, 7)
    }

    func testIntegralTablesMatchPinnedSkiaBytes() throws {
        struct Case: Decodable { let sigma: Float; let pixels: [UInt8] }
        struct Fixture: Decodable { let cases: [Case] }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "android15-shadow-integral", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.cases.count, 12)
        for item in fixture.cases {
            let table = try XCTUnwrap(ZTransferShadowBlur.integralTable(sigma: item.sigma, maximumWorkingBytes: item.pixels.count))
            XCTAssertEqual(table, item.pixels, "sigma=\(item.sigma)")
            XCTAssertNil(ZTransferShadowBlur.integralTable(sigma: item.sigma, maximumWorkingBytes: item.pixels.count - 1))
        }
        for sigma: Float in [.nan, .infinity, -.infinity, -1, 0, 0.03, Float(128).nextUp] {
            XCTAssertNil(ZTransferShadowBlur.integralTable(sigma: sigma, maximumWorkingBytes: 2048))
        }
        XCTAssertNil(ZTransferShadowBlur.integralTable(sigma: 1, maximumWorkingBytes: -1))
    }

    func testCoverageRectangleRasterizationAndClippedBacking() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try ZTransferShadowBlurRenderer(device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        // Explicit outer edge planes and peak coverage derived from Skia's
        // picture-frame geometry. Pixel-area intersection gives different corners.
        let cases: [(SIMD4<Float>, SIMD4<Float>, SIMD2<Float>, Float)] = [
            (.init(2, 2, 6, 6), .init(1.5, 1.5, 6.5, 6.5), .init(1, 1), 1),
            (.init(2.25, 2.25, 6.25, 6.25), .init(1.75, 1.75, 6.75, 6.75), .init(1, 1), 1),
            (.init(3.25, 2, 3.75, 6), .init(2.5, 1.5, 4.5, 6.5), .init(1, 1), 0.5),
            (.init(2, 3.25, 6, 3.75), .init(1.5, 2.5, 6.5, 4.5), .init(1, 1), 0.5),
            (.init(3.25, 3.375, 3.75, 3.625), .init(2.5, 2.5, 4.5, 4.5), .init(1, 1), 0.125),
            (.init(-1, -1, 9, 9), .init(-1.5, -1.5, 9.5, 9.5), .init(1, 1), 1)
        ]
        for origin: SIMD2<Int> in [.zero, .init(-17, 31)] {
            for (rect, edges, ramp, peak) in cases {
                let command = try XCTUnwrap(queue.makeCommandBuffer())
                let surface = try renderer.makeMaskSurface(deviceBounds: .init(origin.x, origin.y, origin.x + 8, origin.y + 8),
                    maximumWorkingBytes: 256, commandBuffer: command)
                let translation = SIMD4<Float>(Float(origin.x), Float(origin.y), Float(origin.x), Float(origin.y))
                try renderer.encodeCoverageRectangle(deviceBounds: rect + translation, surface: surface, commandBuffer: command)
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 16, height: 16, mipmapped: false)
                descriptor.storageMode = .shared
                let readback = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
                let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
                blit.copy(from: surface.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
                    sourceSize: .init(width: 16, height: 16, depth: 1), to: readback, destinationSlice: 0,
                    destinationLevel: 0, destinationOrigin: .init(x: 0, y: 0, z: 0))
                blit.endEncoding(); command.commit(); command.waitUntilCompleted()
                XCTAssertEqual(command.status, .completed)
                var bytes = [UInt8](repeating: 255, count: 256)
                bytes.withUnsafeMutableBytes { readback.getBytes($0.baseAddress!, bytesPerRow: 16,
                    from: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0) }
                for y in 0..<16 { for x in 0..<16 {
                    let px = Float(x) + 0.5, py = Float(y) + 0.5
                    let plane = max(0, min(1, min(min((px - edges.x) / ramp.x, (edges.z - px) / ramp.x),
                                                   min((py - edges.y) / ramp.y, (edges.w - py) / ramp.y))))
                    let expected = x < 8 && y < 8 ? Int((plane * peak * 255).rounded()) : 0
                    XCTAssertLessThanOrEqual(abs(Int(bytes[y * 16 + x]) - expected), 1,
                        "rect=\(rect) origin=\(origin) pixel=\(x),\(y)")
                } }
            }
        }
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let surface = try renderer.makeMaskSurface(deviceBounds: .init(0, 0, 8, 8), maximumWorkingBytes: 256, commandBuffer: command)
        for rect: SIMD4<Float> in [.zero, .init(1, 0, 0, 2), .init(.nan, 0, 1, 2)] {
            XCTAssertThrowsError(try renderer.encodeCoverageRectangle(deviceBounds: rect, surface: surface, commandBuffer: command))
        }
        // A rejected draw leaves the command usable.
        try renderer.encodeCoverageRectangle(deviceBounds: .init(1, 1, 4, 4), surface: surface, commandBuffer: command)
        command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
    }

    func testMaskBackingSizeAndTransparentGPUSurface() throws {
        let cases = [(1, 16), (16, 16), (17, 32), (31, 32), (32, 32), (33, 64),
                     (1023, 1024), (1024, 1024), (1025, 1536), (1536, 1536),
                     (1537, 2048), (2048, 2048), (2049, 3072), (3072, 3072), (3073, 4096)]
        for (input, expected) in cases {
            XCTAssertEqual(ZTransferShadowBlur.maskBackingSize(.init(input, 17)), .init(expected, 32))
            XCTAssertEqual(ZTransferShadowBlur.maskBackingSize(.init(17, input)), .init(32, expected))
        }
        XCTAssertNil(ZTransferShadowBlur.maskBackingSize(.init(0, 1)))
        XCTAssertNil(ZTransferShadowBlur.maskBackingSize(.init(Int.max, 1)))
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try ZTransferShadowBlurRenderer(device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        for bounds: SIMD4<Int> in [.init(-7, 11, 12, 24), .init(5, -8, 70, -7), .init(0, 0, 1025, 3)] {
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let surface = try renderer.makeMaskSurface(deviceBounds: bounds, maximumWorkingBytes: 1024 * 1024,
                commandBuffer: command)
            XCTAssertEqual(surface.contentBounds, .init(0, 0, bounds.z - bounds.x, bounds.w - bounds.y))
            XCTAssertEqual(surface.deviceOrigin, .init(bounds.x, bounds.y))
            XCTAssertEqual(surface.texture.storageMode, .private)
            XCTAssertTrue(surface.texture.usage.contains(.renderTarget))
            let width = surface.texture.width, height = surface.texture.height
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .shared
            let readback = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
            blit.copy(from: surface.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
                sourceSize: .init(width: width, height: height, depth: 1), to: readback, destinationSlice: 0,
                destinationLevel: 0, destinationOrigin: .init(x: 0, y: 0, z: 0))
            blit.endEncoding(); command.commit(); command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed)
            var bytes = [UInt8](repeating: 255, count: width * height)
            bytes.withUnsafeMutableBytes { readback.getBytes($0.baseAddress!, bytesPerRow: width,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
            XCTAssertTrue(bytes.allSatisfy { $0 == 0 }, "entire backing, including padding, must be transparent")
        }
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertThrowsError(try renderer.makeMaskSurface(deviceBounds: .init(0, 0, 1025, 3), maximumWorkingBytes: 1025 * 3, commandBuffer: command))
        XCTAssertThrowsError(try renderer.makeMaskSurface(deviceBounds: .init(Int.min, 0, Int.max, 1), maximumWorkingBytes: Int.max, commandBuffer: command))
    }

    func testGeneralMaskRouteAndTruncatedOutset() throws {
        let clip = SIMD4<Int>(-1000, -1000, 1000, 1000)
        XCTAssertEqual(ZTransferShadowBlur.maskPlan(shapeBounds: .init(0, 0, 64, 64), clipBounds: clip, sigma: 32),
                       .software(bounds: .init(-96, -96, 160, 160)))
        XCTAssertEqual(ZTransferShadowBlur.maskPlan(shapeBounds: .init(0, 0, 65, 64), clipBounds: clip, sigma: 32),
                       .gpu(bounds: .init(-96, -96, 161, 160)))
        XCTAssertEqual(ZTransferShadowBlur.maskPlan(shapeBounds: .init(0, 0, 64, 65), clipBounds: clip, sigma: 32),
                       .gpu(bounds: .init(-96, -96, 160, 161)))
        XCTAssertEqual(ZTransferShadowBlur.maskPlan(shapeBounds: .init(0, 0, 64, 64), clipBounds: clip, sigma: Float(32).nextUp),
                       .gpu(bounds: .init(-96, -96, 160, 160)))
        for sigma: Float in [0, 0.03] {
            XCTAssertEqual(ZTransferShadowBlur.maskPlan(shapeBounds: .init(-5, -3, 12, 20), clipBounds: .init(0, 0, 10, 10), sigma: sigma),
                           .identity(bounds: .init(0, 0, 10, 10)))
        }
        // Nonidentity blur may still have an integer mask outset of zero.
        for sigma: Float in [Float(0.03).nextUp, 0.125] {
            XCTAssertEqual(ZTransferShadowBlur.maskPlan(shapeBounds: .init(3, 4, 20, 25), clipBounds: clip, sigma: sigma),
                           .software(bounds: .init(3, 4, 20, 25)))
        }
        XCTAssertEqual(ZTransferShadowBlur.maskPlan(shapeBounds: .init(3, 4, 20, 25), clipBounds: .init(8, 9, 18, 22), sigma: 0.5),
                       .software(bounds: .init(7, 8, 19, 23)))
        XCTAssertEqual(ZTransferShadowBlur.maskPlan(shapeBounds: .init(0, 0, 64, 64), clipBounds: .init(100, 0, 110, 10), sigma: 0), .empty)
        XCTAssertEqual(ZTransferShadowBlur.maskPlan(shapeBounds: .init(0, 0, 64, 64), clipBounds: .init(100, 0, 110, 10), sigma: 1), .empty)
        XCTAssertEqual(ZTransferShadowBlur.maskPlan(shapeBounds: .init(0, 0, 64, 64), clipBounds: .init(70, 0, 80, 10), sigma: 2),
                       .software(bounds: .init(64, -6, 70, 16)))
        for sigma: Float in [-1, .nan, .infinity, .greatestFiniteMagnitude] {
            XCTAssertNil(ZTransferShadowBlur.maskPlan(shapeBounds: .init(0, 0, 64, 64), clipBounds: clip, sigma: sigma))
        }
        XCTAssertNil(ZTransferShadowBlur.maskPlan(shapeBounds: .init(Int.min, 0, Int.max, 1), clipBounds: clip, sigma: 1))
    }

    func testReexpandFractionalSubsetAndPaddedBoundaries() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try ZTransferShadowBlurRenderer(device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        func texture(_ w: Int, _ h: Int) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
            d.storageMode = .shared; d.usage = [.shaderRead, .shaderWrite]
            return try XCTUnwrap(device.makeTexture(descriptor: d))
        }
        let source = try texture(7, 5), output = try texture(23, 17)
        let input: [UInt8] = (0..<35).map { (i: Int) in UInt8((i * 71 + 43) % 256) }
        input.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, 7, 5), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: 7) }
        let rectangles: [SIMD4<Float>] = [.init(0, 0, 7, 5), .init(0.2, 0.7, 6.8, 4.2),
            .init(1.3, 1.1, 1.6, 1.8), .init(2, 1, 3, 4), .init(0, 0, 0.1, 0.2)]
        var foundPolicyDifference = false
        for bounds in rectangles {
            var previous: [UInt8]?
            for padded in [false, true] {
                func coordinate(_ fraction: Float, _ low: Float, _ high: Float, _ size: Float) -> Float {
                    let position = low + fraction * (high - low)
                    if padded { return min(max(position, 0.5), size - 0.5) }
                    if high - low < 1 { return (low + high) / 2 }
                    return min(max(position, low + 0.5), high - 0.5)
                }
                func value(_ x: Int, _ y: Int) -> Float { Float(input[min(max(y, 0), 4) * 7 + min(max(x, 0), 6)]) / 255 }
                var expected: [UInt8] = []
                for y in 0..<17 { for x in 0..<23 {
                    let sx = coordinate((Float(x) + 0.5) / 23, bounds.x, bounds.z, 7) - 0.5
                    let sy = coordinate((Float(y) + 0.5) / 17, bounds.y, bounds.w, 5) - 0.5
                    let l = Int(floor(sx)), t = Int(floor(sy)), fx = sx - floor(sx), fy = sy - floor(sy)
                    let top = value(l, t) * (1 - fx) + value(l + 1, t) * fx
                    let bottom = value(l, t + 1) * (1 - fx) + value(l + 1, t + 1) * fx
                    expected.append(UInt8(min(max((Float(Float16(top * (1 - fy) + bottom * fy)) * 255).rounded(), 0), 255)))
                } }
                let command = try XCTUnwrap(queue.makeCommandBuffer())
                try renderer.encodeReexpand(source: source, destination: output, sourceBounds: bounds,
                    paddedUpscale: padded, commandBuffer: command)
                command.commit(); command.waitUntilCompleted()
                XCTAssertEqual(command.status, .completed)
                var actual = [UInt8](repeating: 0, count: 391)
                actual.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: 23,
                    from: MTLRegionMake2D(0, 0, 23, 17), mipmapLevel: 0) }
                XCTAssertLessThanOrEqual(zip(actual, expected).map { abs(Int($0) - Int($1)) }.max() ?? 0, 2,
                    "bounds \(bounds), padded \(padded)")
                if let previous, previous != actual { foundPolicyDifference = true }
                previous = actual
            }
        }
        XCTAssertTrue(foundPolicyDifference, "fixture must distinguish fractional subset from full-content clamp")
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        for bounds: SIMD4<Float> in [.zero, .init(-1, 0, 2, 2), .init(0, 0, 8, 5), .init(.nan, 0, 1, 1)] {
            XCTAssertThrowsError(try renderer.encodeReexpand(source: source, destination: output, sourceBounds: bounds,
                paddedUpscale: false, commandBuffer: command))
        }
        XCTAssertThrowsError(try renderer.encodeReexpand(source: source, destination: source,
            sourceBounds: .init(0, 0, 7, 5), paddedUpscale: true, commandBuffer: command))
    }

    func testOffsetClampBlurMatchesIndependentFullRowReference() throws {
        struct Linear: Decodable { let sigma: Float; let radius: Int; let samples: [[Float]] }
        struct Full: Decodable { let sigma, weights: [Float] }
        struct Reference: Decodable { let linear: [Linear]; let full: [Full] }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "android15-shadow-blur-kernel", withExtension: "json"))
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try ZTransferShadowBlurRenderer(device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        func texture(_ w: Int, _ h: Int) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
            d.storageMode = .shared; d.usage = [.shaderRead, .shaderWrite]
            return try XCTUnwrap(device.makeTexture(descriptor: d))
        }
        func quantize(_ value: Float16) -> UInt8 { UInt8(min(max((Float(value) * 255).rounded(), 0), 255)) }
        let source = try texture(23, 17), output = try texture(6, 5)
        let input: [UInt8] = (0..<391).map { (index: Int) -> UInt8 in
            let row = index / 23
            return UInt8((index * 71 + row * 37) % 256)
        }
        input.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, 23, 17), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: 23) }
        let subsets: [SIMD4<Int>] = [.init(0, 0, 23, 17), .init(3, 4, 19, 14), .init(8, 3, 9, 13), .init(2, 7, 17, 8)]
        let origins: [SIMD2<Int>] = [.init(5, 5), .init(-3, -2), .init(17, 13), .init(-40, 6), .init(50, -50), .init(6, 50)]
        for bounds in subsets {
            func original(_ x: Int, _ y: Int) -> Float {
                Float(input[min(max(y, bounds.y), bounds.w - 1) * 23 + min(max(x, bounds.x), bounds.z - 1)]) / 255
            }
            for origin in origins {
                for requested: SIMD2<Float> in [.zero, .init(0.5, 0.5), .init(1, 1), .init(4, 0), .init(4, 4)] {
                    let sigma = SIMD2<Float>(bounds.z - bounds.x == 1 ? 0 : requested.x,
                                             bounds.w - bounds.y == 1 ? 0 : requested.y)
                    let kx = try XCTUnwrap(reference.linear.first { $0.sigma == sigma.x })
                    let ky = try XCTUnwrap(reference.linear.first { $0.sigma == sigma.y })
                    let is2D = kx.radius > 0 && ky.radius > 0 && (2 * kx.radius + 1) * (2 * ky.radius + 1) <= 28
                    let full = reference.full.first { $0.sigma == [sigma.x, sigma.y] }
                    // Intentionally keep every original source row: no production reach
                    // intersection or intermediate clipping calculation is reused here.
                    func xFiltered(_ x: Int, _ y: Int) -> Float {
                        if kx.radius == 0 { return original(x, y) }
                        var total: Float16 = 0
                        for tap in kx.samples.prefix(kx.radius + 1) {
                            let sx = Float(x) + Float(Float16(tap[0])), left = Int(floor(sx)), f = sx - floor(sx)
                            let value = original(left, y) * (1 - f) + original(left + 1, y) * f
                            total += Float16(tap[1]) * Float16(value)
                        }
                        return Float(quantize(total)) / 255
                    }
                    var expected: [UInt8] = []
                    for y in origin.y..<(origin.y + 5) { for x in origin.x..<(origin.x + 6) {
                        var total: Float16 = 0
                        if is2D {
                            let weights = try XCTUnwrap(full).weights
                            for dy in -ky.radius...ky.radius { for dx in -kx.radius...kx.radius {
                                let weight = weights[(dy + ky.radius) * (2 * kx.radius + 1) + dx + kx.radius]
                                total += Float16(weight) * Float16(original(x + dx, y + dy))
                            } }
                        } else if ky.radius > 0 {
                            for tap in ky.samples.prefix(ky.radius + 1) {
                                let sy = Float(y) + Float(Float16(tap[0])), top = Int(floor(sy)), f = sy - floor(sy)
                                total += Float16(tap[1]) * Float16(xFiltered(x, top) * (1 - f) + xFiltered(x, top + 1) * f)
                            }
                        } else { total = Float16(xFiltered(x, y)) }
                        expected.append(quantize(total))
                    } }
                    let command = try XCTUnwrap(queue.makeCommandBuffer())
                    try renderer.encode(source: source, sourceBounds: bounds, destination: output,
                        destinationBounds: .init(origin.x, origin.y, origin.x + 6, origin.y + 5),
                        sigma: requested, commandBuffer: command)
                    command.commit(); command.waitUntilCompleted()
                    XCTAssertEqual(command.status, .completed)
                    var actual = [UInt8](repeating: 0, count: 30)
                    actual.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: 6,
                        from: MTLRegionMake2D(0, 0, 6, 5), mipmapLevel: 0) }
                    XCTAssertLessThanOrEqual(zip(actual, expected).map { abs(Int($0) - Int($1)) }.max() ?? 0, 2,
                        "subset \(bounds), origin \(origin), sigma \(requested)")
                }
            }
        }
        XCTAssertNil(ZTransferShadowBlur.clampPlan(sourceBounds: .init(0, 0, 2, 2),
            destinationBounds: .init(Int.min, 0, Int.max, 1), sigma: .zero))
    }

    func testOnePixelClampAxesSkipConvolutionExactly() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try ZTransferShadowBlurRenderer(device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        for (width, height) in [(1, 1), (1, 256), (256, 1)] {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,
                width: width, height: height, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead, .shaderWrite]
            let source = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            let destination = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            for sigma: Float in [0.125, 0.5, 1, 4] {
                // Cover all A8 values, including a nonzero 1x1 texel.
                let input = (0..<(width * height)).map { UInt8(($0 + 97) % 256) }
                input.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                    withBytes: $0.baseAddress!, bytesPerRow: width) }
                let command = try XCTUnwrap(queue.makeCommandBuffer())
                try renderer.encode(source: source, destination: destination,
                    sigma: .init(width == 1 ? sigma : 0, height == 1 ? sigma : 0), commandBuffer: command)
                command.commit(); command.waitUntilCompleted()
                XCTAssertEqual(command.status, .completed)
                var output = [UInt8](repeating: 0, count: input.count)
                output.withUnsafeMutableBytes { destination.getBytes($0.baseAddress!, bytesPerRow: width,
                    from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
                XCTAssertEqual(output, input, "\(width)x\(height), sigma \(sigma)")
            }
        }
    }

    func testMetalDownsamplePreservesOriginalBordersAndQuantizedSteps() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try ZTransferShadowBlurRenderer(device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        func texture(_ width: Int, _ height: Int) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,
                width: width, height: height, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead, .shaderWrite]
            return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        }
        func sample(_ pixels: [UInt8], _ w: Int, _ h: Int, _ x: Float, _ y: Float) -> UInt8 {
            let l = Int(floor(x)), t = Int(floor(y)), fx = x - floor(x), fy = y - floor(y)
            func at(_ x: Int, _ y: Int) -> Float { Float(pixels[min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)]) / 255 }
            let top = at(l, t) * (1 - fx) + at(l + 1, t) * fx
            let bottom = at(l, t + 1) * (1 - fx) + at(l + 1, t + 1) * fx
            return UInt8(min(max((Float(Float16(top * (1 - fy) + bottom * fy)) * 255).rounded(), 0), 255))
        }
        // Non-square odd sizes, unchanged axes, repeated reductions and one-pixel images.
        for (w, h, dw, dh) in [(19, 13, 2, 1), (19, 13, 9, 6), (19, 13, 19, 3),
                               (19, 13, 4, 13), (19, 13, 19, 13), (1, 7, 1, 1), (1, 1, 1, 1)] {
            for transparentBorder in [false, true] {
                let input: [UInt8] = (0..<(w * h)).map { i in
                    let x = i % w, y = i / w
                    if transparentBorder && (x == 0 || y == 0 || x == w - 1 || y == h - 1) { return 0 }
                    return UInt8((x * 71 + y * 37 + 83) % 256)
                }
                let source = try texture(w, h), output = try texture(dw + 2, dh + 2)
                input.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                    withBytes: $0.baseAddress!, bytesPerRow: w) }
                var interior = input, iw = w, ih = h
                while iw != dw || ih != dh {
                    let nw = max((iw + 1) / 2, dw), nh = max((ih + 1) / 2, dh)
                    interior = (0..<(nw * nh)).map { i in
                        sample(interior, iw, ih, (Float(i % nw) + 0.5) * Float(iw) / Float(nw) - 0.5,
                               (Float(i / nw) + 0.5) * Float(ih) / Float(nh) - 0.5)
                    }
                    iw = nw; ih = nh
                }
                let expected: [UInt8] = (0..<((dw + 2) * (dh + 2))).map { i in
                    let x = i % (dw + 2), y = i / (dw + 2)
                    if x > 0 && x <= dw && y > 0 && y <= dh { return interior[(y - 1) * dw + x - 1] }
                    let sx: Float = x == 0 ? 0 : (x == dw + 1 ? Float(w - 1) : (Float(x) - 0.5) * Float(w) / Float(dw) - 0.5)
                    let sy: Float = y == 0 ? 0 : (y == dh + 1 ? Float(h - 1) : (Float(y) - 0.5) * Float(h) / Float(dh) - 0.5)
                    return sample(input, w, h, sx, sy)
                }
                let command = try XCTUnwrap(queue.makeCommandBuffer())
                try renderer.encodeDownsample(source: source, destination: output, commandBuffer: command)
                command.commit(); command.waitUntilCompleted()
                XCTAssertEqual(command.status, .completed)
                var actual = [UInt8](repeating: 0, count: expected.count)
                actual.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: dw + 2,
                    from: MTLRegionMake2D(0, 0, dw + 2, dh + 2), mipmapLevel: 0) }
                XCTAssertLessThanOrEqual(zip(actual, expected).map { abs(Int($0) - Int($1)) }.max() ?? 0, 2,
                    "\(w)x\(h) → \(dw)x\(dh), transparent \(transparentBorder)")
                for y in 0..<(dh + 2) { for x in 0..<(dw + 2) {
                    if transparentBorder && (x == 0 || y == 0 || x == dw + 1 || y == dh + 1) {
                        XCTAssertEqual(actual[y * (dw + 2) + x], 0, "original transparent border must not pull interior pixels")
                    }
                } }
                let invalid = try XCTUnwrap(queue.makeCommandBuffer())
                XCTAssertThrowsError(try renderer.encodeDownsample(source: source, destination: source, commandBuffer: invalid))
            }
        }
    }

    func testMetalBlurMatchesNativeKernelReferencePixels() throws {
        struct Linear: Decodable { let sigma: Float; let radius: Int; let samples: [[Float]] }
        struct Full: Decodable { let sigma, weights: [Float] }
        struct Reference: Decodable { let linear: [Linear]; let full: [Full] }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "android15-shadow-blur-kernel", withExtension: "json"))
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try ZTransferShadowBlurRenderer(device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let width = 19, height = 13
        let input: [UInt8] = (0..<(width * height)).map { index in
            let x = index % width, y = index / width
            return x < 3 ? 255 : ((x + y) % 5 == 0 ? 0 : UInt8((x * 11 + y * 17) % 256))
        }
        func texture(_ usage: MTLTextureUsage) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = usage
            return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        }
        let source = try texture(.shaderRead), destination = try texture([.shaderRead, .shaderWrite])
        input.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                               withBytes: $0.baseAddress!, bytesPerRow: width) }
        func pass(_ pixels: [UInt8], samples: [SIMD3<Float>]) -> [UInt8] {
            func at(_ x: Int, _ y: Int) -> Float {
                Float(pixels[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]) / 255
            }
            return (0..<(width * height)).map { index in
                var total: Float16 = 0
                for sample in samples {
                    let x = Float(index % width) + Float(Float16(sample.x))
                    let y = Float(index / width) + Float(Float16(sample.y))
                    let left = Int(floor(x)), top = Int(floor(y)), fx = x - floor(x), fy = y - floor(y)
                    let upper = at(left, top) * (1 - fx) + at(left + 1, top) * fx
                    let lower = at(left, top + 1) * (1 - fx) + at(left + 1, top + 1) * fx
                    let value = Float16(upper * (1 - fy) + lower * fy)
                    total += Float16(sample.z) * value
                }
                return UInt8(min(max((Float(total) * 255).rounded(), 0), 255))
            }
        }
        for sigma: SIMD2<Float> in [.zero, .init(0.03, 0.03), .init(0.125, 0.5), .init(0.5, 0.5),
                                   .init(1, 1), .init(4, 4), .init(4, 0), .init(0, 4)] {
            let x = try XCTUnwrap(reference.linear.first { $0.sigma == sigma.x })
            let y = try XCTUnwrap(reference.linear.first { $0.sigma == sigma.y })
            let expected: [UInt8]
            if x.radius > 0 && y.radius > 0 && (2 * x.radius + 1) * (2 * y.radius + 1) <= 28 {
                let full = try XCTUnwrap(reference.full.first { $0.sigma == [sigma.x, sigma.y] })
                let samples = full.weights.enumerated().map { index, weight in
                    SIMD3<Float>(Float(index % (2 * x.radius + 1) - x.radius), Float(index / (2 * x.radius + 1) - y.radius), weight)
                }
                expected = pass(input, samples: samples)
            } else {
                var pixels = input
                if x.radius > 0 { pixels = pass(pixels, samples: x.samples.prefix(x.radius + 1).map { .init($0[0], 0, $0[1]) }) }
                if y.radius > 0 { pixels = pass(pixels, samples: y.samples.prefix(y.radius + 1).map { .init(0, $0[0], $0[1]) }) }
                expected = pixels
            }
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            try renderer.encode(source: source, destination: destination, sigma: sigma, commandBuffer: command)
            command.commit()
            command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed)
            var pixels = [UInt8](repeating: 0, count: input.count)
            pixels.withUnsafeMutableBytes { destination.getBytes($0.baseAddress!, bytesPerRow: width,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
            let error = zip(pixels, expected).map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertLessThanOrEqual(error, 2, "sigma \(sigma)")
            if sigma == .zero { XCTAssertEqual(pixels, input) }
        }
        let invalid = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertThrowsError(try renderer.encode(source: source, destination: destination, sigma: .init(4.1, 0), commandBuffer: invalid))
        XCTAssertThrowsError(try renderer.encode(source: destination, destination: destination, sigma: .zero, commandBuffer: invalid))
        let alias = try XCTUnwrap(destination.makeTextureView(pixelFormat: .r8Unorm))
        XCTAssertThrowsError(try renderer.encode(source: alias, destination: destination, sigma: .zero, commandBuffer: invalid))
    }

    func testBlurKernelsMatchPinnedSkia() throws {
        struct Linear: Decodable { let sigma: Float; let radius: Int; let samples: [[Float]] }
        struct Full: Decodable { let sigma, weights: [Float] }
        struct Reference: Decodable { let linear: [Linear]; let full: [Full] }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "android15-shadow-blur-kernel", withExtension: "json"))
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        XCTAssertEqual(reference.linear.count, 12)
        XCTAssertEqual(reference.full.count, 77)
        for test in reference.linear {
            XCTAssertEqual(ZTransferShadowBlur.radius(sigma: test.sigma), test.radius)
            let actual = try XCTUnwrap(ZTransferShadowBlur.linearKernel(sigma: test.sigma))
            XCTAssertEqual(actual, test.samples.map { SIMD2<Float>($0[0], $0[1]) }, "sigma \(test.sigma)")
            XCTAssertEqual(actual.count, 28)
            XCTAssertEqual(actual.reduce(Float(0)) { $0 + $1.y }, 1, accuracy: 0.000001)
        }
        for test in reference.full {
            let actual = try XCTUnwrap(ZTransferShadowBlur.kernel(sigma: .init(test.sigma[0], test.sigma[1])))
            XCTAssertEqual(actual, test.weights, "sigma \(test.sigma)")
        }
        for sigma: Float in [-1, .nan, .infinity, Float(4).nextUp] {
            XCTAssertNil(ZTransferShadowBlur.linearKernel(sigma: sigma))
        }
        XCTAssertNil(ZTransferShadowBlur.kernel(sigma: .init(4, 4)))
    }

    func testFallbackRectSimplificationUsesDeviceSpaceStroke() throws {
        let caster = ZTransferAndroidShadowMetrics.Caster(minimum: .init(1, 2), maximum: .init(11, 22), radius: 0)
        let transforms: [(ZTransferShadowTransform, SIMD4<Float>)] = [
            (.init(x: .init(2, 0, 17), y: .init(0, 3, -9), perspective: .init(0, 0, 1)), .init(19, -3, 39, 57)),
            (.init(x: .init(-2, 0, 17), y: .init(0, 3, -9), perspective: .init(0, 0, 1)), .init(-5, -3, 15, 57)),
            (.init(x: .init(0, -3, 17), y: .init(2, 0, -9), perspective: .init(0, 0, 1)), .init(-49, -7, 11, 13))
        ]
        for (transform, fillBounds) in transforms {
            let ambient = ZTransferShadowGeometry.BlurFallback(transform: transform, transformApplication: .pathBeforeStyle,
                sigma: 200, style: .strokeAndFill(width: 4))
            let result = try XCTUnwrap(ambient.axisAlignedRectangle(caster: caster))
            XCTAssertEqual(result.bounds, fillBounds + SIMD4(-2, -2, 2, 2))
            XCTAssertEqual(result.sigma, 128)
            let spot = ZTransferShadowGeometry.BlurFallback(transform: transform, transformApplication: .drawingMatrix, sigma: 0, style: .fill)
            XCTAssertEqual(spot.axisAlignedRectangle(caster: caster)?.bounds, fillBounds)
            XCTAssertEqual(spot.axisAlignedRectangle(caster: caster)?.sigma, 0)
            XCTAssertNil(ambient.axisAlignedRectangle(caster: .init(minimum: caster.minimum, maximum: caster.maximum, radius: 1)))
        }
        for transform in [
            ZTransferShadowTransform(x: .init(1, 0.25, 0), y: .init(0, 1, 0), perspective: .init(0, 0, 1)),
            .init(x: .init(0, 0, 0), y: .init(0, 1, 0), perspective: .init(0, 0, 1)),
            .init(x: .init(1, 0, 0), y: .init(0, 1, 0), perspective: .init(0.001, 0, 1))
        ] {
            let recipe = ZTransferShadowGeometry.BlurFallback(transform: transform, transformApplication: .pathBeforeStyle, sigma: 1, style: .strokeAndFill(width: 4))
            XCTAssertNil(recipe.axisAlignedRectangle(caster: caster))
        }
        let wrongStage = ZTransferShadowGeometry.BlurFallback(transform: .identity, transformApplication: .drawingMatrix,
            sigma: 1, style: .strokeAndFill(width: 4))
        XCTAssertNil(wrongStage.axisAlignedRectangle(caster: caster))
    }

    func testFallbackTransformAppliedAtOriginalDrawingStage() throws {
        let transform = ZTransferShadowTransform(x: .init(2, 0.25, 17), y: .init(0, 3, -9), perspective: .init(0, 0, 1))
        let ambient = try XCTUnwrap(ZTransferShadowGeometry.ambientFallback(transform: transform, height: 6))
        XCTAssertEqual(ambient.transformApplication, .pathBeforeStyle)
        XCTAssertEqual(ambient.pathTransform.x, transform.x)
        XCTAssertEqual(ambient.pathTransform.y, transform.y)
        XCTAssertEqual(ambient.drawingTransform.x, ZTransferShadowTransform.identity.x)
        XCTAssertEqual(ambient.drawingTransform.y, ZTransferShadowTransform.identity.y)
        // The nonuniform path transform must not scale the subsequent stroke.
        let identity = try XCTUnwrap(ZTransferShadowGeometry.ambientFallback(transform: .identity, height: 6))
        XCTAssertEqual(ambient.style, identity.style)
        XCTAssertEqual(ambient.filterSigma, identity.filterSigma)
        let spot = try XCTUnwrap(ZTransferShadowGeometry.spotFallback(minimum: .zero, maximum: .init(80, 40),
            transform: transform, heightPlane: .init(0, 0, 6), light: .init(200, -50, 500), lightRadius: 800))
        XCTAssertEqual(spot.transformApplication, .drawingMatrix)
        XCTAssertEqual(spot.pathTransform.x, ZTransferShadowTransform.identity.x)
        XCTAssertEqual(spot.pathTransform.y, ZTransferShadowTransform.identity.y)
        XCTAssertEqual(spot.drawingTransform.x, spot.transform.x)
        XCTAssertEqual(spot.drawingTransform.y, spot.transform.y)
        XCTAssertEqual(spot.drawingTransform.perspective, spot.transform.perspective)
        XCTAssertEqual(spot.style, .fill)
        XCTAssertNotEqual(spot.drawingTransform.x, ZTransferShadowTransform.identity.x)
    }

    func testBlurFallbackRecipesMatchPinnedSkia() throws {
        struct Case: Decodable {
            let height, spotRadius, stroke, ambientSigma, spotSigma: Float
        }
        struct Reference: Decodable { let cases: [Case] }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "android15-shadow-fallback", withExtension: "json"))
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        XCTAssertEqual(reference.cases.count, 55)
        for test in reference.cases {
            let ambient = try XCTUnwrap(ZTransferShadowGeometry.ambientFallback(transform: .identity, height: test.height))
            XCTAssertEqual(ambient.style, .strokeAndFill(width: test.stroke))
            XCTAssertEqual(ambient.sigma, test.ambientSigma)
            XCTAssertEqual(ambient.filterSigma, min(test.ambientSigma, 128))
            let spot = try XCTUnwrap(ZTransferShadowGeometry.spotFallback(minimum: .zero, maximum: .init(80, 40),
                transform: .identity, heightPlane: .init(0, 0, 1), light: .init(20, 30, 500),
                lightRadius: test.spotRadius, directional: true))
            XCTAssertEqual(spot.style, .fill)
            XCTAssertEqual(spot.sigma, test.spotSigma)
            XCTAssertEqual(spot.filterSigma, min(test.spotSigma, 128))
        }
        XCTAssertNil(ZTransferShadowGeometry.ambientFallback(transform: .identity, height: .infinity))
        let perspective = ZTransferShadowTransform(x: .init(1, 0, 0), y: .init(0, 1, 0), perspective: .init(0.001, 0, 1))
        XCTAssertNil(ZTransferShadowGeometry.spotFallback(minimum: .zero, maximum: .init(80, 40),
            transform: perspective, heightPlane: .init(0, 0, 500), light: .init(20, 30, 500), lightRadius: 800))
    }

    func testOpaqueAboveLightSkipsZeroInsetSpotAndKeepsAmbient() throws {
        let light = ZTransferAndroidShadowMetrics.Lighting(center: .init(20, -30, 500),
            radius: 10, ambientAlpha: 9, spotAlpha: 48)
        for radius: Float in [0, 12, 20] {
            let caster = ZTransferAndroidShadowMetrics.Caster(minimum: .zero, maximum: .init(40, 40), radius: radius)
            for height: Float in [Float(500).nextUp, 501, 1000] {
                let geometry = try XCTUnwrap(ZTransferAndroidShadowMetrics.shadowGeometry(caster: caster,
                    height: height, light: light.center, lightRadius: light.radius, transform: .identity, transparent: false))
                XCTAssertEqual(geometry.spot.insetWidth, 0)
                XCTAssertEqual(geometry.spot.blurWidth, 0)
                let scene = try XCTUnwrap(ZTransferAndroidShadowRenderer.scene(caster: caster, elevation: height,
                    lighting: light, transform: .identity))
                XCTAssertEqual(scene.layers.map(\.alpha), [9])
                let pixels = try render(scene.layers, width: scene.size.x, height: scene.size.y)
                let ambient = try XCTUnwrap(geometry.ambient.mesh())
                let localVertices = ambient.vertices.map {
                    ZTransferAndroidShadowMetrics.Vertex(position: $0.position - scene.origin,
                        offset: $0.offset, distanceCorrection: $0.distanceCorrection)
                }
                let independentLayer = ZTransferAndroidShadowRenderer.Layer(mesh: .init(kind: ambient.kind,
                    vertices: localVertices, indices: ambient.indices), alpha: 9)
                let expected = try render([independentLayer], width: scene.size.x, height: scene.size.y)
                XCTAssertEqual(pixels, expected, "spot omission must leave ambient rendering unchanged")
                // At height1000 the alpha9 ambient layer quantizes to zero on this
                // target. Visibility is only asserted at the light-height boundary.
                if height <= 501 {
                    XCTAssertTrue(stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 0 })
                }
                let spotOnly = ZTransferAndroidShadowMetrics.Lighting(center: light.center, radius: light.radius,
                    ambientAlpha: 0, spotAlpha: 48)
                XCTAssertNil(try ZTransferAndroidShadowRenderer.scene(caster: caster, elevation: height,
                    lighting: spotOnly, transform: .identity))
            }
        }
    }

    func testEqualLightHeightProducesBothRenderedLayers() throws {
        let light = ZTransferAndroidShadowMetrics.Lighting(center: .init(20, -30, 500),
            radius: 10, ambientAlpha: 9, spotAlpha: 48)
        let scene = try XCTUnwrap(ZTransferAndroidShadowRenderer.scene(
            caster: .init(minimum: .zero, maximum: .init(80, 40), radius: 12), elevation: 500,
            lighting: light, transform: .identity))
        XCTAssertEqual(scene.layers.map(\.alpha), [9, 48])
        let pixels = try render(scene.layers, width: scene.size.x, height: scene.size.y)
        XCTAssertTrue(stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 0 })
    }

    func testFastGeometryMatchesPinnedSkiaComposition() throws {
        struct Shape: Decodable {
            let bounds: [Float]
            let radius, blur, inset: Float
            let circle: Bool
        }
        struct Case: Decodable {
            let bounds, matrix, light: [Float]
            let radius, height, lightRadius: Float
            let transparent: Bool
            let ambient, spot: Shape
        }
        struct Reference: Decodable { let cases: [Case] }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "android15-shadow-fast", withExtension: "json"))
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        XCTAssertEqual(reference.cases.count, 1224)
        for (index, test) in reference.cases.enumerated() {
            let m = test.matrix, b = test.bounds, l = test.light
            let actual = try XCTUnwrap(ZTransferAndroidShadowMetrics.shadowGeometry(
                caster: .init(minimum: .init(b[0], b[1]), maximum: .init(b[2], b[3]), radius: test.radius),
                height: test.height, light: .init(l[0], l[1], l[2]), lightRadius: test.lightRadius,
                transform: .init(x: .init(m[0], m[1], m[2]), y: .init(m[3], m[4], m[5]),
                                 perspective: .init(m[6], m[7], m[8])), transparent: test.transparent))
            for (shape, expected) in [(actual.ambient, test.ambient), (actual.spot, test.spot)] {
                XCTAssertEqual([shape.caster.minimum.x, shape.caster.minimum.y,
                                shape.caster.maximum.x, shape.caster.maximum.y], expected.bounds, "case \(index)")
                XCTAssertEqual(shape.caster.radius, expected.radius, "case \(index)")
                XCTAssertEqual(shape.blurWidth, expected.blur, "case \(index)")
                XCTAssertEqual(shape.insetWidth, expected.inset, "case \(index)")
                XCTAssertEqual(shape.isCircle, expected.circle, "case \(index)")
            }
        }
    }

    func testNearSimilarityRetainsBothAxesAndSourceCircleRadius() throws {
        typealias Metrics = ZTransferAndroidShadowMetrics
        let yScale: Float = 1 + 1 / 8192
        let transform = ZTransferShadowTransform(x: .init(1, 0, 16),
            y: .init(0, yScale, 32), perspective: .init(0, 0, 1))
        let caster = Metrics.Caster(minimum: .zero, maximum: .init(40, 40), radius: 20)
        let pair = try XCTUnwrap(Metrics.shadowGeometry(caster: caster, height: 1,
            light: .init(16, 32, 5), lightRadius: 4, transform: transform, transparent: false))
        XCTAssertEqual(pair.ambient.caster.minimum, .init(15.5, -0.5 * yScale + 32))
        XCTAssertEqual(pair.ambient.caster.maximum, .init(56.5, 40.5 * yScale + 32))
        XCTAssertEqual(pair.ambient.caster.radius, 20.5)
        XCTAssertTrue(pair.ambient.isCircle)
        XCTAssertNotEqual(pair.ambient.caster.maximum.x - pair.ambient.caster.minimum.x,
                          pair.ambient.caster.maximum.y - pair.ambient.caster.minimum.y)
        // The light is at the translation, so inverse-mapped spot offset is zero.
        XCTAssertEqual(pair.spot.caster.minimum, .init(15, 32 - yScale))
        XCTAssertEqual(pair.spot.caster.maximum, .init(67, 51 * yScale + 32))
        XCTAssertEqual(pair.spot.caster.radius, 26)
        XCTAssertNotNil(pair.ambient.mesh())
        XCTAssertNotNil(pair.spot.mesh())
        let rejected = ZTransferShadowTransform(x: .init(1, 0, 0),
            y: .init(0, 1 + 1 / 2048, 0), perspective: .init(0, 0, 1))
        XCTAssertNil(Metrics.shadowGeometry(caster: caster, height: 1,
            light: .init(16, 32, 5), lightRadius: 4, transform: rejected, transparent: false))
    }

    func testAnalyticEligibilityAndInverseMatchPinnedSkia() throws {
        struct Case: Decodable {
            let matrix: [Float]
            let eligible, valid: Bool
            let inverse: [Float]?
        }
        struct Reference: Decodable { let cases: [Case] }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "android15-shadow-inverses", withExtension: "json"))
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        XCTAssertEqual(reference.cases.count, 235)
        for (index, test) in reference.cases.enumerated() {
            let m = test.matrix
            let transform = ZTransferShadowTransform(x: .init(m[0], m[1], m[2]),
                y: .init(m[3], m[4], m[5]), perspective: .init(m[6], m[7], m[8]))
            XCTAssertEqual(transform.supportsAnalyticShadow, test.eligible, "case \(index)")
            let inverse = transform.inverted()
            XCTAssertEqual(inverse != nil, test.valid, "case \(index)")
            if let inverse, let expected = test.inverse {
                XCTAssertEqual([inverse.x.x, inverse.x.y, inverse.x.z,
                    inverse.y.x, inverse.y.y, inverse.y.z,
                    inverse.perspective.x, inverse.perspective.y, inverse.perspective.z], expected,
                    "case \(index)")
            }
        }
    }

    private func render(_ layers: [ZTransferAndroidShadowRenderer.Layer], width: Int, height: Int,
                        tessellated: [ZTransferAndroidShadowRenderer.TessellatedLayer]? = nil,
                        resolved: ZTransferAndroidShadowRenderer.ResolvedScene? = nil) throws -> [UInt8] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "GPU coverage verification requires Metal")
        let renderer = try ZTransferAndroidShadowRenderer(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        if let resolved {
            try renderer.encodeResolved(scene: resolved, destination: target, commandBuffer: command)
        } else if let tessellated {
            try renderer.encodeTessellated(layers: tessellated, destination: target, commandBuffer: command)
        } else {
            try renderer.encode(layers: layers, destination: target, commandBuffer: command)
        }
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes {
            target.getBytes($0.baseAddress!, bytesPerRow: width * 4,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return pixels
    }

    private func load() throws -> Fixture {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "android15-shadow-metrics", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
}
