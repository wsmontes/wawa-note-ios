# Task 1: Remove Chat tab from navigation (KAN-519)

**Goal:** Remove the 4th tab (Chat) from ContentView.swift. Navigation becomes 3 tabs: Capture | Inbox | Explore.

**File to modify:** `wawa-note/UI/Components/ContentView.swift`

## Requirements

1. Remove the Chat tab entry from the TabView in ContentView.swift
2. The tab bar must show exactly 3 items: Capture, Inbox, Explore
3. The `.badge(inboxPendingCount)` modifier that was on the Chat tab should be removed
4. ChatView is still used via ProjectDetailView (do NOT delete ChatView.swift)
5. Build must succeed

## Code to remove

Find the Chat tab in the TabView (look for `tabItem { Label("Chat", ...) }` or similar) and remove the entire tab entry. The TabView currently has 4 tabs; after this task it should have exactly 3.

## Verification

```bash
cd /Users/wagnermontes/Documents/GitHub/wawa-note-ios
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note \
  -destination 'platform=iOS Simulator,name=iPhone 14 Plus,OS=latest' build 2>&1 | \
  grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -3
```

Expected: `** BUILD SUCCEEDED **`

## Commit message

```
KAN-519: remove Chat tab from main navigation — 3 tabs (Capture, Inbox, Explore)

Co-Authored-By: Claude <noreply@anthropic.com>
```

## Report

Write a short report to `.superpowers/sdd/task-1-report.md` covering: what you changed, build result, any concerns.
