import Foundation
import Combine

// Raw values are the Android preference format, shared by photo/movie modes.
// Layout order/visibility remains separate for the two modes.
enum RemoteHistogramMode: String, CaseIterable { case off = "OFF", rgb = "RGB", luma = "LUMA" }
enum RemoteExposureAssist: String, CaseIterable { case off = "OFF", zebra = "ZEBRA", falseColor = "FALSE_COLOR" }
enum RemoteWaveformMode: String, CaseIterable { case off = "OFF", luma = "LUMA", rgb = "RGB" }
enum RemoteDispMode: String, CaseIterable {
    case camera = "CAMERA", exposure = "EXPOSURE", clean = "CLEAN"
    var next: Self {
        switch self { case .camera: .exposure; case .exposure: .clean; case .clean: .camera }
    }
    var showsCameraInformation: Bool { self == .camera }
    var showsExposureInformation: Bool { self != .clean }
}
enum RemoteGridMode: String, CaseIterable {
    case off = "OFF", thirds = "THIRDS", fourths = "FOURTHS", center = "CENTER", golden = "GOLDEN"
    case thirdsDiagonals = "THIRDS_DIAGONALS", fourthsDiagonals = "FOURTHS_DIAGONALS"
    case wide235 = "WIDE_235", wide169 = "WIDE_169", frame43 = "FRAME_43"
}

/// RemoteToolPreferences.kt: writes occur on mutation, never deferred to page
/// disposal. Hiding an action does not reset the corresponding camera parameter.
@MainActor
final class RemoteToolPreferences: ObservableObject {
    private let defaults: UserDefaults
    @Published var fps: Bool { didSet { save(fps, oldValue, "remote_fps") } }
    @Published var hd: Bool { didSet { save(hd, oldValue, "remote_hd") } }
    @Published var audio: Bool { didSet { save(audio, oldValue, "remote_audio_levels_visible") } }
    @Published var level: Bool { didSet { save(level, oldValue, "remote_level") } }
    @Published var meter: Bool { didSet { save(meter, oldValue, "remote_exposure_meter") } }
    @Published var locked: Bool { didSet { save(locked, oldValue, "remote_layout_locked") } }
    @Published var lockedRotation: Int { didSet { save(lockedRotation, oldValue, "remote_locked_rotation") } }
    @Published var desqueeze: Double { didSet { save(desqueeze, oldValue, "remote_desqueeze_multiplier") } }
    @Published var histogram: RemoteHistogramMode { didSet { save(histogram.rawValue, oldValue.rawValue, "remote_histogram_mode") } }
    @Published var exposure: RemoteExposureAssist { didSet { save(exposure.rawValue, oldValue.rawValue, "remote_exposure_assist") } }
    @Published var waveform: RemoteWaveformMode { didSet { save(waveform.rawValue, oldValue.rawValue, "remote_waveform_mode") } }
    @Published var grid: RemoteGridMode { didSet { save(grid.rawValue, oldValue.rawValue, "remote_grid") } }
    @Published var disp: RemoteDispMode { didSet { save(disp.rawValue, oldValue.rawValue, "remote_disp_mode") } }

    private lazy var photoLayout = RemoteToolLayout(defaults: defaults, movie: false) { [weak self] in self?.disable($0) }
    private lazy var movieLayout = RemoteToolLayout(defaults: defaults, movie: true) { [weak self] in self?.disable($0) }
    func layout(movie: Bool) -> RemoteToolLayout { movie ? movieLayout : photoLayout }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ key: String, _ fallback: Bool = false) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        func value<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
            defaults.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
        }
        fps = bool("remote_fps", true)
        hd = bool("remote_hd")
        audio = bool("remote_audio_levels_visible", true)
        level = bool("remote_level")
        meter = bool("remote_exposure_meter")
        locked = bool("remote_layout_locked")
        lockedRotation = min(2, max(0, defaults.integer(forKey: "remote_locked_rotation")))
        desqueeze = RemoteDisplayOptions.normalizedDesqueeze(defaults.object(forKey: "remote_desqueeze_multiplier") == nil ? 1 : defaults.double(forKey: "remote_desqueeze_multiplier"))
        histogram = value("remote_histogram_mode", bool("remote_histogram") ? .luma : RemoteHistogramMode.off)
        exposure = value("remote_exposure_assist", RemoteExposureAssist.off)
        waveform = value("remote_waveform_mode", bool("remote_waveform") ? .luma : RemoteWaveformMode.off)
        grid = value("remote_grid", RemoteGridMode.off)
        disp = value("remote_disp_mode", RemoteDispMode.camera)
    }

    private func save<T: Equatable>(_ value: T, _ old: T, _ key: String) {
        if value != old { defaults.set(value, forKey: key) }
    }

    private func disable(_ tool: RemoteTool) {
        switch tool {
        case .hd: hd = false
        case .fps: fps = false
        case .audio: audio = false
        case .histogram: histogram = .off
        case .grid: grid = .off
        case .exposure: exposure = .off
        case .desqueeze: desqueeze = 1
        case .level: level = false
        case .meter: meter = false
        case .waveform: waveform = .off
        case .lock: locked = false
        case .record, .whiteBalance, .focusArea, .lut, .rotate: break
        }
    }
}
