import XCTest
import CoreLocation
@testable import OpenGlasses

/// Tests for the location string injected into LLM prompts as "USER LOCATION: ...".
/// Uses fresh instances with properties set directly — no CLLocationManager fix or
/// network geocoding is exercised, so these run headlessly.
@MainActor
final class LocationServiceTests: XCTestCase {

    func testLocationContextNilWithoutFix() {
        let service = LocationService()
        XCTAssertNil(service.locationContext)
    }

    func testLocationContextFallsBackToCoordinates() {
        let service = LocationService()
        service.currentLocation = CLLocation(latitude: -36.8485, longitude: 174.7633)
        XCTAssertEqual(service.locationContext, "-36.8485, 174.7633")
    }

    func testLocationContextPrefersGeocodedPlace() {
        let service = LocationService()
        service.currentLocation = CLLocation(latitude: -36.8485, longitude: 174.7633)
        service.geocodedPlace = "Auckland, New Zealand"
        XCTAssertEqual(service.locationContext, "Auckland, New Zealand")
    }

    func testLocationContextAppendsNearbyMapPlaces() {
        let service = LocationService()
        service.geocodedPlace = "Westbourne Gardens, W2"
        service.nearbyPlaces = "Tesco Express 20m, Royal Oak 40m"
        XCTAssertEqual(
            service.locationContext,
            "Westbourne Gardens, W2. Nearby: Tesco Express 20m, Royal Oak 40m"
        )
    }
}
