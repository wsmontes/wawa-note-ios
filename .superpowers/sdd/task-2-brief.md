# Task 2: 3-tab Project Detail (KAN-520)

**Goal:** Redesign ProjectDetailView to have 3 tabs: Chat | Items | Files. First tab becomes Chat scoped to project.

**File to modify:** `wawa-note/UI/Project/ProjectDetailView.swift`

## Requirements

1. Change `ProjectTab` enum to: `case chat = "Chat"`, `case items = "Items"`, `case files = "Files"`
2. Set default selected tab to `.chat`
3. Add a `ProjectChatView` struct that shows ChatView with project context
4. Wire the switch statement to the new tabs
5. Build must succeed

## ProjectChatView code

Add this struct to the file:

```swift
struct ProjectChatView: View {
    let project: Project
    @StateObject private var chatVM = ChatViewModel()
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ChatView(viewModel: chatVM, compact: false)
            .onAppear {
                chatVM.setup(modelContext: modelContext)
                chatVM.activeProjectID = project.id
                chatVM.activeProjectName = project.name
                if let hex = project.colorHex {
                    chatVM.activeProjectColorHex = hex
                }
            }
    }
}
```

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
KAN-520: 3-tab Project Detail (Chat, Items, Files) with ProjectChatView
Co-Authored-By: Claude <noreply@anthropic.com>
```

## Report

Write to `.superpowers/sdd/task-2-report.md`
