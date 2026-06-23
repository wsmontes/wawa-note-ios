# TrashService & ConfigProjectService — Wawa Note

**Last updated:** 2026-06-22
**Related JIRA:** KAN-208
**Source modules:** `Domain/Services/TrashService.swift`, `Domain/Services/ConfigProjectService.swift`

---

## TrashService

### Overview
Soft-delete service for KnowledgeItems. Items moved to trash are hidden from normal views but not permanently deleted. This provides a safety net for accidental deletions.

### Operations

```swift
protocol TrashServiceProtocol {
    func moveToTrash(_ item: KnowledgeItem) throws
    func restoreFromTrash(_ item: KnowledgeItem) throws
    func emptyTrash() throws
    func trashFolder() -> Folder?
}
```

### Lifecycle

1. **Move to Trash:**
   - Set `item.status = .archived`
   - Assign to trash Folder (special folder with `isTrashFolder = true`)
   - Item hidden from Inbox, Explore, and project views
   - Item visible only in Inbox → Trash filter
   - Audio/transcript/analysis files NOT deleted (kept for recovery)

2. **Restore from Trash:**
   - Set `item.status` back to previous state (stored before archiving)
   - Remove from trash Folder
   - Item reappears in original location

3. **Empty Trash:**
   - Requires user confirmation (destructive action)
   - Iterates all items in trash Folder
   - Deletes item directories from filesystem (`FileArtifactStore.deleteItemDirectory()`)
   - Deletes SwiftData records
   - Irreversible (files permanently deleted)

### UI Integration
- InboxView → Trash filter → shows trashed items
- Trash item swipe action → "Restore" or "Delete Forever"
- Trash filter toolbar → "Empty Trash" button with confirmation alert
- Undo toast on move-to-trash (5-second window)

---

## ConfigProjectService

### Overview
Manages the internal `wawa-note-config` project — a special project accessible through the VFS that holds system configuration. This allows the agent and power users to inspect and modify configuration through the same filesystem interface used for knowledge items.

### Purpose
Instead of scattered configuration files and settings screens, system configuration is consolidated into a VFS-accessible project:
- AI provider configurations
- Prompt templates
- Framework schemas
- Agent memory/learned patterns
- Sync settings
- Migration state

### VFS Paths
```
/config/providers          → AI provider configs
/config/prompts            → Editable prompt templates
/config/settings           → App settings
/config/schemas            → Framework schemas
/config/memories           → Agent learned patterns
```

### Agent Access
The LLM agent can read and modify configuration through standard VFS commands:
```bash
run_command "cat /config/providers"           # List all providers
run_command "cat /config/prompts/analysis"    # Read analysis prompt
run_command "echo '...' > /config/prompts/analysis"  # Update prompt
```

### Implementation
- ConfigProjectService creates and manages the `wawa-note-config` project on first launch
- Project is hidden from normal UI (`Project.isHidden = true`)
- Accessible only through VFS (agent) and Settings UI
- Config changes are audited (ChangeRecord entries)
