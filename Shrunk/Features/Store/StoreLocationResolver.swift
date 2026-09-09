import CoreLocation
import Foundation
import MapKit

struct StoreSearchCoordinate: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
}

struct ResolvedStorePlace: Equatable, Sendable {
    let postalCode: String
    let coordinate: StoreSearchCoordinate
}

enum StoreLocationResolutionError: Error, Equatable {
    case denied
    case unavailable
    case placeNotFound
}

@MainActor
protocol StoreLocationResolving: AnyObject {
    func currentPlace() async throws -> ResolvedStorePlace
    func resolvePlace(named query: String) async throws -> ResolvedStorePlace
}

@MainActor
final class AppleStoreLocationResolver: NSObject, StoreLocationResolving, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func currentPlace() async throws -> ResolvedStorePlace {
        let location = try await requestLocation()
        let marks = try await CLGeocoder().reverseGeocodeLocation(location)
        guard let postalCode = marks.lazy.compactMap(\.postalCode).first else {
            throw StoreLocationResolutionError.placeNotFound
        }
        return ResolvedStorePlace(
            postalCode: postalCode,
            coordinate: StoreSearchCoordinate(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            )
        )
    }

    func resolvePlace(named query: String) async throws -> ResolvedStorePlace {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]
        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first(where: { $0.placemark.postalCode != nil }),
              let postalCode = item.placemark.postalCode else {
            throw StoreLocationResolutionError.placeNotFound
        }
        return ResolvedStorePlace(
            postalCode: postalCode,
            coordinate: StoreSearchCoordinate(
                latitude: item.placemark.coordinate.latitude,
                longitude: item.placemark.coordinate.longitude
            )
        )
    }

    private func requestLocation() async throws -> CLLocation {
        guard CLLocationManager.locationServicesEnabled() else {
            throw StoreLocationResolutionError.unavailable
        }
        switch manager.authorizationStatus {
        case .denied, .restricted:
            throw StoreLocationResolutionError.denied
        default:
            break
        }
        guard locationContinuation == nil else {
            throw StoreLocationResolutionError.unavailable
        }
        return try await withCheckedThrowingContinuation { continuation in
            locationContinuation = continuation
            if manager.authorizationStatus == .notDetermined {
                manager.requestWhenInUseAuthorization()
            } else {
                manager.requestLocation()
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard locationContinuation != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            finishLocation(with: .failure(StoreLocationResolutionError.denied))
        case .notDetermined:
            break
        @unknown default:
            finishLocation(with: .failure(StoreLocationResolutionError.unavailable))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            finishLocation(with: .failure(StoreLocationResolutionError.unavailable))
            return
        }
        finishLocation(with: .success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finishLocation(with: .failure(StoreLocationResolutionError.unavailable))
    }

    private func finishLocation(with result: Result<CLLocation, Error>) {
        guard let continuation = locationContinuation else { return }
        locationContinuation = nil
        continuation.resume(with: result)
    }
}
