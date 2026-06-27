# Task 1 Report: Remove Chat tab from navigation (KAN-519)

## What was changed

**File:** `wawa-note/UI/Components/ContentView.swift`

1. **Removed the Chat tab entry** — `Color.clear` with `.tabItem { Label("Chat", ...) }` and `.tag(3)` was removed from the TabView. Navigation is now 3 tabs: Capture (tag 0), Inbox (tag 1 with badge), Explore (tag 2).

2. **Simplified the TabView selection binding** — Removed the `Binding` with custom setter that handled tag 3 (showing the chat overlay). Replaced with a simple `TabView(selection: $selectedTab)`.

3. **Removed the chat overlay UI** — The `if showChat { ... }` block (overlay background + ChatView) was removed since nothing sets `showChat` to true anymore. The `showChat` state variable was also removed.

4. **Kept environment objects** — `ChatOverlayState` and `ChatViewModel` are still created and injected as environment objects because `ExploreView` (defined in the same file) still depends on them.

5. **Kept inbox badge** — `.badge(inboxPendingCount)` remains on the Inbox tab (it was never on the Chat tab in the current code).

## Build result

**BUILD SUCCEEDED** — no errors.

## Concerns

- `ChatView` is no longer referenced from `ContentView.swift` but is still used by `ProjectDetailView`, per requirements.
- `safeAreaBottom` State variable is now set but never read (trace of the removed overlay's keyboard positioning). This does not produce a warning since `@State` properties are considered inherently "used" by SwiftUI.
