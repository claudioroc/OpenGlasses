import Foundation
import CoreLocation
import MapKit

/// The region-monitoring surface a geofence tool needs (BK P1). Abstracting it lets `GeofenceTool`
/// route through the app's single `CLLocationManager`/delegate (`LocationService`) in production,
/// and lets tests inject a fake so entering/exiting a region, the authorization state, and the
/// 20-region cap are all drivable headlessly (no `CLLocationManager` on GPU / no permission prompt).
@MainActor
protocol RegionMonitoring: AnyObject {
    var regionAuthorizationStatus: CLAuthorizationStatus { get }
    var monitoredRegionCount: Int { get }
    func regionMonitoringAvailable() -> Bool
    func requestAlwaysAuthorization()
    func startMonitoringRegion(_ region: CLCircularRegion)
    func stopMonitoringRegion(_ region: CLCircularRegion)
    /// Fired on a region enter (`didEnter == true`) / exit (`false`).
    var onRegionEvent: ((CLRegion, _ didEnter: Bool) -> Void)? { get set }
    /// Fired when authorization becomes `authorizedAlways` — the moment deferred geofences can arm.
    var onBecameAuthorizedAlways: (() -> Void)? { get set }
}

/// Provides the user's current location for LLM context
@MainActor
class LocationService: NSObject, ObservableObject {
    @Published var currentLocation: CLLocation?
    /// Human-readable place for the current location (reverse geocoded).
    @Published var geocodedPlace: String?
    /// Closest Apple Maps points of interest (shop/cafe/station names).
    @Published var nearbyPlaces: String?
    @Published var locationError: String?
    @Published var isAuthorized: Bool = false

    private let locationManager = CLLocationManager()

    /// Region-monitoring event forwarders (BK P1). Set by `GeofenceTool.activate()`.
    var onRegionEvent: ((CLRegion, Bool) -> Void)?
    var onBecameAuthorizedAlways: (() -> Void)?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 100  // Update every 100m
    }

    /// Request location permissions and start updates
    func startTracking() {
        let status = locationManager.authorizationStatus
        switch status {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            isAuthorized = true
            locationManager.startUpdatingLocation()
        case .denied, .restricted:
            isAuthorized = false
            locationError = "Location access denied"
        @unknown default:
            break
        }
    }

    /// Returns a human-readable location string for LLM context
    var locationContext: String? {
        var parts: [String] = []
        if let geocodedPlace, !geocodedPlace.isEmpty {
            parts.append(geocodedPlace)
        } else if let location = currentLocation {
            parts.append(String(format: "%.4f, %.4f", location.coordinate.latitude, location.coordinate.longitude))
        }
        if parts.isEmpty { return nil }
        if let nearbyPlaces, !nearbyPlaces.isEmpty {
            parts.append("Nearby: \(nearbyPlaces)")
        }
        return parts.joined(separator: ". ")
    }

    /// Reverse geocode the current location to a human-readable place. A small on-device model
    /// can't map raw coordinates to a city, so the USER LOCATION prompt line needs a place name;
    /// coordinates remain the fallback while geocoding is pending or offline.
    private func reverseGeocode(_ location: CLLocation) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let place = await GeocodingHelper.reverseGeocode(location) {
                self.geocodedPlace = place.cityState ?? place.fullAddress
            }
            if let nearby = await Self.nearbyMapNames(around: location) {
                self.nearbyPlaces = nearby
            }
            print("📍 Location: \(self.locationContext ?? "unknown")")
        }
    }

    /// Closest named places from Apple Maps, already formatted for the Describe prompt.
    static func nearbyMapNames(around location: CLLocation, radius: CLLocationDistance = 150) async -> String? {
        let request = MKLocalPointsOfInterestRequest(center: location.coordinate, radius: radius)
        do {
            let search = MKLocalSearch(request: request)
            let response = try await search.start()
            var seen = Set<String>()
            var names: [String] = []
            for item in response.mapItems.prefix(6) {
                guard let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                    continue
                }
                let key = name.lowercased()
                if seen.contains(key) { continue }
                seen.insert(key)
                if let itemLocation = item.location {
                    names.append("\(name) \(Int(location.distance(from: itemLocation)))m")
                } else {
                    names.append(name)
                }
            }
            return names.isEmpty ? nil : names.joined(separator: ", ")
        } catch {
            return nil
        }
    }
}

// MARK: - RegionMonitoring (BK P1)

extension LocationService: RegionMonitoring {
    var regionAuthorizationStatus: CLAuthorizationStatus { locationManager.authorizationStatus }
    var monitoredRegionCount: Int { locationManager.monitoredRegions.count }
    func regionMonitoringAvailable() -> Bool {
        CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self)
    }
    func requestAlwaysAuthorization() { locationManager.requestAlwaysAuthorization() }
    func startMonitoringRegion(_ region: CLCircularRegion) { locationManager.startMonitoring(for: region) }
    func stopMonitoringRegion(_ region: CLCircularRegion) { locationManager.stopMonitoring(for: region) }
}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.currentLocation = location
            self.reverseGeocode(location)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let status = manager.authorizationStatus
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                self.isAuthorized = true
                manager.startUpdatingLocation()
                print("📍 Location authorized")
                // BK P1: geofences deferred while permission was pending can arm now.
                if status == .authorizedAlways { self.onBecameAuthorizedAlways?() }
            case .denied, .restricted:
                self.isAuthorized = false
                self.locationError = "Location access denied"
                print("📍 Location denied")
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            print("📍 Location error: \(error.localizedDescription)")
            self.locationError = error.localizedDescription
        }
    }

    // MARK: Region monitoring (BK P1) — the callbacks that were missing, so a geofence can fire.

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        Task { @MainActor in self.onRegionEvent?(region, true) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        Task { @MainActor in self.onRegionEvent?(region, false) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        Task { @MainActor in
            print("📍 Region monitoring failed for \(region?.identifier ?? "?"): \(error.localizedDescription)")
            self.locationError = "Region monitoring failed: \(error.localizedDescription)"
        }
    }
}
