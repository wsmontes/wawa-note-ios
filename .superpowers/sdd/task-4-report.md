# Task 4 Report: Scope Chat to Project Context (KAN-522)

## Summary

Scoped `ChatView` when used inside `ProjectChatView` (created in Task 2, KAN-520) to isolate the chat's context to the active project.

## Changes Made

### 1. `wawa-note/UI/Project/ProjectDetailView.swift` (modified)

**`ProjectChatView.onAppear`** — replaced direct property assignment with `chatVM.setProjectContext(project:)`.

**Before:**
```swift
chatVM.activeProjectID = project.id
chatVM.activeProjectName = project.name
if let hex = project.colorHex {
    chatVM.activeProjectColorHex = hex
}
```

**After:**
```swift
chatVM.setProjectContext(project: project)
```

### 2. `wawa-note/UI/Chat/ChatViewModel.swift` (already committed in KAN-521)

The `setProjectContext(project:)` method was already introduced in `aa0bda5` (KAN-521). It:

1. Sets `activeProjectID`, `activeProjectName`, and `activeProjectColorHex`
2. Resolves project color with `ProjectPalette.allHexes.first!` fallback
3. Calls `switchToContext(.project(project.id))` which:
   - Loads/creates the project-specific conversation
   - Calls `injectProjectContext(project:conversationId:)` to inject synthetic `cd` and `ls` tool calls so the agent sees project navigation as already completed
   - Generates a project-aware greeting (e.g., "They're viewing **Project Name**. Offer to help.")
   - Sets `activeContext` to `.project(id)` — scoping all subsequent `ToolContext` and VFS operations to this project's items

## Verification

### Requirement 1: Chat focuses on project items when `activeProjectID` is set
- `switchToContext(.project(id))` loads the conversation keyed by `"project:<uuid>"`
- Every `sendMessage()` call creates a `ToolContext` with `activeProjectID` passed through
- The `AgentLoop.buildPromptFragments()` includes project context in the dynamic system prompt when `toolContext.activeProjectSlug` is set
- `ShellInterpreter` scopes all `ls`, `cat`, `find`, `grep`, `touch`, `echo`, `rm`, `mv` operations to the active project via `VFSService.resolve()` path resolution

### Requirement 2: Greeting mentions project name in project context
- `welcomePrompt(for:projectName:)` case `.project` already uses `projectName`:
  ```
  "Greet the user. One line. They're viewing \(name). Offer to help."
  ```
- `generateWelcome(for:)` passes `activeProjectName` to `welcomePrompt`
- Greeting is cached per-context-key (`"project:<uuid>"`), so each project gets its own cached greeting

### Requirement 3: ToolContext/VFS scoped to project items
- `ToolContext` receives `activeProjectID`, `activeProjectName`, `activeProjectSlug`
- `AgentLoop` dynamic prompt shows `CURRENT DIRECTORY: /projects/{slug}/`
- `ShellInterpreter` scopes all operations to `ctx.activeProjectID` (e.g., `ls` lists only project items, `touch` creates items/tasks within the project)
- The sandbox mechanism (`sandboxedItemID`) provides an additional layer of restriction when analyzing individual items

## Pre-existing Infrastructure Used

The following were already in place and did not need changes:

- `ToolContext.activeProjectID` — scopes all VFS operations
- `ShellInterpreter` — already scopes `ls`, `cat`, `find`, `grep`, `touch`, `echo`, `rm`, `mv` to active project
- `AgentLoop` — includes project context in dynamic system prompt
- `ChatViewModel.switchToContext(.project(id))` — loads project conversation and context
- `ChatViewModel.injectProjectContext(project:conversationId:)` — injects synthetic `cd`/`ls` commands
- `welcomePrompt(for:projectName:)` — already handles project case with project name
- `GreetingCache` — already keys by `Context.key` (e.g., `"project:<uuid>"`)

## Build Notes

- Build confirmed — no errors in modified files (`ProjectDetailView.swift`)
- Pre-existing build failures (`ProjectIngestionPipeline` not found) are unrelated and track to KAN-523
