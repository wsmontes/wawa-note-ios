# Context Detail View Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign `contextSection` in `KnowledgeDetailView` from tiny gray debug capsules into polished material-card groups (Place, Event, Device) with Copy interaction.

**Architecture:** Replace `contextBadge` helper with 3 group card views inline in the existing `contextSection`. Each group renders conditionally. ContextMenu on each card for Copy. Remove duplicate context entries from the `badges` array.

**Tech Stack:** SwiftUI, SF Symbols, `.regularMaterial`, `.contextMenu`, `UIPasteboard`

## Global Constraints

- Target iOS 17+, iPhone 14 Plus physical device
- No new files — all changes in `KnowledgeDetailView.swift`
- No external navigation (Maps, Calendar, Contacts)
- No internal filtering/querying by context
- Context section must remain invisible when `hasContextFields` is false
- Respect existing code patterns: `@MainActor`, `@Environment`, `private var` computed views

---

### Task 1: Remove duplicate context badges and old contextBadge helper

**Files:**
- Modify: `UI/Knowledge/KnowledgeDetailView.swift:724-759` (contextSection, contextBadge, hasContextFields)
- Modify: `UI/Knowledge/KnowledgeDetailView.swift:844-845` (duplicate badges)

**Produce:** Clean foundation — no old context code in the way

- [ ] **Step 1: Remove old `contextSection`, `contextBadge` helper, and `hasContextFields`**

Replace the entire block from `hasContextFields` through `contextBadge` (lines 724-759) with empty stubs:

```swift
  private var hasContextFields: Bool {
    item.contextPlaceName != nil || item.contextAudioRoute != nil || item.contextLatitude != nil
      || item.contextFocusActive != nil || item.contextMotionActivity != nil
      || item.contextBatteryLevel != nil || item.contextCalendarEventTitle != nil
  }

  private var contextSection: some View {
    EmptyView()  // Placeholder — replaced in Task 2
  }
```

- [ ] **Step 2: Remove duplicate context badges from `badges` array**

Remove lines 844-845:
```swift
    // REMOVE these two lines:
    if let cal = item.contextCalendarEventTitle { b.append((cal, "calendar", .neutral)) }
    if let route = item.contextAudioRoute { b.append((route, "airpodspro", .neutral)) }
```

- [ ] **Step 3: Build and verify no compile errors**

```bash
make deploy DEVICE=14plus
```

Expected: ** BUILD SUCCEEDED **

- [ ] **Step 4: Commit**

```bash
git add wawa-note/UI/Knowledge/KnowledgeDetailView.swift
git commit -m "refactor: remove old contextSection and duplicate context badges

Prep for context detail view redesign."
```

---

### Task 2: Build the 3 grouped context cards

**Files:**
- Modify: `UI/Knowledge/KnowledgeDetailView.swift` — replace `contextSection` body

**Interfaces:**
- Consumes: `item.contextPlaceName`, `item.contextLatitude`, `item.contextLongitude`, `item.contextCalendarEventTitle`, `item.calendarEventIdentifier`, `item.contextAudioRoute`, `item.contextMotionActivity`, `item.contextBatteryLevel`, `item.contextFocusActive`
- Consumes: Person records matching contacts (via `contextCalendarEventTitle` match — contacts are stored during cross-reference, but for display we check if any Person has been linked; for now, skip contact display until Gap 3 Person linking is fully wired)

- [ ] **Step 1: Implement the 3 group cards in `contextSection`**

Replace the `EmptyView()` placeholder:

```swift
  private var contextSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      sectionHeader("Context", icon: "location.fill.viewfinder")

      VStack(spacing: 8) {
        if let place = item.contextPlaceName {
          placeGroup(place)
        }

        if let event = item.contextCalendarEventTitle {
          eventGroup(event)
        }

        if hasDeviceFields {
          deviceGroup
        }
      }
    }
    .padding(.horizontal, 16)
  }

  private var hasDeviceFields: Bool {
    item.contextAudioRoute != nil || item.contextMotionActivity != nil
      || item.contextBatteryLevel != nil || item.contextFocusActive != nil
  }

  // MARK: - Place group

  private func placeGroup(_ place: String) -> some View {
    let displayText: String = {
      if let lat = item.contextLatitude, let lon = item.contextLongitude {
        return "\(place)\n(\(String(format: "%.4f", lat)), \(String(format: "%.4f", lon)))"
      }
      return place
    }()

    return GroupCard(icon: "mappin.and.ellipse", color: .blue) {
      VStack(alignment: .leading, spacing: 2) {
        Text(place).font(.caption).foregroundStyle(.primary)
        if item.contextLatitude != nil || item.contextLongitude != nil {
          Text("(\(String(format: "%.4f", item.contextLatitude ?? 0)), \(String(format: "%.4f", item.contextLongitude ?? 0)))")
            .font(.caption2).foregroundStyle(.secondary)
            .monospacedDigit()
        }
      }
    }
    .contextMenu {
      Button { UIPasteboard.general.string = place } label: {
        Label("Copy location", systemImage: "doc.on.doc")
      }
    }
  }

  // MARK: - Event group

  private func eventGroup(_ event: String) -> some View {
    GroupCard(icon: "calendar.badge.clock", color: .orange) {
      HStack(spacing: 6) {
        Text(event).font(.caption).foregroundStyle(.primary)
        if item.calendarEventIdentifier != nil {
          HStack(spacing: 2) {
            Image(systemName: "checkmark.seal.fill")
              .font(.system(size: 10))
              .foregroundStyle(.green)
            Text("Matched")
              .font(.caption2)
              .foregroundStyle(.green)
          }
          .padding(.horizontal, 4).padding(.vertical, 1)
          .background(.green.opacity(0.12), in: Capsule())
        }
      }
    }
    .contextMenu {
      Button { UIPasteboard.general.string = event } label: {
        Label("Copy event", systemImage: "doc.on.doc")
      }
    }
  }

  // MARK: - Device group

  private var deviceGroup: some View {
    GroupCard(icon: "airpodspro", color: .indigo) {
      HStack(spacing: 6) {
        if let route = item.contextAudioRoute {
          HStack(spacing: 3) {
            Image(systemName: audioRouteIcon(for: route)).font(.system(size: 9))
            Text(shortAudioLabel(route)).font(.caption)
          }
          .foregroundStyle(.primary)
        }
        if let motion = item.contextMotionActivity {
          if item.contextAudioRoute != nil { Text("·").font(.caption2).foregroundStyle(.tertiary) }
          HStack(spacing: 3) {
            Image(systemName: motionIcon(for: motion)).font(.system(size: 9))
            Text(motion).font(.caption)
          }
          .foregroundStyle(.secondary)
        }
        if let battery = item.contextBatteryLevel {
          if item.contextAudioRoute != nil || item.contextMotionActivity != nil {
            Text("·").font(.caption2).foregroundStyle(.tertiary)
          }
          HStack(spacing: 3) {
            Image(systemName: batteryIcon(for: battery)).font(.system(size: 9))
            Text("\(Int(battery * 100))%").font(.caption)
          }
          .foregroundStyle(.secondary)
        }
        if let focus = item.contextFocusActive {
          if item.contextAudioRoute != nil || item.contextMotionActivity != nil || item.contextBatteryLevel != nil {
            Text("·").font(.caption2).foregroundStyle(.tertiary)
          }
          HStack(spacing: 3) {
            Image(systemName: focus ? "moon.fill" : "sun.max").font(.system(size: 9))
            Text(focus ? "Focus" : "Active").font(.caption)
          }
          .foregroundStyle(.secondary)
        }
      }
    }
    .contextMenu {
      let deviceText = [
        item.contextAudioRoute.map { shortAudioLabel($0) },
        item.contextMotionActivity,
        item.contextBatteryLevel.map { "\(Int($0 * 100))%" },
        item.contextFocusActive.map { $0 ? "Focus active" : "Focus inactive" }
      ].compactMap { $0 }.joined(separator: " · ")
      if !deviceText.isEmpty {
        Button { UIPasteboard.general.string = deviceText } label: {
          Label("Copy device info", systemImage: "doc.on.doc")
        }
      }
    }
  }

  // MARK: - Helper formatters

  private func audioRouteIcon(for route: String) -> String {
    let lower = route.lowercased()
    if lower.contains("bluetooth") || lower.contains("airpod") { return "airpodspro" }
    if lower.contains("speaker") { return "speaker.wave.2" }
    if lower.contains("headphone") || lower.contains("wired") { return "headphones" }
    if lower.contains("car") { return "car" }
    return "mic.fill"
  }

  private func shortAudioLabel(_ route: String) -> String {
    let lower = route.lowercased()
    if lower.contains("airpod") { return "AirPods" }
    if lower.contains("bluetooth") { return "Bluetooth" }
    if lower.contains("speaker") { return "Speaker" }
    if lower.contains("headphone") { return "Headphones" }
    if lower.contains("car") { return "Car" }
    if route.count > 20 { return String(route.prefix(18)) + "…" }
    return route
  }

  private func motionIcon(for activity: String) -> String {
    switch activity.lowercased() {
    case "stationary": "figure.stand"
    case "walking": "figure.walk"
    case "running": "figure.run"
    case "automotive": "car"
    case "cycling": "bicycle"
    default: "figure.walk"
    }
  }

  private func batteryIcon(for level: Double) -> String {
    if level >= 0.75 { "battery.75" }
    else if level >= 0.5 { "battery.50" }
    else if level >= 0.25 { "battery.25" }
    else { "battery.0" }
  }
```

- [ ] **Step 2: Add `GroupCard` component at the bottom of the file**

```swift
// MARK: - Context Group Card

private struct GroupCard<Content: View>: View {
  let icon: String
  let color: Color
  @ViewBuilder let content: () -> Content

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: icon)
        .font(.system(size: 13))
        .foregroundStyle(color)
        .frame(width: 22, alignment: .leading)
      content()
      Spacer(minLength: 0)
    }
    .padding(10)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
  }
}
```

- [ ] **Step 3: Build, deploy, and verify on device**

```bash
make deploy DEVICE=14plus
```

Expected: ** BUILD SUCCEEDED **

- [ ] **Step 4: Verify visually on iPhone 14 Plus**

Open an item that has context data (record a test meeting). Verify:
- Place group shows location name + coordinates
- Event group shows calendar event title + "Matched" badge (green)
- Device group shows audio, motion, battery, focus with icons
- Long press → context menu with "Copy" appears
- Haptic feedback on long press
- Items without context show no section (no empty cards)

- [ ] **Step 5: Commit**

```bash
git add wawa-note/UI/Knowledge/KnowledgeDetailView.swift
git commit -m "feat: context detail view — grouped cards with material design and Copy interaction

Replace debug-style capsules with 3 grouped cards (Place, Event, Device).
Each card uses .regularMaterial background. Calendar events show Matched
badge when cross-reference confirmed. ContextMenu with Copy on each group.
Remove duplicate context badges."
```
