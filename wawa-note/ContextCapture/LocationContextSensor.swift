import CoreLocation
import Foundation
import OSLog

// Related JIRA: KAN-544

final class LocationContextSensor: ContextSensor, @unchecked Sendable {
  let sensorName = "location_context"

  private let manager = CLLocationManager()
  private static let timeoutSeconds: TimeInterval = 10

  /// Retains the delegate across the async continuation boundary.
  /// CLLocationManager holds its delegate via a weak reference,
  /// so the only strong reference must live at least until the
  /// location callback fires or the timeout expires.
  private var activeDelegate: LocationDelegate?

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
      AppLog.general.warning(
        "LocationContextSensor: unknown authorization status (\(status.rawValue))")
      return []
    }

    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters

    return try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<[CapturedAnnotation], Error>) in
      let delegate = LocationDelegate()
      self.activeDelegate = delegate  // keep strong reference
      manager.delegate = delegate

      let state = LocationCaptureState(continuation: continuation)

      // Timeout
      let timeoutWork = DispatchWorkItem {
        state.finish(location: nil, placemark: nil, error: nil)
      }
      DispatchQueue.global().asyncAfter(
        deadline: .now() + Self.timeoutSeconds, execute: timeoutWork)

      delegate.onResult = { location, placemark, error in
        state.finish(location: location, placemark: placemark, error: error)
      }

      manager.requestLocation()
    }
  }
}

private final class LocationCaptureState: @unchecked Sendable {
  private let lock = OSAllocatedUnfairLock()
  private let continuation: CheckedContinuation<[CapturedAnnotation], Error>
  private var didFinish = false

  init(continuation: CheckedContinuation<[CapturedAnnotation], Error>) {
    self.continuation = continuation
  }

  func finish(location: CLLocation?, placemark: CLPlacemark?, error: Error?) {
    lock.lock()
    guard !didFinish else {
      lock.unlock()
      return
    }
    didFinish = true
    lock.unlock()

    if let error {
      AppLog.general.warning("LocationContextSensor: \(error.localizedDescription)")
      continuation.resume(returning: [])
      return
    }

    var annotations: [CapturedAnnotation] = []
    if let location {
      annotations.append(
        CapturedAnnotation(
          source: "location_context", key: "lat", value: String(location.coordinate.latitude)))
      annotations.append(
        CapturedAnnotation(
          source: "location_context", key: "lon", value: String(location.coordinate.longitude)))
      if location.horizontalAccuracy >= 0 {
        annotations.append(
          CapturedAnnotation(
            source: "location_context", key: "accuracy",
            value: String(format: "%.0f", location.horizontalAccuracy)))
      }
    }
    if let placemark {
      if let name = placemark.name {
        annotations.append(
          CapturedAnnotation(source: "location_context", key: "place_name", value: name))
      }
      if let locality = placemark.locality {
        annotations.append(
          CapturedAnnotation(source: "location_context", key: "city", value: locality))
      }
      if let country = placemark.country {
        annotations.append(
          CapturedAnnotation(source: "location_context", key: "country", value: country))
      }
    }
    continuation.resume(returning: annotations)
  }
}

private final class GeocodeResultState: @unchecked Sendable {
  let location: CLLocation
  let callback: @Sendable (CLLocation?, CLPlacemark?, Error?) -> Void

  init(
    location: CLLocation,
    callback: @escaping @Sendable (CLLocation?, CLPlacemark?, Error?) -> Void
  ) {
    self.location = location
    self.callback = callback
  }
}

private final class LocationDelegate: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
  var onResult: (@Sendable (CLLocation?, CLPlacemark?, Error?) -> Void)?

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let location = locations.first, let callback = onResult else { return }
    onResult = nil
    let geocoder = CLGeocoder()
    let state = GeocodeResultState(location: location, callback: callback)
    geocoder.reverseGeocodeLocation(location) { placemarks, error in
      state.callback(state.location, placemarks?.first, error)
    }
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    guard let callback = onResult else { return }
    onResult = nil
    callback(nil, nil, error)
  }
}
