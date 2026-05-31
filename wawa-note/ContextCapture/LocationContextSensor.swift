import CoreLocation
import Foundation
import OSLog

final class LocationContextSensor: ContextSensor, @unchecked Sendable {
    let sensorName = "location_context"

    private let manager = CLLocationManager()
    private static let timeoutSeconds: TimeInterval = 10

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func capture() async throws -> [CapturedAnnotation] {
        let status = manager.authorizationStatus

        switch status {
        case .notDetermined:
            AppLog.general.info("LocationContextSensor: authorization not determined")
            return []
        case .denied, .restricted:
            AppLog.general.info("LocationContextSensor: not authorized (\(status.rawValue))")
            return []
        case .authorizedWhenInUse, .authorizedAlways:
            break
        @unknown default:
            AppLog.general.warning("LocationContextSensor: unknown authorization status (\(status.rawValue))")
            return []
        }

        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CapturedAnnotation], Error>) in
            let delegate = LocationDelegate()
            manager.delegate = delegate

            var resumed = false

            // Timeout
            let timeoutWork = DispatchWorkItem {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: [])
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeoutSeconds, execute: timeoutWork)

            delegate.onResult = { location, placemark, error in
                guard !resumed else { return }
                resumed = true
                timeoutWork.cancel()

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
        guard let callback = onResult else { return }
        onResult = nil
        callback(nil, nil, error)
    }
}
