import XCTest
import UIKit
import CryptoKit
@testable import ZTransfer

/// Android 7690172b's five regression suites, exercised through iOS geometry,
/// the real renderer/JPEG lookup and both editors' common canvas identity.
final class PhotoFrameUniformBorderTests: XCTestCase {
    private let supported: [PhotoFramePreset] = [.mist, .cinema, .minimal, .frosted, .brandGallery, .classicSignature]
    private var noInformation: PhotoFrameMetadataSettings {
        .init(showDate: false, showTime: false, showFocalLength: false, showExposure: false,
              showBrand: false, showModel: false, showLensModel: false, showCoordinates: false,
              showAltitude: false, datePattern: "yyyy-MM-dd", timePattern: "HH:mm:ss")
    }
    private func recipe(_ preset: PhotoFramePreset = .minimal) -> PhotoEffectsSettings {
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true; settings.photoFrameBorderEnabled = true
        settings.photoFramePreset = preset; settings.metadata = noInformation
        settings.watermark.enabled = false
        return settings
    }
    private func image(width: Int = 320, height: Int = 213) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image {
            UIColor.red.setFill(); $0.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.blue.setFill(); $0.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        }
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uniform-\(UUID())")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("ZTFrames"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func saveIdentity(_ identity: String, name: String, directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("ZTFrames").appendingPathComponent(name)
        let jpeg = Data([0xff, 0xd8, 0xff, 0xda, 0, 2, 0xff, 0xd9])
        try XCTUnwrap(PhotoEffectIdentityJPEG.inserting(identity, into: jpeg)).write(to: url)
        return url
    }
    private func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func testEligibilityUsesSwitchesAndActualWatermarkPlacement() {
        for preset in PhotoFramePreset.allCases {
            var settings = recipe(preset)
            XCTAssertEqual(settings.usesUniformFrameBorder, supported.contains(preset), preset.rawValue)
            guard supported.contains(preset) else { continue }
            for position in PhotoFrameWatermarkPosition.allCases {
                settings.watermark.enabled = true; settings.watermark.position = position
                let expected = position.isPhotoPlacement || position == .auto && [.brandGallery, .classicSignature].contains(preset)
                XCTAssertEqual(settings.usesUniformFrameBorder, expected, "\(preset) \(position)")
                settings.watermark.content = .image; settings.watermark.imageHash = String(repeating: "a", count: 64)
                XCTAssertTrue(settings.usesUniformFrameBorder)
                settings.watermark.content = .text
            }
            settings.watermark.enabled = false
            var hidden = noInformation
            hidden.showAddress = true; hidden.datePattern = "MM-dd-yyyy"; hidden.widthPercent = 145
            settings.metadata = hidden
            XCTAssertTrue(settings.usesUniformFrameBorder)
            for field in [\PhotoFrameMetadataSettings.showDate, \.showTime, \.showFocalLength, \.showExposure,
                          \.showBrand, \.showModel, \.showLensModel, \.showCoordinates, \.showAltitude, \.showCity, \.showRegion] {
                var metadata = noInformation; metadata[keyPath: field] = true; settings.metadata = metadata
                XCTAssertEqual(settings.usesUniformFrameBorder,
                    preset == .brandGallery && field != \.showBrand && field != \.showModel)
            }
        }
    }

    func testGeometryMatchesExecutedAndroidStandardLayoutOracle() throws {
        // Unmodified Kotlin layout functions executed with Java 17/Kotlin 1.9.20.
        // Frozen numeric output is independent of the Swift implementation.
        let rows = """
        1000,667,60,1096,763,48.0,1159.0,869.0,721.26996
        1000,667,100,1160,827,80.0,1159.0,869.0,721.26996
        1000,667,145,1232,899,116.0,1159.0,869.0,721.26996
        1000,667,200,1320,987,160.0,1159.0,869.0,721.26996
        6000,4000,60,6576,4576,288.0,6954.0,5212.0,4325.6196
        6000,4000,100,6960,4960,480.0,6954.0,5212.0,4325.6196
        6000,4000,145,7392,5392,696.0,6954.0,5212.0,4325.6196
        6000,4000,200,7920,5920,960.0,6954.0,5212.0,4325.6196
        4000,6000,60,4384,6384,192.0,4636.0,6808.0,6217.08
        4000,6000,100,4640,6640,320.0,4636.0,6808.0,6217.08
        4000,6000,145,4928,6928,464.0,4636.0,6808.0,6217.08
        4000,6000,200,5280,7280,640.0,4636.0,6808.0,6217.08
        6597,6000,60,7231,6634,317.0,7645.9233,7332.5938,6358.019
        6597,6000,100,7653,7056,528.0,7645.9233,7332.5938,6358.019
        6597,6000,145,8129,7532,766.0,7645.9233,7332.5938,6358.019
        6597,6000,200,8709,8112,1056.0,7645.9233,7332.5938,6358.019
        1920,1746,60,2106,1932,93.0,2225.28,2133.84,1850.1984
        1920,1746,100,2228,2054,154.0,2225.28,2133.84,1850.1984
        1920,1746,145,2366,2192,223.0,2225.28,2133.84,1850.1984
        1920,1746,200,2536,2362,308.0,2225.28,2133.84,1850.1984
        4033,3025,60,4421,3413,194.0,4674.247,3839.666,3243.8708
        4033,3025,100,4679,3671,323.0,4674.247,3839.666,3243.8708
        4033,3025,145,4969,3961,468.0,4674.247,3839.666,3243.8708
        4033,3025,200,5325,4317,646.0,4674.247,3839.666,3243.8708
        80,120,60,88,128,4.0,92.72,136.16,124.3416
        80,120,100,94,134,7.0,92.72,136.16,124.3416
        80,120,145,100,140,10.0,92.72,136.16,124.3416
        80,120,200,106,146,13.0,92.72,136.16,124.3416
        """
        for row in rows.split(separator: "\n") {
            let values = row.split(separator: ",").map { Double($0)! }
            for preset in [PhotoFramePreset.mist, .cinema, .minimal, .frosted] {
                let layout = try PhotoFrameUniformGeometry(width: Int(values[0]), height: Int(values[1]),
                    preset: preset, percent: Int(values[2]))
                XCTAssertEqual(layout.canvas, CGSize(width: values[3], height: values[4]))
                XCTAssertEqual(layout.photo.minX, values[5])
                XCTAssertEqual(layout.designSize.width, values[6], accuracy: 0.001)
                XCTAssertEqual(layout.designSize.height, values[7], accuracy: 0.001)
                XCTAssertEqual(layout.designMetadataTop, values[8], accuracy: 0.001)
            }
        }
    }

    func testIdentityUsesActiveRenderFieldsRatherThanRememberedEditorDraft() {
        var settings = recipe(.minimal)
        let empty = photoEffectOutputIdentity(sourceName: "DSC.JPG", settings: settings)
        settings.metadataByPreset[PhotoFramePreset.minimal.rawValue] = .defaults(for: .minimal)
        XCTAssertEqual(empty, photoEffectOutputIdentity(sourceName: "DSC.JPG", settings: settings))
        settings.metadata.showDate = true
        let dated = photoEffectOutputIdentity(sourceName: "DSC.JPG", settings: settings)
        XCTAssertNotEqual(empty, dated)
        settings.metadataByPreset[PhotoFramePreset.minimal.rawValue] = noInformation
        XCTAssertEqual(dated, photoEffectOutputIdentity(sourceName: "DSC.JPG", settings: settings))
    }

    func testAllWidthsOrientationsAndCropHeightsPreserveEverySourcePixel() throws {
        for preset in supported {
            for size in [(6000,4000), (4000,6000), (4000,4000), (12000,3000), (3000,12000), (4033,3025), (80,120)] {
                var previous: CGFloat = 0
                for percent in stride(from: 60, through: 200, by: 5) {
                    let value = try PhotoFrameUniformGeometry(width: size.0, height: size.1, preset: preset, percent: percent)
                    XCTAssertEqual(value.photo.size, CGSize(width: size.0, height: size.1))
                    XCTAssertEqual(value.photo.minX, value.photo.minY)
                    XCTAssertEqual(value.photo.minX, value.canvas.width - value.photo.maxX)
                    XCTAssertEqual(value.photo.minX, value.canvas.height - value.photo.maxY)
                    XCTAssertGreaterThanOrEqual(value.photo.minX, previous); previous = value.photo.minX
                }
            }
            let reference = try PhotoFrameUniformGeometry(width: 6000, height: 4000, preset: preset, percent: 100)
            for height in [1500, 3157, 5454, 5455, 6000, 6667, 12000] {
                let cropped = try PhotoFrameUniformGeometry(width: 6000, height: height, preset: preset, percent: 100)
                XCTAssertEqual(reference.photo.minX, cropped.photo.minX)
                XCTAssertEqual(reference.designSize.width, cropped.designSize.width)
                XCTAssertEqual(reference.decorationBandHeight, cropped.decorationBandHeight, accuracy: 0.002)
            }
        }
        XCTAssertThrowsError(try PhotoFrameUniformGeometry(width: Int.max, height: 1, preset: .mist, percent: 200))
        XCTAssertThrowsError(try PhotoFrameUniformGeometry(width: 0, height: 1, preset: .mist, percent: 100))
    }

    func testIndependentDownsamplingDoesNotCrossLegacyAspectThresholds() throws {
        for aspect in [1.9, 1.1, 0.9, 0.72, 0.56] {
            for delta in [-1, 0, 1] {
                let w = Int((aspect * 6000).rounded()) + delta, h = 6000
                let scale = 1920 / Double(max(w, h))
                for preset in supported {
                    for percent in [60, 100, 200] {
                        let original = try PhotoFrameUniformGeometry(width: w, height: h, preset: preset, percent: percent)
                        let preview = try PhotoFrameUniformGeometry(width: Int((Double(w) * scale).rounded()), height: Int((Double(h) * scale).rounded()), preset: preset, percent: percent)
                        let a = 1920 / max(original.canvas.width, original.canvas.height)
                        let b = 1920 / max(preview.canvas.width, preview.canvas.height)
                        XCTAssertEqual(original.photo.minX * a, preview.photo.minX * b, accuracy: 1)
                        XCTAssertEqual(original.canvas.height * a, preview.canvas.height * b, accuracy: 1.1)
                    }
                }
            }
        }
    }

    func testRendererAndFHDUseTheUniformCanvasAndKeepBrandPhotoInformation() throws {
        let source = image()
        let metadata = PhotoFrameMetadata(make: "Example", model: "Z233", lensModel: "35mm", focalLength: "35mm",
            aperture: "f/2.8", shutter: "1/125", iso: "400", exposureCompensation: nil, dateTime: "2026:10:22 12:34:56")
        for preset in supported {
            var settings = recipe(preset)
            let geometry = try PhotoFrameUniformGeometry(width: 320, height: 213, preset: preset, percent: 100)
            let output = try PhotoEffectsRenderer.render(source, settings: settings, metadata: metadata)
            XCTAssertEqual(output.size, geometry.canvas)
            let preview = try PhotoEffectsRenderer.render(source, settings: settings, metadata: metadata, previewPlaceholders: true, previewLongEdge: 720)
            XCTAssertEqual(max(preview.size.width, preview.size.height), 720)
            if preset == .brandGallery {
                var fields = settings.metadata; fields.showExposure = true; fields.showLensModel = true
                settings.metadata = fields
                let details = try PhotoEffectsRenderer.render(source, settings: settings, metadata: metadata)
                XCTAssertEqual(details.size, output.size)
                XCTAssertNotEqual(details.pngData(), output.pngData(), "Photo-relative metadata must survive removal of the outer band")
            }
            let attachment = XCTAttachment(image: preview)
            attachment.name = "uniform-\(preset.rawValue)"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    func testCanvasIdentityIncludesUniformToggleButNotHiddenDraftsOrPhotoFields() {
        for preset in supported {
            var settings = recipe(preset)
            let uniform = photoEffectsPreviewCanvasKey(settings)
            var fields = settings.metadata; fields.showBrand = true; settings.metadata = fields
            XCTAssertNotEqual(uniform, photoEffectsPreviewCanvasKey(settings))
            settings.metadata = noInformation; settings.watermark.enabled = true; settings.watermark.position = .center
            XCTAssertNotEqual(uniform, photoEffectsPreviewCanvasKey(settings))
            settings.watermark.position = .photoTopRight
            XCTAssertEqual(uniform, photoEffectsPreviewCanvasKey(settings))
        }
        var gallery = recipe(.brandGallery), fields = noInformation
        let empty = photoEffectsPreviewCanvasKey(gallery)
        fields.showExposure = true; fields.showCity = true; gallery.metadata = fields
        XCTAssertEqual(empty, photoEffectsPreviewCanvasKey(gallery))
        gallery.photoFrameBorderEnabled = false
        let noBorder = photoEffectsPreviewCanvasKey(gallery)
        for preset in PhotoFramePreset.allCases {
            gallery.photoFramePreset = preset
            XCTAssertEqual(noBorder, photoEffectsPreviewCanvasKey(gallery))
        }
    }

    func testOldUnevenIdentitiesCannotClaimUniformOutputButUnaffectedTemplatesRemainCompatible() throws {
        // Frozen from Android's oldEmptyNames, not generated from the new Swift serializer.
        let fixtures: [(PhotoFramePreset, String)] = [
            (.mist, "DSC_frame_mist_w98254e54cd42.jpg"), (.cinema, "DSC_frame_dark_w25cdc577c6c3.jpg"),
            (.minimal, "DSC_frame_clean_w8bf9b7187989.jpg"), (.frosted, "DSC_frame_glass_w26ce5566474d.jpg"),
            (.brandGallery, "DSC_frame_brand_gallery_w55c83a3b2c31.jpg"), (.classicSignature, "DSC_frame_classic_signature_we76696d45521.jpg"),
            (.plaque, "DSC_frame_plaque_w13c6c8f01b6e.jpg"), (.immersive, "DSC_frame_immersive_w664b73e7fdad.jpg"),
            (.brandInset, "DSC_frame_brand_inset_wf5abb1d01c0d.jpg"), (.galleryMat, "DSC_frame_gallery_mat_w6166c0f684de.jpg"),
            (.colorArchive, "DSC_frame_color_archive_w344dee657c94.jpg"), (.filmGallery, "DSC_frame_film_gallery_w974937f2f840.jpg"),
            (.filmEdge, "DSC_frame_film_edge_w6166c0f684de.jpg"), (.filmNegative, "DSC_frame_film_negative_waed74e7a2df8.jpg"),
            (.parameterPoster, "DSC_frame_parameter_poster_wbfd283642864.jpg")]
        for (preset, oldName) in fixtures {
            let settings = recipe(preset), oldIdentity = hash(oldName.lowercased())
            let current = photoEffectOutputIdentity(sourceName: "DSC.JPG", settings: settings)
            XCTAssertEqual(current == oldIdentity, !supported.contains(preset), preset.rawValue)
            let dir = try directory(), source = dir.appendingPathComponent("DSC.JPG")
            _ = try saveIdentity(oldIdentity, name: oldName, directory: dir)
            _ = try saveIdentity(oldIdentity, name: "DSC_f (2).jpg", directory: dir)
            XCTAssertEqual(TransferQueue.existingFrameURL(source: source, settings: settings, in: dir) != nil, !supported.contains(preset))
            _ = try saveIdentity(current, name: "dsc_f_3.JPG", directory: dir)
            XCTAssertNotNil(TransferQueue.existingFrameURL(source: source, settings: settings, in: dir))
        }
    }

    func testAmbiguousAutomaticAndCenterBothRejectOldIdentity() throws {
        let fixtures: [(PhotoFramePreset, String)] = [(.classicSignature, "11c12abf43d3"), (.colorArchive, "2397b746076e"), (.filmEdge, "11c12abf43d3"), (.parameterPoster, "11c12abf43d3")]
        for (preset, fingerprint) in fixtures {
            var settings = recipe(preset); settings.metadata = .defaults(for: preset); settings.watermark = .init()
            let oldSuffix: String = switch preset {
            case .classicSignature: "classic_signature"
            case .colorArchive: "color_archive"
            case .filmEdge: "film_edge"
            default: "parameter_poster"
            }
            let previous = hash("dsc_frame_\(oldSuffix)_w\(fingerprint).jpg")
            let automatic = photoEffectOutputIdentity(sourceName: "DSC.JPG", settings: settings)
            settings.watermark.position = .center
            let centered = photoEffectOutputIdentity(sourceName: "DSC.JPG", settings: settings)
            XCTAssertNotEqual(automatic, centered); XCTAssertNotEqual(automatic, previous); XCTAssertNotEqual(centered, previous)
            settings.photoFrameBorderEnabled = false
            let flat = photoEffectOutputIdentity(sourceName: "DSC.JPG", settings: settings)
            settings.watermark.position = .auto
            XCTAssertEqual(flat, photoEffectOutputIdentity(sourceName: "DSC.JPG", settings: settings))
        }
    }

    func testPlaceIdentityUsesOnlySelectedTrimmedTextAndUTF16Lengths() {
        var settings = recipe(.brandGallery), fields = noInformation
        fields.showCity = true; fields.showRegion = true; settings.metadata = fields
        let missing = photoEffectOutputIdentity(sourceName: "DSC.JPG", settings: settings)
        XCTAssertEqual(missing, photoEffectOutputIdentity(sourceName: "DSC.JPG", settings: settings, renderedPlace: .init(city: " \t", region: "\n")))
        let place = PhotoFramePlace(city: " 杭州🗺 ", region: " 西湖 ")
        let identity = photoEffectOutputIdentity(sourceName: "DSC.JPG", settings: settings, renderedPlace: place)
        let expected = hash(androidPhotoFrameOutputName(sourceName: "DSC.JPG", settings: settings).lowercased() + "\0place-v=1\0city=4:杭州🗺\0region=2:西湖")
        XCTAssertEqual(identity, expected); XCTAssertNotEqual(missing, identity)
        fields.showRegion = false; settings.metadata = fields
        XCTAssertEqual(photoEffectOutputIdentity(sourceName: "DSC.JPG", settings: settings, renderedPlace: place),
                       photoEffectOutputIdentity(sourceName: "DSC.JPG", settings: settings, renderedPlace: .init(city: "杭州🗺", region: "上城")))
        settings.photoFrameBorderEnabled = false
        XCTAssertEqual(photoEffectOutputIdentity(sourceName: "DSC.JPG", settings: settings), photoEffectOutputIdentity(sourceName: "DSC.JPG", settings: settings, renderedPlace: place))
    }

    func testSamePlaceReusesNumberedJPEGWhileMissingChangedAndLegacyPlacesDoNot() throws {
        let dir = try directory(), source = dir.appendingPathComponent("DSC.JPG")
        var settings = recipe(.brandGallery), fields = noInformation
        fields.showCity = true; fields.showRegion = true; settings.metadata = fields
        let place = PhotoFramePlace(city: "杭州", region: "西湖")
        let identity = photoEffectOutputIdentity(sourceName: "DSC.JPG", settings: settings, renderedPlace: place)
        let saved = try saveIdentity(identity, name: "dsc_f_12.JPG", directory: dir)
        XCTAssertEqual(TransferQueue.existingFrameURL(source: source, settings: settings, in: dir, renderedPlace: place), saved)
        XCTAssertNil(TransferQueue.existingFrameURL(source: source, settings: settings, in: dir))
        XCTAssertNil(TransferQueue.existingFrameURL(source: source, settings: settings, in: dir, renderedPlace: .init(city: "杭州", region: "上城")))
        _ = try saveIdentity(identity, name: androidPhotoFrameOutputName(sourceName: "DSC.JPG", settings: settings), directory: dir)
        try FileManager.default.removeItem(at: saved)
        XCTAssertNil(TransferQueue.existingFrameURL(source: source, settings: settings, in: dir, renderedPlace: place), "An old long name never proves rendered location")
    }

    func testEveryTemplatePlaceLookupKeepsFilterAndGrainRecipesIndependent() throws {
        for preset in PhotoFramePreset.allCases {
            let dir = try directory(), source = dir.appendingPathComponent("DSC.JPG")
            var settings = recipe(preset)
            settings.metadata.showCity = true; settings.metadata.showRegion = true
            settings.photoFilterEnabled = true
            settings.selectedFilter = .init(preset: .init(id: "uniform-place", name: "Uniform"), intensityPercent: 72)
            settings.photoGrain = .init(intensityPercent: 40, enabled: true, style: .medium)
            for place: PhotoFramePlace? in [nil, .init(city: "杭州", region: nil), .init(city: "杭州", region: "西湖")] {
                let identity = photoEffectOutputIdentity(sourceName: "DSC.JPG", settings: settings, renderedPlace: place)
                let saved = try saveIdentity(identity, name: "dsc_f_e_g (3).JPG", directory: dir)
                XCTAssertEqual(TransferQueue.existingFrameURL(source: source, settings: settings, in: dir, renderedPlace: place), saved)
                var changed = settings
                changed.selectedFilter?.intensityPercent = 74
                XCTAssertNil(TransferQueue.existingFrameURL(source: source, settings: changed, in: dir, renderedPlace: place))
                changed = settings; changed.photoGrain.style = .coarse
                XCTAssertNil(TransferQueue.existingFrameURL(source: source, settings: changed, in: dir, renderedPlace: place))
                changed = settings; changed.photoGrain = .off
                XCTAssertNil(TransferQueue.existingFrameURL(source: source, settings: changed, in: dir, renderedPlace: place))
                XCTAssertNil(TransferQueue.existingFrameURL(source: source, settings: settings, in: dir,
                    renderedPlace: .init(city: "宁波", region: "海曙")))
            }
        }
    }

    func testQueueRendererWritesExactlyThePlaceUsedAfterNetworkGate() async throws {
        let dir = try directory(), source = dir.appendingPathComponent("DSC.JPG")
        try XCTUnwrap(image().jpegData(compressionQuality: 0.9)).write(to: source)
        var settings = recipe(.brandGallery), fields = noInformation
        fields.showCity = true; fields.showRegion = true; settings.metadata = fields
        let metadata = PhotoFrameMetadata(make: "Example", model: "Z233", lensModel: nil, focalLength: "35mm", aperture: "f/2.8", shutter: "1/125", iso: "400", exposureCompensation: nil, dateTime: nil,
            latitude: 30.25, longitude: 120.15, city: "杭州", region: "西湖")
        let cleared = metadata.withAllowedFramePlace(false)
        XCTAssertNil(cleared.city); XCTAssertNil(cleared.region); XCTAssertEqual(cleared.latitude, metadata.latitude); XCTAssertEqual(cleared.model, metadata.model)
        for allowed in [false, true] {
            let output = try await TransferQueue.renderFrameFile(source: source, settings: settings, directory: dir, metadata: metadata, placeAllowed: { allowed }, placeAlreadyPrepared: true)
            let place = allowed ? metadata.renderedPlace : nil
            XCTAssertEqual(PhotoEffectIdentityJPEG.read(from: output), photoEffectOutputIdentity(sourceName: "DSC.JPG", settings: settings, renderedPlace: place))
            XCTAssertEqual(TransferQueue.existingFrameURL(source: source, settings: settings, in: dir, renderedPlace: place), output)
        }
    }

    @MainActor func testQueueReusesOutputAndKeepsEffectLabelWithSeparateSkippedState() async throws {
        let dir = try directory(), source = dir.appendingPathComponent("DSC.JPG")
        let bytes = try XCTUnwrap(image().jpegData(compressionQuality: 0.9)); try bytes.write(to: source)
        let suite = "UniformQueue-\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        // Both preflight (no place fields) and generation-worker lookup (place fields) must skip.
        for places in [false, true] {
            var settings = recipe(.brandGallery), fields = noInformation
            fields.showCity = places; settings.metadata = fields
            let saved = try saveIdentity(photoEffectOutputIdentity(sourceName: "DSC.JPG", settings: settings), name: "DSC_f.jpg", directory: dir)
            let queue = TransferQueue(defaults: UserDefaults(suiteName: suite)!, premiumAccess: PremiumAccess(.lifetime), placeAllowed: { false }, renderFrame: { _, _, _, _ in
                XCTFail("An existing exact effect must never render again"); throw CocoaError(.fileWriteUnknown)
            })
            let file = CameraFile(id: 1, storageID: 1, format: 0x3801, size: UInt64(bytes.count), fileName: "DSC.JPG", captureDate: "20261022T120000", isProtected: false)
            await queue.enqueue(file, effects: settings); await queue.start(session: nil, directory: dir)
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            var state = await queue.snapshot()
            while ContinuousClock.now < deadline && (state.items.first?.status != .completed || state.isTransferring || state.items.first?.isGeneratingFrame == true) {
                try await Task.sleep(for: .milliseconds(10)); state = await queue.snapshot()
            }
            let item = try XCTUnwrap(state.items.first)
            XCTAssertEqual(item.frameURL, saved); XCTAssertTrue(item.frameGenerationSkipped)
            XCTAssertNil(item.frameGenerationElapsedMs); XCTAssertNil(item.frameError)
            XCTAssertEqual(TransferQueueCardText(item: item).effectText, AppLocalized.resource("photo_frame_brand_gallery"))
            XCTAssertFalse(TransferQueueCardText(item: item).generationWaiting)
            await queue.closePhotoGeneration()
        }
    }

    @MainActor func testComparisonConfirmsOnceAndRespectsPreference() {
        let suite = "UniformHaptics-\(UUID())", prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        var events: [HapticFeedbackEvent] = []
        let input = PhotoEffectsImageInput.InputView()
        input.haptics = ZTransferHaptics(defaults: prefs, output: { events.append($0) })
        XCTAssertEqual(input.hold.minimumPressDuration, 0.5)
        XCTAssertTrue(events.isEmpty)
        input.setComparing(true); input.setComparing(true); input.setComparing(false); input.cancel()
        XCTAssertEqual(events, [.feedback(.holdConfirmed)])
        prefs.set(false, forKey: HapticPreference.key)
        input.setComparing(true); input.cancel()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(PhotoEffectModule.allCases.map(\.rawValue), [1, 2, 16, 4, 8])
        XCTAssertEqual(allPhotoEffectModules, 31)
    }
}
