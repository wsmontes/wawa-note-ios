import CoreLocation
import Foundation
import OSLog

final class LocationContextSensor: ContextSensor, @unchecked Sendable {
    let sensorName = "location_context"

    func capture() async throws -> [CapturedAnnotation] {
        let manager = CLLocationManager()

        // Check authorization
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            AppLog.general.info("LocationContextSensor: not authorized (\(status.rawValue))")
            return []
        }

        let delegate = LocationDelegate()
        return await withCheckedContinuation { (continuation: CheckedContinuation<[CapturedAnnotation], Never>) in
            delegate.onResult = { [weak delegate] location, placemark, error in
                _ = delegate // retain
                if let error {
                    AppLog.general.warning("LocationContextSensor: \(error.localizedDescription)")
                    continuation.resume(returning: [])
                    return
                }
                var annotations: [CapturedAnnotation] = []
                if let location {
                    annotations.append(CapturedAnnotation(source: "location_context", key: "lat", value: String(location.coordinate.latitude)))
                    annotations.append(CapturedAnnotation(source: "location_context", key: "lon", value: String(location.coordinate.longitude)))
                    if location.horizontalAccuracy >= 0 {
                        annotations.append(CapturedAnnotation(source: "location_context", key: "accuracy", value: String(format: "%.0f", location.horizontalAccuracy)))
                    }
                }
                if let placemark {
                    if let name = placemark.name { annotations.append(CapturedAnnotation(source: "location_context", key: "place_name", value: name)) }
                    if let locality = placemark.locality { annotations.append(CapturedAnnotation(source: "location_context", key: "city", value: locality)) }
                    if let country = placemark.country { annotations.append(CapturedAnnotation(source: "location_context", key: "country", value: country)) }
                }
                continuation.resume(returning: annotations)
            }
            manager.delegate = delegate
            manager.requestLocation()
        }
    }
}

private final class LocationDelegate: NSObject, CLLocationManagerDelegate {
    var onResult: ((CLLocation?, CLPlacemark?, Error?) -> Void)?

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.first, let callback = onResult else { return }
        onResult = nil
        let geocoder = CLGeocoder()
        geocoder.reverseGeocodeLocation(location) { placemarks, error in
            callback(location, placemarks?.first, error)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        onResult?(nil, nil, error)
        onResult = nil
    }
}
