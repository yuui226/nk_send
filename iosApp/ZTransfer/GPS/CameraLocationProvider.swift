import Foundation
import Combine
import CoreLocation
import UIKit
import ZTransferShared

/// Foreground location adapter. Does not authenticate BLE or claim coordinates reached the camera.
/// CoreLocation fuses providers; verticalAccuracy is the Apple validity signal, not a fake "GPS"
/// provider label. Always/reduced-accuracy escalation and background modes are not requested.
@MainActor
final class CameraLocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var running = false
    @Published private(set) var status = "定位尚未启用。"
    @Published private(set) var latest: CLLocation?
    @Published private(set) var reducedAccuracy = false
    private var manager: CLLocationManager?
    private var timer: Timer?
    private var pending = false
    private var interval: TimeInterval = 10
    private var backgroundObserver: AnyCancellable?

    override init() {
        super.init()
        backgroundObserver = NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.stop() } }
    }

    func start(frequencySeconds: Int64 = 60) {
        stop()
        guard UIApplication.shared.applicationState != .background else { return }
        latest = nil
        interval = Double(NativeGpsBridge.shared.samplingMillis(frequencySeconds: frequencySeconds)) / 1000
        let location = CLLocationManager()
        manager = location
        running = true
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.distanceFilter = kCLDistanceFilterNone
        location.allowsBackgroundLocationUpdates = false
        applyAuthorization(location)
    }

    func stop() {
        timer?.invalidate(); timer = nil
        manager?.stopUpdatingLocation(); manager?.delegate = nil; manager = nil
        running = false; pending = false; latest = nil
        status = "定位已停止；没有继续在后台获取位置。"
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { applyAuthorization(manager) }

    private func applyAuthorization(_ location: CLLocationManager) {
        guard manager === location, running else { return }
        reducedAccuracy = location.accuracyAuthorization == .reducedAccuracy
        switch location.authorizationStatus {
        case .notDetermined:
            status = "等待使用期间定位授权…"
            location.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            guard timer == nil else { return }
            status = "等待有效定位…"
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.requestFix() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
            requestFix()
        case .denied, .restricted:
            stop(); status = "定位权限不可用，请在系统设置中检查；尚未写入相机。"
        @unknown default:
            stop(); status = "系统返回未知定位授权状态。"
        }
    }

    private func requestFix() {
        guard running, !pending, let manager else { return }
        pending = true
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard self.manager === manager, running else { return }
        pending = false
        guard let fix = locations.filter({ Self.usable($0, now: Date()) }).max(by: { $0.timestamp < $1.timestamp }) else {
            status = "尚无两分钟内有效定位，继续等待。"; return
        }
        if latest == nil || fix.timestamp >= latest!.timestamp { latest = fix }
        reducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
        status = reducedAccuracy ? "已获得大概位置；未写入相机。" : "已获得位置；未写入相机。"
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard self.manager === manager, running else { return }
        pending = false
        if (error as? CLError)?.code == .denied { stop() }
        status = "定位暂不可用：\(error.localizedDescription)"
    }

    /// Current UTC goes into GEO, while the fix timestamp is used only to reject stale coordinates.
    /// Returns real shared-encoded bytes for the later BLE writer; no automatic network/BT write.
    func geoPayload(now: Date = Date()) -> Data? {
        guard running, let latest else { return nil }
        return Self.payload(for: latest, now: now)
    }

    nonisolated static func usable(_ location: CLLocation, now: Date) -> Bool {
        CLLocationCoordinate2DIsValid(location.coordinate) && location.horizontalAccuracy.isFinite &&
            location.horizontalAccuracy >= 0 && location.timestamp.timeIntervalSince1970 > 0 &&
            abs(now.timeIntervalSince(location.timestamp)) <= 120
    }

    nonisolated static func payload(for fix: CLLocation, now: Date) -> Data? {
        guard usable(fix, now: now) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let time = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        guard let year = time.year, (0...65535).contains(year), let month = time.month, let day = time.day,
              let hour = time.hour, let minute = time.minute, let second = time.second,
              let bytes = NativeGpsBridge.shared.encode(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
                altitude: fix.altitude, validAltitude: fix.verticalAccuracy.isFinite && fix.verticalAccuracy >= 0,
                year: Int32(year), month: Int32(month), day: Int32(day), hour: Int32(hour), minute: Int32(minute), second: Int32(second)) else { return nil }
        return Data((0..<Int(bytes.size)).map { UInt8(bitPattern: bytes.get(index: Int32($0))) })
    }
}
