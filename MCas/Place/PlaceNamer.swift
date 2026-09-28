import CoreLocation

/// "Trastevere, Rome": the neighborhood and the city, from one location fix.
/// Replaces BrightRecorder's Nominatim lookup; no network key, no server.
final class PlaceNamer: NSObject, CLLocationManagerDelegate {
    private let lm = CLLocationManager()
    private var waiting: [(String?) -> Void] = []
    private var busy = false

    override init() {
        super.init()
        lm.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func lookup(_ done: @escaping (String?) -> Void) {
        waiting.append(done)
        switch lm.authorizationStatus {
        case .notDetermined: lm.requestWhenInUseAuthorization()
        case .denied, .restricted: flush(nil)
        default: request()
        }
    }

    private func request() {
        guard !busy else { return }
        busy = true
        lm.requestLocation()
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        guard !waiting.isEmpty else { return }
        switch m.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: request()
        case .denied, .restricted: flush(nil)
        default: break
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard busy, let loc = locs.last else { return }
        busy = false
        CLGeocoder().reverseGeocodeLocation(loc) { [weak self] marks, _ in
            let p = marks?.first
            let near = p?.subLocality ?? p?.thoroughfare ?? p?.name
            let city = p?.locality ?? p?.administrativeArea
            var parts: [String] = []
            for s in [near, city].compactMap({ $0 }) where !parts.contains(s) { parts.append(s) }
            let name = parts.joined(separator: ", ")
            DispatchQueue.main.async { self?.flush(name.isEmpty ? nil : name) }
        }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        busy = false
        flush(nil)
    }

    private func flush(_ s: String?) {
        let w = waiting
        waiting = []
        w.forEach { $0(s) }
    }
}
