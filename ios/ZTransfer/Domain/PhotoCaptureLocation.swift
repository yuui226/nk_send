import Foundation

/// Android PhotoCaptureLocation: an immutable snapshot belonging to the same
/// original photo. This value never reads the phone's location service.
struct PhotoCaptureLocation: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let altitude: Double?

    init?(latitude: Double?, longitude: Double?, altitude: Double?) {
        guard let latitude, let longitude, latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude),
              latitude != 0 || longitude != 0 else { return nil }
        self.latitude = latitude; self.longitude = longitude
        self.altitude = altitude.flatMap { $0.isFinite ? $0 : nil }
    }

}
