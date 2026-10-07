import Foundation

@MainActor
final class RemoteLUTPreferences {
    private let defaults: UserDefaults
    private let folderKey = "remote_lut_folder"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var folder: String? { defaults.string(forKey: folderKey) }
    func setFolder(_ value: String?) { defaults.set(value, forKey: folderKey) }
    func selection(movie: Bool) -> String? { defaults.string(forKey: movie ? "remote_lut_movie" : "remote_lut_photo") }
    func setSelection(_ value: String?, movie: Bool) {
        defaults.set(value, forKey: movie ? "remote_lut_movie" : "remote_lut_photo")
    }
    func toggleSelection(_ value: String, movie: Bool) {
        setSelection(selection(movie: movie) == value ? nil : value, movie: movie)
    }
}
