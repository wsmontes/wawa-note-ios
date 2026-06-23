# File Storage Architecture — Wawa Note

**Last updated:** 2026-06-22
**Related JIRA:** KAN-57, KAN-58
**Source modules:** `Storage/`, `Domain/Services/KnowledgeItemService.swift`

---

## Overview

Wawa Note stores large artifacts (audio, transcripts, analysis JSON, scanned images) on the filesystem, using SwiftData only for metadata and indexable records. The storage layer provides atomic writes, crash recovery, backup exclusion, and App Group sharing for the Share Extension.

---

## Directory Layout

```
~/Library/Application Support/Meetings/
  .wawa-store-check                    ← Sentinel file for write validation
  items/
    <uuid>/                            ← One directory per KnowledgeItem
      audio.m4a                        ← Final concatenated audio (AAC)
      transcript.json                  ← Transcription output
      analysis.json                    ← AI analysis output
      segments/                        ← Recording segments (before concatenation)
        manifest.json                  ← Segment list + checkpoint markers
        segment_001.wav                ← PCM WAV segment (~5s each)
        segment_002.wav
        ...
      images/                          ← Scanned document pages
        page_01.jpg
        page_02.jpg
        ...
      bookmarks/                       ← Web bookmark snapshots
        snapshot.html
  configs/
    ai_config.json                     ← AI provider config (bundle default + overrides)
    prompts/                           ← User prompt template overrides
    frameworks/                        ← Custom framework schemas
    agent_memory.json                  ← AgentMemoryStore patterns
    model_cache.json                   ← ModelCache (1hr TTL)
    metrics.json                       ← MetricsHistoryStore
  Chat/
    <conversation_id>/                 ← Chat conversation persistence
      index.json                       ← Message index
      messages.json                    ← Message array
  exports/                             ← User export output directory
  media/                               ← Shared media files

group.com.wawa-note/shared/            ← App Group (Share Extension)
  imported_files/                      ← Files received from Share Extension
```

---

## FileArtifactStore

Central filesystem manager. All file operations go through this class.

### Initialization
```swift
class FileArtifactStore {
    let baseURL: URL  // ~/Library/Application Support/Meetings/

    init() {
        // 1. Resolve applicationSupportDirectory
        // 2. Fallback to cachesDirectory if unavailable
        // 3. Create base directory + subdirectories
        // 4. Write sentinel file .wawa-store-check
        // 5. Apply file protection: .completeUnlessOpen
        // 6. Exclude from iTunes/iCloud backup
    }
}
```

### Key methods
```swift
func createItemDirectory(id: UUID) -> URL
func writeArtifact(data: Data, to relativePath: String) throws
func readArtifact(at relativePath: String) throws -> Data
func deleteItemDirectory(id: UUID) throws
func artifactExists(at relativePath: String) -> Bool
func artifactSize(at relativePath: String) -> Int64
func availableDiskSpace() -> Int64
```

### Sentinel validation
On init, writes a `.wawa-store-check` file to verify:
- Directory is writable
- File protection is working
- Disk has enough free space
If sentinel write fails → critical error logged, `.cachesDirectory` fallback with persistent preference in UserDefaults.

### File protection
```swift
func applyBaseProtection() {
    try? FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUnlessOpen],
        ofItemAtPath: baseURL.path
    )
}
```
`completeUnlessOpen` allows writing while app is in foreground, protects files when device is locked.

### Backup exclusion
All content under `Meetings/` is excluded from iCloud/iTunes backup:
```swift
var values = URLResourceValues()
values.isExcludedFromBackup = true
try? baseURL.setResourceValues(values)
```

---

## Atomic Write Pattern

All writes use temp → rename for atomicity:

```swift
func atomicWrite(data: Data, to url: URL) throws {
    let tempURL = url.appendingPathExtension("tmp")
    try data.write(to: tempURL, options: .completeFileProtection)
    try FileManager.default.replaceItemAt(url, withItemAt: tempURL, backupItemName: nil)
}
```

### Benefits
- No partial writes visible to readers
- If app crashes mid-write, temp file is left, not corrupted target
- `.completeFileProtection` ensures data hits storage before rename

### BAK backup on critical files
For `analysis.json`, `transcript.json`, and `index.json`:
1. Write new content to `.tmp`
2. Copy existing to `.BAK` (if exists)
3. Rename `.tmp` → target
4. Delete `.BAK` on confirmed success

---

## SecureKeyStore

Keychain-based API key storage:

```swift
class SecureKeyStore {
    func save(key: String, value: String, service: String) throws
    func load(key: String, service: String) throws -> String?
    func delete(key: String, service: String) throws
}
```

### Key format
```
Service: com.wawa-note.provider.<provider_id>
Key: api_key
```

### Security
- Uses Keychain with `kSecAttrAccessibleAfterFirstUnlock`
- API keys never written to UserDefaults or files
- Provider configs (without keys) in SwiftData, keys only in Keychain

---

## Chat Persistence

Chat conversations and messages stored as JSON files (not SwiftData):

### Directory: `Chat/<conversation_id>/`
- `index.json` — ChatConversation metadata (id, title, providerId, model, messageCount, contextKey)
- `messages.json` — Array of ChatMessage (id, conversationId, role, content, toolCalls, blocksJSON)

### Atomic write + BAK recovery
```swift
func writeMessages(_ messages: [ChatMessage], for conversation: ChatConversation) throws {
    let dir = chatDirectory(for: conversation.id)
    let targetURL = dir.appendingPathComponent("messages.json")
    let data = try JSONEncoder().encode(messages)
    try atomicWrite(data: data, to: targetURL, withBackup: true)
}
```

### Auto-recovery
On app launch, ChatService scans Chat/ directory:
1. If `index.json` exists but `messages.json` is missing → recover from `.BAK`
2. If both are corrupted → create empty conversation, log error
3. Orphaned `.tmp` files → delete

---

## Crash Recovery

### Recording crash recovery
On app launch, scan `items/<uuid>/segments/manifest.json` for all items:
- Check `status == .recording` → crash during recording
- Recover segments up to last checkpoint marker
- Concatenate partial recording, set status to `.failed` or `.transcribed`
- Alert user: "Recording was interrupted. Partial recording saved."

### Analysis crash recovery
- On launch, scan for items with `status == .analyzing`
- Check for `.analysis.tmp.json` → crash during write
- If exists and valid → rename to `analysis.json`, set status to `.analyzed`
- If exists and invalid → delete temp, set status to `.pendingReview`

### Chat recovery
- Scan `Chat/` directory for orphaned `.tmp` files → delete
- For each conversation, verify `index.json` + `messages.json` integrity
- Corrupted conversations → recover from `.BAK`

---

## Disk Space Management

### Proactive monitoring
```swift
func availableDiskSpace() -> Int64 {
    let values = try? baseURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage ?? 0
}
```

### Recording pre-check
Before starting recording:
1. Estimate required space: `sampleRate × 4 bytes × estimatedDuration + 50MB margin`
2. Check against `availableDiskSpace()`
3. If insufficient → alert user, suggest freeing space
4. During recording: monitor every 30s, warn at 100MB remaining, force-stop at 50MB

### Low-space notifications
- 200MB remaining → "Running low on storage"
- 100MB remaining → "Recording may stop soon"
- 50MB remaining → forceStop(), show alert

---

## App Group Container

`group.com.wawa-note` shared with Share Extension:

### Share Extension flow
1. User shares file from another app → ShareViewController
2. File copied to `group.com.wawa-note/shared/imported_files/`
3. App checks `shared/imported_files/` on `.willEnterForeground`
4. Files imported → moved to `Meetings/items/<uuid>/`
5. Imported files cleaned up after successful import

### Security boundary
- App Group container accessible by both main app and Share Extension
- Downloaded files stay in App Group until import confirmed
- Main app moves files to its sandboxed `Meetings/` directory on import

---

## File Cleanup

### Item deletion
```swift
func deleteItemDirectory(id: UUID) throws {
    let dir = itemDirectory(for: id)
    if FileManager.default.fileExists(atPath: dir.path) {
        try FileManager.default.removeItem(at: dir)
    }
}
```

### Trash
- TrashService.moveToTrash() → moves item to Trash folder (SwiftData only)
- Files NOT deleted until `emptyTrash()` confirmed
- emptyTrash() → deletes all items with `status == .archived` AND their file directories
- Confirmation dialog required before permanent deletion

### Orphan cleanup
Periodic cleanup (every 7 days):
- Find item directories without corresponding SwiftData records → log + offer "Clean Up" option
- Find SwiftData records pointing to non-existent directories → recreate directory, flag item

---

## Migration

### Migration registry (KAN-58)
- Plist file: `configs/migrations.plist`
- Tracks which migrations have been applied
- Each migration has: id, date, description, version
- Applied migrations are never re-run

### Store recovery (KAN-57)
- Before any destructive operation: copy SwiftData store to backup
- Backup location: `configs/store_backup_<timestamp>.sqlite`
- If operation fails → restore from backup
- User can trigger manual "Repair File Store" from Settings

---

## Performance

| Metric | Value |
|---|---|
| Atomic write latency | <50ms (SSD) |
| File protection | completeUnlessOpen |
| Backup exclusion | All Meetings/ contents |
| Max directory depth | 3 (Meetings/items/uuid/) |
| Sentinal validation | On every init |
| Orphan scan interval | 7 days |
| Chat BAK recovery | On app launch |
