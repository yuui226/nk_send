import XCTest
import Combine
@testable import ZTransfer

final class PhotoFramePlaceTests: XCTestCase {
    func testChineseDistrictDoesNotBecomeCity() {
        XCTAssertEqual(photoFramePlace(city: "西湖区", district: "西湖区", subAdmin: "杭州市", admin: "浙江省", countryCode: "CN"), PhotoFramePlace(city: "杭州市", region: "西湖区"))
    }
    func testAndroidAdministrativeHierarchyCases() {
        let cases: [(String?, String?, String?, String?, String?, String?, String?)] = [
            (nil, "黄浦区", nil, "上海市", nil, "上海市", "黄浦区"),
            (nil, "渝中區", nil, "重慶市", "CN", "重慶市", "渝中區"),
            (nil, "Haidian District", nil, "Beijing", "CN", "Beijing", "Haidian District"),
            (nil, "市辖区", nil, "上海市", "CN", "上海市", nil),
            (nil, nil, "桐庐县", "浙江省", "CN", nil, "桐庐县"),
            ("浙江省", nil, nil, "浙江省", "CN", nil, nil),
            (nil, "广西壮族自治区", nil, "广西壮族自治区", "CN", nil, nil),
            ("杭州市", "高新区", nil, "浙江省", "CN", "杭州市", nil),
            ("杭州市", "幸福社区", "西湖区", "浙江省", "CN", "杭州市", "西湖区"),
            ("幸福社区", nil, "杭州市", "浙江省", "CN", "杭州市", nil),
            ("新宿区", nil, nil, "東京都", "JP", "新宿区", nil),
            (nil, nil, "Santa Clara County", "California", "US", nil, "Santa Clara County"),
            ("Santa Clara County", nil, nil, "California", "US", nil, "Santa Clara County"),
            ("San Jose", "Downtown", "Santa Clara County", "California", "US", "San Jose", "Santa Clara County"),
            ("New York", "SoHo", nil, "New York", "US", "New York", nil),
            (" Paris ", "Montmartre", "PARIS", "Île-de-France", "FR", "Paris", nil),
            (" ", nil, nil, "California", "US", nil, nil)
        ]
        for (city, district, subdivision, admin, country, expectedCity, expectedRegion) in cases {
            XCTAssertEqual(photoFramePlace(city: city, district: district, subAdmin: subdivision, admin: admin, countryCode: country),
                           PhotoFramePlace(city: expectedCity, region: expectedRegion), "country=\(country ?? "nil"), city=\(city ?? "nil")")
        }
    }

    func testRejectsZeroPlaceholderButAllowsEquatorOnly() {
        XCTAssertFalse(validPhotoFrameCoordinates(0, 0)); XCTAssertTrue(validPhotoFrameCoordinates(0, 120)); XCTAssertFalse(validPhotoFrameCoordinates(91, 0))
    }
}


final class PhotoFramePlaceCacheTests: XCTestCase {
    func testPositiveAndNegativeEntriesHaveAndroidExpiryBoundaries() throws {
        var cache = PhotoFramePlaceCache()
        let place = PhotoFramePlace(city: "Paris", region: nil)
        cache.insert(place, for: "positive", now: 100)
        cache.insert(nil, for: "negative", now: 100)
        XCTAssertEqual(cache.entry(for: "positive", now: 86_499)?.place, place)
        XCTAssertNil(cache.entry(for: "positive", now: 86_500))
        let negative = try XCTUnwrap(cache.entry(for: "negative", now: 159.999))
        XCTAssertNil(negative.place, "Cached failure must be distinguishable from a cache miss")
        XCTAssertNil(cache.entry(for: "negative", now: 160))
        cache.insert(place, for: "negative", now: 161)
        XCTAssertEqual(cache.entry(for: "negative", now: 162)?.place, place)
    }

    func testAccessOrderEvictsOldestAtThirtyTwoAndLocaleSeparatesKeys() {
        var cache = PhotoFramePlaceCache()
        for index in 0..<32 { cache.insert(nil, for: String(index), now: 0) }
        XCTAssertNotNil(cache.entry(for: "0", now: 1))
        cache.insert(nil, for: "32", now: 2)
        XCTAssertEqual(cache.count, 32)
        XCTAssertNil(cache.entry(for: "1", now: 3))
        XCTAssertNotNil(cache.entry(for: "0", now: 3))
        XCTAssertNotNil(cache.entry(for: "32", now: 3))
        let key = PhotoFramePlaceCache.key(latitude: 30.25, longitude: 120.15, locale: Locale(identifier: "zh_CN"))
        XCTAssertEqual(key, "zh-CN:30.2500,120.1500")
        XCTAssertNotEqual(key, PhotoFramePlaceCache.key(latitude: 30.25, longitude: 120.15, locale: Locale(identifier: "en_US")))
        XCTAssertEqual(key, PhotoFramePlaceCache.key(latitude: 30.25001, longitude: 120.15001, locale: Locale(identifier: "zh_CN")))
    }
}

private actor SuspendedPlaceBackend {
    private(set) var calls: [Double] = []
    private var pending: [Double: CheckedContinuation<PhotoFramePlace?, Never>] = [:]
    func query(_ latitude: Double) async -> PhotoFramePlace? {
        calls.append(latitude)
        return await withCheckedContinuation { pending[latitude] = $0 }
    }
    func release(_ latitude: Double, city: String = "Result") {
        pending.removeValue(forKey: latitude)?.resume(returning: PhotoFramePlace(city: city, region: nil))
    }
    func waitForCalls(_ count: Int) async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(2))
        while calls.count < count, ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(calls.count, count)
    }
}

final class PhotoFramePlaceResolverTests: XCTestCase {
    func testTimeoutReturnsWithoutWaitingForUncooperativeBackendAndDiscardsLateResult() async throws {
        let backend = SuspendedPlaceBackend()
        let resolver = PhotoFramePlaceResolver { latitude, _, _ in await backend.query(latitude) }
        let started = ContinuousClock.now
        let result = await resolver.resolve(latitude: 10, longitude: 20, timeout: .milliseconds(80))
        XCTAssertNil(result)
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        await backend.release(10, city: "Late")
        let cached = await resolver.resolve(latitude: 10, longitude: 20)
        XCTAssertNil(cached)
        let calls = await backend.calls
        XCTAssertEqual(calls, [10])
    }

    func testQueuedTimeoutDoesNotStartBackendOrCacheAnUnattemptedCoordinate() async throws {
        let backend = SuspendedPlaceBackend()
        let resolver = PhotoFramePlaceResolver { latitude, _, _ in await backend.query(latitude) }
        let first = Task { await resolver.resolve(latitude: 10, longitude: 20) }
        try await backend.waitForCalls(1)
        let expired = await resolver.resolve(latitude: 11, longitude: 20, timeout: .milliseconds(50))
        XCTAssertNil(expired)
        let before = await backend.calls
        XCTAssertEqual(before, [10])
        await backend.release(10)
        let firstResult = await first.value
        XCTAssertEqual(firstResult?.city, "Result")
        let retry = Task { await resolver.resolve(latitude: 11, longitude: 20) }
        try await backend.waitForCalls(2)
        // A completed cache hit must not queue behind this suspended lookup.
        let hit = await resolver.resolve(latitude: 10, longitude: 20, timeout: .zero)
        XCTAssertEqual(hit?.city, "Result")
        await backend.release(11)
        let retried = await retry.value
        XCTAssertEqual(retried?.city, "Result")
    }

    func testQueuedConnectivityLossSkipsBackendWithoutNegativeCaching() async throws {
        let backend = SuspendedPlaceBackend()
        let availability = PlaceAvailabilityFixture()
        let resolver = PhotoFramePlaceResolver { latitude, _, _ in await backend.query(latitude) }
        let first = Task { await resolver.resolve(latitude: 10, longitude: 20) }
        try await backend.waitForCalls(1)
        let second = Task {
            await resolver.resolve(latitude: 11, longitude: 20, allowed: { await availability.allowed })
        }
        let limit = ContinuousClock.now.advanced(by: .milliseconds(500))
        while await resolver.pendingCount != 2, ContinuousClock.now < limit {
            try await Task.sleep(for: .milliseconds(5))
        }
        let pending = await resolver.pendingCount
        XCTAssertEqual(pending, 2)
        await availability.block()
        await backend.release(10)
        _ = await first.value
        let blocked = await second.value
        XCTAssertNil(blocked)
        let calls = await backend.calls
        XCTAssertEqual(calls, [10])
        let retry = Task { await resolver.resolve(latitude: 11, longitude: 20) }
        try await backend.waitForCalls(2)
        await backend.release(11)
        let result = await retry.value
        XCTAssertEqual(result?.city, "Result", "A blocked, unattempted request must not poison the cache")
    }

    func testParentCancellationReleasesSerialSlotBeforeBackendReturns() async throws {
        let backend = SuspendedPlaceBackend()
        let resolver = PhotoFramePlaceResolver { latitude, _, _ in await backend.query(latitude) }
        let first = Task { await resolver.resolve(latitude: 10, longitude: 20) }
        try await backend.waitForCalls(1)
        first.cancel()
        let cancelled = await first.value
        XCTAssertNil(cancelled)
        let next = Task { await resolver.resolve(latitude: 11, longitude: 20) }
        try await backend.waitForCalls(2)
        await backend.release(10, city: "Discard")
        await backend.release(11, city: "Next")
        let result = await next.value
        XCTAssertEqual(result?.city, "Next")
        let stale = await resolver.resolve(latitude: 10, longitude: 20)
        XCTAssertNil(stale)
    }
}


private actor PlaceAvailabilityFixture {
    var allowed = true
    func block() { allowed = false }
}

final class PhotoFramePlaceGatingTests: XCTestCase {
    private func metadata() -> PhotoFrameMetadata {
        PhotoFrameMetadata(make: "Nikon", model: "Z8", lensModel: nil, focalLength: nil,
            aperture: nil, shutter: nil, iso: nil, exposureCompensation: nil, dateTime: nil,
            latitude: 0, longitude: 120, altitude: 520, city: "Old city", region: "Old region")
    }

    func testBlockedOrDisabledLookupClearsOldPlaceAndPreservesEXIF() async {
        let resolver = PhotoFramePlaceResolver { _, _, _ in XCTFail("Blocked lookup started"); return nil }
        var settings = PhotoFrameMetadataSettings()
        settings.showCity = true
        let blocked = await resolver.enriching(metadata(), settings: settings, allowed: { false })
        XCTAssertNil(blocked.city); XCTAssertNil(blocked.region)
        XCTAssertEqual(blocked.latitude, 0); XCTAssertEqual(blocked.longitude, 120)
        XCTAssertEqual(blocked.altitude, 520); XCTAssertEqual(blocked.model, "Z8")
        settings.showCity = false
        let disabled = await resolver.enriching(metadata(), settings: settings, allowed: { XCTFail("Disabled fields inspected network"); return true })
        XCTAssertNil(disabled.city); XCTAssertNil(disabled.region)
    }

    func testConnectivityLossDuringLookupDropsPlaceAndBlockedCacheHitDoesNotLeak() async {
        let availability = PlaceAvailabilityFixture()
        let resolver = PhotoFramePlaceResolver { _, _, _ in
            await availability.block()
            return PhotoFramePlace(city: "New city", region: "New region")
        }
        var settings = PhotoFrameMetadataSettings(); settings.showRegion = true
        let result = await resolver.enriching(metadata(), settings: settings, allowed: { await availability.allowed })
        XCTAssertNil(result.city); XCTAssertNil(result.region)
        let cached = await resolver.enriching(metadata(), settings: settings, allowed: { false })
        XCTAssertNil(cached.city); XCTAssertNil(cached.region)
    }
}


final class LocalPhotoLocationScopeTests: XCTestCase {
    @MainActor
    func testLocalStoreClearsAllLocationFieldsAcrossPresetsAndReload() {
        let suite = "local-place-scope-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = PhotoEffectsSettings()
        for preset in PhotoFramePreset.allCases {
            var fields = PhotoFrameMetadataSettings.defaults(for: preset)
            fields.showAddress = true; fields.showCity = true; fields.showRegion = true
            fields.showCoordinates = true; fields.showAltitude = true
            settings.metadataByPreset[preset.rawValue] = fields
        }
        settings.metadata = settings.metadataByPreset[settings.photoFramePreset.rawValue]!
        let camera = PhotoEffectsStore(defaults: defaults, scope: .cameraTransfer)
        camera.update(settings)
        XCTAssertTrue(camera.settings.metadata.showCity)
        let local = PhotoEffectsStore(defaults: defaults, scope: .localPhotos)
        local.update(settings)
        let restored = PhotoEffectsStore(defaults: defaults, scope: .localPhotos)
        for value in [local.settings, restored.settings] {
            for preset in PhotoFramePreset.allCases {
                let fields = value.metadataByPreset[preset.rawValue] ?? .defaults(for: preset)
                XCTAssertFalse(fields.showAddress); XCTAssertFalse(fields.showCity); XCTAssertFalse(fields.showRegion)
                XCTAssertFalse(fields.showCoordinates); XCTAssertFalse(fields.showAltitude)
            }
        }
        XCTAssertTrue(camera.settings.metadata.showCity)
    }
}


final class PhotoFramePlacePresentationTests: XCTestCase {
    func testLanguageExamplesNeverEnterExportsAndSwitchesRemainIndependent() {
        let cases = [("en", "Light & Shadow City", "Blue Hour District"),
                     ("fr", "Light & Shadow City", "Blue Hour District"),
                     ("zh-CN", "光影市", "蓝调区"), ("zh-Hant", "光影市", "藍調區"),
                     ("zh-TW", "光影市", "藍調區"), ("zh-HK", "光影市", "藍調區"),
                     ("zh-MO", "光影市", "藍調區")]
        for (tag, city, region) in cases {
            for showCity in [false, true] {
                for showRegion in [false, true] {
                    var settings = PhotoFrameMetadataSettings()
                    settings.showCity = showCity; settings.showRegion = showRegion
                    let preview = presentedPhotoFrameMetadata(nil, settings: settings, preview: true, locale: Locale(identifier: tag))
                    XCTAssertEqual(preview.city, showCity ? city : nil)
                    XCTAssertEqual(preview.region, showRegion ? region : nil)
                    let export = presentedPhotoFrameMetadata(nil, settings: settings, locale: Locale(identifier: tag))
                    XCTAssertNil(export.city); XCTAssertNil(export.region)
                }
            }
        }
        XCTAssertEqual(photoFramePlaceLocale(language: "en", systemLocale: Locale(identifier: "zh-CN")).language.languageCode?.identifier, "en")
        XCTAssertEqual(photoFramePlaceLocale(language: "system", systemLocale: Locale(identifier: "zh-Hant")).identifier, "zh-Hant")
    }

    func testRealPlaceIsTrimmedAndTakesPrecedenceOverPreviewExample() {
        var settings = PhotoFrameMetadataSettings(); settings.showCity = true; settings.showRegion = true
        let source = PhotoFrameMetadata(make: nil, model: nil, lensModel: nil, focalLength: nil,
            aperture: nil, shutter: nil, iso: nil, exposureCompensation: nil, dateTime: nil,
            city: "  Paris  ", region: "  ")
        let preview = presentedPhotoFrameMetadata(source, settings: settings, preview: true, locale: Locale(identifier: "en"))
        XCTAssertEqual(preview.city, "Paris"); XCTAssertEqual(preview.region, "Blue Hour District")
        let exported = presentedPhotoFrameMetadata(source, settings: settings)
        XCTAssertEqual(exported.city, "Paris"); XCTAssertNil(exported.region)
    }
}

final class PhotoFramePlaceAvailabilityTests: XCTestCase {
    @MainActor
    func testAPBlocksDefaultPathWhileActiveUSBAndSTAUseIt() {
        let state = PhotoFramePlaceAvailability()
        XCTAssertFalse(state.allowed)
        state.updatePath(true)
        XCTAssertFalse(state.allowed, "Starts blocked until the connection owner supplies its mode")
        state.updateConnection(wirelessMode: .sta, isUSB: false)
        XCTAssertTrue(state.allowed)
        state.updateConnection(wirelessMode: .ap, isUSB: false)
        XCTAssertFalse(state.allowed)
        state.updateConnection(wirelessMode: .ap, isUSB: true)
        XCTAssertTrue(state.allowed)
        state.updatePath(false)
        XCTAssertFalse(state.allowed)
        state.updatePath(true)
        XCTAssertTrue(state.allowed)
        state.updateConnection(wirelessMode: .ap, isUSB: false)
        XCTAssertFalse(state.allowed)
        state.updateConnection(wirelessMode: .sta, isUSB: false)
        XCTAssertTrue(state.allowed)
        state.stop()
        XCTAssertFalse(state.allowed)
    }
}

final class PhotoFramePlaceOutputReuseTests: XCTestCase {
    func testPlaceExportsBypassExistingNamesButHiddenPlaceFieldsStillReuse() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let frames = directory.appendingPathComponent("ZTFrames")
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("camera.jpg")
        for border in [false, true] {
            for city in [false, true] {
                for region in [false, true] {
                    var settings = PhotoEffectsSettings()
                    settings.photoFrameEnabled = true
                    settings.photoFrameBorderEnabled = border
                    var metadata = settings.metadata
                    metadata.showCity = city
                    metadata.showRegion = region
                    settings.metadata = metadata
                    let output = frames.appendingPathComponent(
                        androidPhotoFrameOutputName(sourceName: source.lastPathComponent, settings: settings))
                    let previous = Data("existing offline export".utf8)
                    try previous.write(to: output)
                    let found = TransferQueue.existingFrameURL(source: source, settings: settings, in: directory)
                    if border && (city || region) { XCTAssertNil(found) }
                    else { XCTAssertNotNil(found) }
                    XCTAssertEqual(try Data(contentsOf: output), previous)
                }
            }
        }
    }
}

final class PhotoFrameMetadataPersistenceTests: XCTestCase {
    @MainActor
    func testEveryPresetNewFieldsSurviveBothStoreScopes() {
        let suite = "metadata-new-fields-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for scope in [PhotoEffectsStore.Scope.cameraTransfer, .localPhotos] {
            var settings = PhotoEffectsSettings()
            for (index, preset) in PhotoFramePreset.allCases.enumerated() {
                var fields = PhotoFrameMetadataSettings.defaults(for: preset)
                fields.showCity = scope == .cameraTransfer
                fields.showRegion = scope == .cameraTransfer
                fields.brandStyle = .logo
                fields.widthPercent = 60 + (index % 20) * 5
                fields.backgroundBlurPercent = index * 3
                fields.backgroundMaskPercent = 170 - index
                settings.metadataByPreset[preset.rawValue] = fields
            }
            settings.metadata = settings.metadataByPreset[settings.photoFramePreset.rawValue]!
            let store = PhotoEffectsStore(defaults: defaults, scope: scope)
            store.update(settings)
            let saved = store.settings.metadataByPreset
            let restored = PhotoEffectsStore(defaults: defaults, scope: scope)
            XCTAssertEqual(restored.settings.metadataByPreset, saved)
        }
        let camera = PhotoEffectsStore(defaults: defaults, scope: .cameraTransfer)
        XCTAssertTrue(camera.settings.metadata.showCity)
        XCTAssertEqual(camera.settings.metadata.brandStyle, .logo)
    }

    @MainActor
    func testModernAndroidFormatsRestoreAndRejectMalformedFields() {
        let suite = "metadata-formats-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let base = "MIST|true|true|true|true|true|true|false|false|false|yyyy-MM-dd|HH:mm:ss"
        for suffix in ["|true|false", "|true|false|LOGO", "|true|false|LOGO|65", "|true|false|LOGO|65|0|170"] {
            defaults.set(base + suffix, forKey: "photo_frame_metadata_settings_v1")
            let fields = PhotoEffectsStore(defaults: defaults).settings.metadataByPreset[PhotoFramePreset.mist.rawValue]
            XCTAssertEqual(fields?.showCity, true)
            XCTAssertEqual(fields?.showRegion, false)
            XCTAssertEqual(fields?.brandStyle, suffix.contains("LOGO") ? .logo : .text)
            XCTAssertEqual(fields?.widthPercent, suffix.contains("65") ? 65 : 100)
            XCTAssertEqual(fields?.backgroundMaskPercent, suffix.contains("170") ? 170 : 100)
        }
        for suffix in ["|TRUE|false", "|true|false|unknown", "|true|false|LOGO|2147483648", "|true|false|LOGO|65|bad|170"] {
            defaults.set(base + suffix, forKey: "photo_frame_metadata_settings_v1")
            XCTAssertNil(PhotoEffectsStore(defaults: defaults).settings.metadataByPreset[PhotoFramePreset.mist.rawValue])
        }
    }
    @MainActor
    func testBoundaryNormalizationAndFirstNondefaultEntryWins() {
        let suite = "metadata-boundaries-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let base = "MIST|true|true|true|true|true|true|false|false|false|yyyy-MM-dd|HH:mm:ss"
        let low = base + "|true|false|TEXT|-2147483648|-10|2147483647"
        let high = base + "|false|true|LOGO|2147483647|210|-1"
        defaults.set(low + ";" + high, forKey: "photo_frame_metadata_settings_v1")
        let first = PhotoEffectsStore(defaults: defaults).settings.metadata
        XCTAssertEqual(first.widthPercent, 60)
        XCTAssertEqual(first.backgroundBlurPercent, 0)
        XCTAssertEqual(first.backgroundMaskPercent, 200)
        XCTAssertTrue(first.showCity)
        XCTAssertFalse(first.showRegion)
        defaults.set(high + ";" + low, forKey: "photo_frame_metadata_settings_v1")
        let second = PhotoEffectsStore(defaults: defaults).settings.metadata
        XCTAssertEqual(second.widthPercent, 200)
        XCTAssertEqual(second.backgroundBlurPercent, 200)
        XCTAssertEqual(second.backgroundMaskPercent, 0)
        XCTAssertEqual(second.brandStyle, .logo)

        var settings = PhotoEffectsSettings()
        var fields = settings.metadata
        fields.widthPercent = 63
        fields.backgroundBlurPercent = -1
        fields.backgroundMaskPercent = 201
        fields.showAddress = true
        settings.metadataByPreset[settings.photoFramePreset.rawValue] = fields
        let store = PhotoEffectsStore(defaults: defaults)
        store.update(settings)
        XCTAssertEqual(store.settings.metadata.widthPercent, 65)
        XCTAssertEqual(store.settings.metadata.backgroundBlurPercent, 0)
        XCTAssertEqual(store.settings.metadata.backgroundMaskPercent, 200)
        XCTAssertFalse(store.settings.metadata.showAddress)
        XCTAssertEqual(PhotoEffectsStore(defaults: defaults).settings.metadata, store.settings.metadata)
    }

}

final class PhotoFrameMetadataOutputIdentityTests: XCTestCase {
    func testVisibleMetadataChangesNamesAndHiddenControlsDoNot() {
        func name(_ preset: PhotoFramePreset = .mist, _ edit: (inout PhotoFrameMetadataSettings) -> Void) -> String {
            var settings = PhotoEffectsSettings()
            settings.photoFrameEnabled = true
            settings.photoFramePreset = preset
            settings.metadata = .defaults(for: preset)
            edit(&settings.metadata)
            settings.metadataByPreset[preset.rawValue] = settings.metadata
            return androidPhotoFrameOutputName(sourceName: "camera.jpg", settings: settings)
        }
        XCTAssertNotEqual(name { $0.widthPercent = 60 }, name { $0.widthPercent = 200 })
        XCTAssertNotEqual(name { $0.backgroundBlurPercent = 30 }, name { $0.backgroundBlurPercent = 70 })
        XCTAssertNotEqual(name { $0.backgroundMaskPercent = 30 }, name { $0.backgroundMaskPercent = 70 })
        XCTAssertNotEqual(name { $0.showCity = true }, name { $0.showRegion = true })
        XCTAssertNotEqual(name { $0.brandStyle = .text }, name { $0.brandStyle = .logo })
        XCTAssertEqual(name(.immersive) { $0.widthPercent = 60 }, name(.immersive) { $0.widthPercent = 200 })
        XCTAssertEqual(name(.plaque) { $0.backgroundBlurPercent = 0 }, name(.plaque) { $0.backgroundBlurPercent = 200 })
        XCTAssertEqual(name { $0.backgroundBlurPercent = 73 }, name { $0.backgroundBlurPercent = 70 })
        XCTAssertEqual(name { $0.showDate = false; $0.datePattern = "yyyy/MM/dd" }, name { $0.showDate = false; $0.datePattern = "yyyy.MM.dd" })
    }

    func testBackdropNormalizationMatchesAndroidTenPointSteps() {
        XCTAssertEqual(normalizePhotoFrameBackdropPercent(73), 70)
        XCTAssertEqual(normalizePhotoFrameBackdropPercent(75), 80)
        XCTAssertEqual(normalizePhotoFrameBackdropPercent(Int.min), 0)
        XCTAssertEqual(normalizePhotoFrameBackdropPercent(Int.max), 200)
    }
    func testDefaultFrameNamesIncludeAndroidLayoutVersions() {
        // SHA-256 first 6 bytes of Android's NUL-delimited identity strings:
        // off + measured-layout-v=6; plus glass-panel-v=2 for frosted;
        // editorial-v=2 + archive-layout-v=2 + off + measured-layout-v=6 for archive.
        let cases: [(PhotoFramePreset, String)] = [
            (.mist, "camera_frame_mist_wc08a79143377.jpg"),
            (.frosted, "camera_frame_glass_w4625101222a8.jpg"),
            (.colorArchive, "camera_frame_color_archive_w1582c5b3ee17.jpg")
        ]
        for (preset, expected) in cases {
            var settings = PhotoEffectsSettings()
            settings.photoFrameEnabled = true
            settings.watermark.enabled = false
            settings.photoFramePreset = preset
            settings.metadata = .defaults(for: preset)
            XCTAssertEqual(androidPhotoFrameOutputName(sourceName: "camera.jpg", settings: settings), expected)
        }
    }

    func testImageIdentityIgnoresHiddenTextAndNormalizesHashCase() {
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true
        settings.watermark.content = .image
        settings.watermark.imageHash = String(repeating: "a1", count: 32)
        func name(_ value: PhotoEffectsSettings) -> String {
            androidPhotoFrameOutputName(sourceName: "camera.jpg", settings: value)
        }
        let baseline = name(settings)
        settings.watermark.imageHash = settings.watermark.imageHash?.uppercased()
        settings.watermark.text = "Hidden"
        settings.watermark.font = .bold
        settings.watermark.color = .gold
        settings.watermark.effect = .outline
        XCTAssertEqual(name(settings), baseline)
        settings.watermark.imageHash = String(repeating: "b2", count: 32)
        XCTAssertNotEqual(name(settings), baseline)
        settings.watermark.imageHash = nil
        let invalid = name(settings)
        settings.watermark.imageHash = String(repeating: "a", count: 64) + "\n"
        XCTAssertEqual(name(settings), invalid)
    }

    func testDiskLookupRejectsOldVersionAndFindsCurrentCollisionCopy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let frames = directory.appendingPathComponent("ZTFrames")
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("camera.jpg")
        let old = frames.appendingPathComponent("camera_frame_mist_w5188c3de1416.jpg")
        let bytes = Data("old published output".utf8)
        try bytes.write(to: old)
        var settings = PhotoEffectsSettings(); settings.photoFrameEnabled = true
        XCTAssertNil(TransferQueue.existingFrameURL(source: source, settings: settings, in: directory))
        let currentName = androidPhotoFrameOutputName(sourceName: source.lastPathComponent, settings: settings)
        let current = frames.appendingPathComponent(String(currentName.dropLast(4)) + " (1).jpg")
        try Data("current published output".utf8).write(to: current)
        XCTAssertEqual(TransferQueue.existingFrameURL(source: source, settings: settings, in: directory), current)
        XCTAssertEqual(try Data(contentsOf: old), bytes)
    }

    func testTemplateControlAvailabilityMatchesAndroid() {
        let backdrop: Set<PhotoFramePreset> = [.mist, .frosted, .cinema, .filmGallery, .parameterPoster]
        for preset in PhotoFramePreset.allCases {
            XCTAssertEqual(preset.supportsBackdropControls, backdrop.contains(preset))
            XCTAssertEqual(preset.supportsWidthControl, preset != .immersive)
        }
    }

}

final class PhotoFrameBrandControlTests: XCTestCase {
    func testEveryPresetCyclesOffTextLogoOffWithoutChangingOtherFields() {
        for preset in PhotoFramePreset.allCases {
            for remembered in PhotoFrameBrandStyle.allCases {
                var value = PhotoFrameMetadataSettings.defaults(for: preset)
                value.showBrand = false; value.brandStyle = remembered
                value.showCity = true; value.widthPercent = 135
                var expected = value
                XCTAssertEqual(value.brandControlLabelKey, "photo_frame_metadata_brand")
                value.cycleBrandStyle()
                expected.showBrand = true; expected.brandStyle = .text
                XCTAssertEqual(value, expected)
                XCTAssertEqual(value.brandControlLabelKey, "photo_frame_metadata_brand_text")
                value.cycleBrandStyle(); expected.brandStyle = .logo
                XCTAssertEqual(value, expected)
                XCTAssertEqual(value.brandControlLabelKey, "photo_frame_metadata_brand_logo")
                value.cycleBrandStyle(); expected.showBrand = false; expected.brandStyle = .text
                XCTAssertEqual(value, expected)
                XCTAssertEqual(value.brandControlLabelKey, "photo_frame_metadata_brand")
            }
        }
    }
}


extension PhotoFramePlaceResolverTests {
    func testSameCoordinateQueriesAndCachesEachLanguageIndependently() async throws {
        let backend = SuspendedPlaceBackend()
        let resolver = PhotoFramePlaceResolver { latitude, _, _ in await backend.query(latitude) }
        let english = Task { await resolver.resolve(latitude: 30, longitude: 120, locale: Locale(identifier: "en_US")) }
        try await backend.waitForCalls(1)
        await backend.release(30, city: "Hangzhou")
        let englishResult = await english.value
        XCTAssertEqual(englishResult?.city, "Hangzhou")
        let chinese = Task { await resolver.resolve(latitude: 30, longitude: 120, locale: Locale(identifier: "zh_CN")) }
        try await backend.waitForCalls(2)
        await backend.release(30, city: "杭州市")
        let chineseResult = await chinese.value
        XCTAssertEqual(chineseResult?.city, "杭州市")
        let cachedEnglish = await resolver.resolve(latitude: 30, longitude: 120, timeout: .zero, locale: Locale(identifier: "en_US"))
        let cachedChinese = await resolver.resolve(latitude: 30, longitude: 120, timeout: .zero, locale: Locale(identifier: "zh_CN"))
        XCTAssertEqual(cachedEnglish, englishResult)
        XCTAssertEqual(cachedChinese, chineseResult)
        let calls = await backend.calls
        XCTAssertEqual(calls.count, 2)
    }
}


extension PhotoFramePlaceAvailabilityTests {
    @MainActor
    func testPublishedAvailabilityInvalidatesConsumersOnlyWhenEffectiveAccessChanges() {
        let state = PhotoFramePlaceAvailability()
        var observed: [Bool] = []
        let observation = state.$allowed.sink { observed.append($0) }
        state.updateConnection(wirelessMode: .sta, isUSB: false)
        state.updatePath(true)
        state.updatePath(true)
        state.updateConnection(wirelessMode: .sta, isUSB: false)
        state.updateConnection(wirelessMode: .ap, isUSB: false)
        state.updatePath(false)
        state.updatePath(true) // AP continues to block despite a valid route
        state.updateConnection(wirelessMode: .ap, isUSB: true)
        state.stop()
        state.stop()
        XCTAssertEqual(observed, [false, true, false, true, false])
        withExtendedLifetime(observation) {}
    }
}
