import CoreLocation
import MapKit

struct PlaceFix {
    var name: String
    var coordinate: CLLocationCoordinate2D?
}

/// Names you've given places ("Home", "Alex's") and where they are. A clip recorded within
/// 60 m of one takes its name.
enum PlaceBook {
    struct Entry: Codable { var name: String; var lat: Double; var lon: Double }
    private static let key = "placeBook"
    static let radius: CLLocationDistance = 60

    static var entries: [Entry] {
        get { (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    static func name(near c: CLLocationCoordinate2D) -> String? {
        let here = CLLocation(latitude: c.latitude, longitude: c.longitude)
        return entries
            .map { ($0, CLLocation(latitude: $0.lat, longitude: $0.lon).distance(from: here)) }
            .filter { $0.1 <= radius }
            .min { $0.1 < $1.1 }?.0.name
    }

    /// Remember a name for a spot; replaces any name already within the radius.
    static func remember(_ name: String, at c: CLLocationCoordinate2D) {
        let here = CLLocation(latitude: c.latitude, longitude: c.longitude)
        var list = entries.filter { CLLocation(latitude: $0.lat, longitude: $0.lon).distance(from: here) > radius }
        list.append(Entry(name: name, lat: c.latitude, lon: c.longitude))
        entries = list
    }
}

/// Where you are, as specifically as it can tell: a place you've named, else the bar or
/// restaurant or park you're in (Apple Maps points of interest within ~45 m), else the
/// neighborhood and city. Replaces BrightRecorder's Nominatim lookup.
final class PlaceNamer: NSObject, CLLocationManagerDelegate {
    private let lm = CLLocationManager()
    private var waiting: [(PlaceFix?) -> Void] = []
    private var busy = false

    override init() {
        super.init()
        lm.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    func lookup(_ done: @escaping (PlaceFix?) -> Void) {
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
        let c = loc.coordinate
        if let named = PlaceBook.name(near: c) { flush(PlaceFix(name: named, coordinate: c)); return }
        Self.neighborhood(loc) { hood in
            Self.pointOfInterest(loc) { poi in
                let parts = [poi, hood].compactMap { $0 }.filter { !$0.isEmpty }
                var unique: [String] = []
                for p in parts where !unique.contains(p) { unique.append(p) }
                DispatchQueue.main.async { self.flush(unique.isEmpty ? PlaceFix(name: Naming.fallbackPlace, coordinate: c) : PlaceFix(name: unique.joined(separator: ", "), coordinate: c)) }
            }
        }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        busy = false
        flush(nil)
    }

    private func flush(_ s: PlaceFix?) {
        let w = waiting
        waiting = []
        w.forEach { $0(s) }
    }

    /// "Lower East Side" or "Trastevere, Rome" when there's no named place.
    static func neighborhood(_ loc: CLLocation, _ done: @escaping (String?) -> Void) {
        CLGeocoder().reverseGeocodeLocation(loc) { marks, _ in
            let p = marks?.first
            let near = p?.subLocality ?? p?.thoroughfare
            let city = p?.locality ?? p?.administrativeArea
            done([near, city].compactMap { $0 }.first(where: { !$0.isEmpty }).map { n in
                if let city, city != n, near != nil, p?.subLocality == nil { return "\(n), \(city)" }
                return near == nil ? n : (p?.subLocality != nil ? n : "\(n), \(city ?? "")")
            })
        }
    }

    /// The nearest point of interest you're plausibly inside: bars, restaurants, cafés,
    /// parks, venues, shops — anything Apple Maps knows within 45 m, closest first.
    static func pointOfInterest(_ loc: CLLocation, _ done: @escaping (String?) -> Void) {
        let req = MKLocalPointsOfInterestRequest(center: loc.coordinate, radius: 80)
        MKLocalSearch(request: req).start { resp, _ in
            let best = resp?.mapItems
                .compactMap { item -> (String, CLLocationDistance)? in
                    guard let name = item.name, let l = item.placemark.location else { return nil }
                    return (name, l.distance(from: loc))
                }
                .filter { $0.1 <= max(45, loc.horizontalAccuracy) }
                .min { $0.1 < $1.1 }
            done(best?.0)
        }
    }
}
