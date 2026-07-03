# Context Detail View — Design Spec

Date: 2026-07-03
Status: Approved

## Goal

Redesign the `contextSection` in `KnowledgeDetailView` so captured device context
(location, calendar event, audio route, motion, battery, focus, matched contacts)
is readable, polished, and no longer looks like debug output.

## Non-goals

- No navigation to external apps (Maps, Calendar, Contacts)
- No internal filtering/querying by context
- No context badges in Inbox rows or Chat messages (chat already has Gap 2 prompt injection)
- No context refresh or editing

## Current state

`contextSection` (line 730) renders tiny `.caption2` capsules in `.tertiarySystemBackground`
gray. The data was never populated until the Gap 1 bridge was implemented. The same
data also appears redundantly in the `badges` array (lines 844-845).

## Design

### Layout: 3 grouped rows

Each group is a subtle card (`.regularMaterial`, 10 pt radius, no shadow).
A group only renders when at least one of its fields is non-nil.

```
┌─────────────────────────────────────────────┐
│  📍 São Paulo, SP                           │
│     ( -23.5505, -46.6333 )                  │
├─────────────────────────────────────────────┤
│  📅 Sprint Planning  ← matched ✓            │
│     👤 John Appleseed                       │
├─────────────────────────────────────────────┤
│  🎙️ AirPods Pro · 🚶 stationary · 🔋 85%   │
│     🔕 Focus active                         │
└─────────────────────────────────────────────┘
```

### Groups

| Group | Icon | Fields | Shows when |
|-------|------|--------|------------|
| Place | `mappin.and.ellipse` | `contextPlaceName` + `(contextLatitude, contextLongitude)` | `contextPlaceName != nil` |
| Event | `calendar.badge.clock` | `contextCalendarEventTitle` + matched badge + contact names from Person records | `contextCalendarEventTitle != nil` or matched contacts exist |
| Device | `airpodspro` | `contextAudioRoute`, `contextMotionActivity`, `contextBatteryLevel`, `contextFocusActive` | any of the four != nil |

### Matched badge

When `calendarEventIdentifier != nil`, a small green seal appears next to the
event title: `checkmark.seal.fill` in `.green` + "Matched" in `.caption2`.
This distinguishes AI-cross-referenced matches from raw sensor captures.

### Typography & colors

- Group icon: SF Symbol 14 pt, `.secondary`
- Labels: `.caption` `.secondary`
- Values: `.caption` `.primary`
- Coordinates: `.caption2` `.secondary` monospaced
- Background: `.regularMaterial`, 10 pt radius, no shadow
- Chips: no more `.tertiarySystemBackground` capsules — just inline text with SF Symbol separators

### Interaction

- `contextMenu` on each group card with a single "Copy" action
- Copy copies the primary value (place name, event title, or route) to UIPasteboard
- `Haptics.light()` on long press

### What is removed

- The duplicate `contextCalendarEventTitle` and `contextAudioRoute` entries in the `badges` array (lines 844-845)
- The old `contextBadge` helper and its `.tertiarySystemBackground` capsule style

### What stays the same

- `hasContextFields` computed property controls visibility
- Section header "Context" with `location.fill.viewfinder` icon
- The section is inside the existing scroll view layout — no structural changes

## Files modified

- `UI/Knowledge/KnowledgeDetailView.swift` — redesign `contextSection`, `contextBadge`, remove duplicate badges, add contextMenu

## No new files

Changes are confined to a single existing file.
