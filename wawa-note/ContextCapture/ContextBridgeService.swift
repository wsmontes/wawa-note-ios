import Foundation
import SwiftData
import WawaNoteCore

// MARK: - Context Bridge Service

/// Bridges `CapturedAnnotation` results from `ContextCaptureService`
/// into the typed context columns on `KnowledgeItem`.
///
/// This closes the gap between context capture (sensors → annotations)
/// and typed storage (KnowledgeItem.context* fields).
@MainActor
enum ContextBridgeService {
  /// Maps a list of `CapturedAnnotation` to a `KnowledgeItem`'s typed context columns.
  /// - Parameters:
  ///   - annotations: Raw sensor output from `ContextCaptureService.captureAll()`
  ///   - itemID: The knowledge item to enrich
  ///   - context: SwiftData ModelContext for persistence
  static func applyAnnotations(
    _ annotations: [CapturedAnnotation],
    to itemID: UUID,
    context modelContext: ModelContext
  ) {
    guard !annotations.isEmpty else { return }

    let descriptor = FetchDescriptor<KnowledgeItem>(
      predicate: #Predicate { $0.id == itemID }
    )
    guard let item = try? modelContext.fetch(descriptor).first else {
      AppLog.warn("context", "ContextBridge: item \(itemID) not found")
      return
    }

    var changed = 0

    for ann in annotations {
      switch (ann.source, ann.key) {
      // ── Location ──────────────────────────────────────────
      case ("location_context", "lat"):
        if let v = Double(ann.value) {
          item.contextLatitude = v
          changed += 1
        }
      case ("location_context", "lon"):
        if let v = Double(ann.value) {
          item.contextLongitude = v
          changed += 1
        }
      case ("location_context", "place_name"):
        item.contextPlaceName = ann.value
        changed += 1
      case ("location_context", "city"):
        if item.contextPlaceName == nil {
          item.contextPlaceName = ann.value
          changed += 1
        }

      // ── Audio Route ───────────────────────────────────────
      case ("audio_route", "route_type"):
        item.contextAudioRoute = ann.value
        changed += 1
      case ("audio_route", "route_name"):
        // Append port name to existing route type if present
        let existing = item.contextAudioRoute ?? ""
        item.contextAudioRoute = existing.isEmpty ? ann.value : "\(existing) (\(ann.value))"
        changed += 1

      // ── Focus Mode ────────────────────────────────────────
      case ("focus_mode", "focus_active"):
        item.contextFocusActive = (ann.value as NSString).boolValue
        changed += 1

      // ── Motion Activity ───────────────────────────────────
      case ("motion_activity", "activity"):
        item.contextMotionActivity = ann.value
        changed += 1

      // ── Battery ───────────────────────────────────────────
      case ("battery", "level"):
        if let v = Double(ann.value) {
          item.contextBatteryLevel = v / 100.0
          changed += 1
        }

      // ── Calendar ──────────────────────────────────────────
      case ("calendar_context", "event_title"):
        item.contextCalendarEventTitle = ann.value
        changed += 1

      default:
        break
      }
    }

    if changed > 0 {
      modelContext.safeSave(context: "context-bridge-apply", itemId: itemID)
      AppLog.event(
        "context",
        "ContextBridge: applied \(changed) field(s) to item \(itemID.uuidString.prefix(8))")
    }
  }
}
