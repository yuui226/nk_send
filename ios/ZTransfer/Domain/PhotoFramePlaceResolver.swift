import CoreLocation
import Foundation

actor PhotoFramePlaceResolver {
    private var cache: [String: PhotoFramePlace?] = [:]
    private var geocoder: CLGeocoder?

    func resolve(latitude: Double, longitude: Double, timeout: Duration = .seconds(1)) async -> PhotoFramePlace? {
        guard validPhotoFrameCoordinates(latitude, longitude) else { return nil }
        let key = String(format: "%.4f,%.4f", latitude, longitude)
        if let cached = cache[key] { return cached }
        let worker = Task { () -> PhotoFramePlace? in
            let coder = CLGeocoder()
            do {
                let marks = try await coder.reverseGeocodeLocation(CLLocation(latitude: latitude, longitude: longitude))
                guard let mark = marks.first else { return nil }
                return photoFramePlace(city: mark.locality, district: mark.subLocality, subAdmin: mark.subAdministrativeArea, admin: mark.administrativeArea, countryCode: mark.isoCountryCode)
            } catch { return nil }
        }
        let result = await withTaskGroup(of: PhotoFramePlace?.self) { group -> PhotoFramePlace? in
            group.addTask { await worker.value }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let first = await group.next() ?? nil; group.cancelAll(); return first
        }
        cache[key] = result
        return result
    }

    func enriching(_ metadata: PhotoFrameMetadata, timeout: Duration = .seconds(1)) async -> PhotoFrameMetadata {
        guard let latitude = metadata.latitude, let longitude = metadata.longitude,
              let place = await resolve(latitude: latitude, longitude: longitude, timeout: timeout) else { return metadata }
        return PhotoFrameMetadata(make: metadata.make, model: metadata.model, lensModel: metadata.lensModel,
                                  focalLength: metadata.focalLength, aperture: metadata.aperture, shutter: metadata.shutter,
                                  iso: metadata.iso, exposureCompensation: metadata.exposureCompensation, dateTime: metadata.dateTime,
                                  latitude: metadata.latitude, longitude: metadata.longitude, altitude: metadata.altitude,
                                  city: place.city, region: place.region)
    }
}
