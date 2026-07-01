import Foundation



import OSLog







public enum FileArtifactStoreError: Error {



  case fileNotFound



  case writeFailed(Error)



  case readFailed(Error)



  case encodingFailed



  case directoryCreationFailed(Error)



  case protectionFailed(Error)



  case backupExclusionFailed(Error)



  case sentinelWriteFailed(Error)



}







public enum AppFileConstants {



  public static let audioFileName = "audio.m4a"



  public static let transcriptFileName = "transcript.json"



  public static let analysisFileName = "analysis.json"



  public static let dynamicAnalysisFileName = "analysis.dynamic.json"



  public static let partialTranscriptFileName = "transcript_partial.json"



  public static let manifestFileName = "recording.manifest.json"



  public static let segmentsDirectoryName = "segments"



  public static let checkpointFileName = "checkpoint.json"



  public static let embeddingFileName = "embedding.json"



  public static let scanFileName = "scan"



  public static let scanFilePattern = "scan_%d.jpg"



  /// File size threshold below which a manifest is considered invalid (0-byte or truncated).



  public static let minimumValidFileSize: Int64 = 1



}







// MARK: - Standard directory names (single source of truth)







public enum AppDirectoryNames {



  public static let items = "items"



  public static let configs = "configs"



  public static let chat = "Chat"



  public static let media = "media"



  public static let exports = "exports"



  public static let base = "Meetings"



  /// Sentinel file written during init to validate write access to the base directory.



  public static let sentinelFileName = ".wawa-store-check"



  /// UserDefaults key that records which directory the store is using (applicationSupport or caches).



  public static let storeLocationKey = "FileArtifactStore.baseURLCategory"



}







public final class FileArtifactStore: @unchecked Sendable {



  private let fileManager: FileManager



  private let baseURL: URL



  private let logger = Logger(subsystem: "com.wawa-note.core", category: "FileArtifactStore")







  public init(fileManager: FileManager = .default) {



    self.fileManager = fileManager







    // Resolve base URL with validated fallback.



    // applicationSupportDirectory can theoretically be empty in sandboxed



    // environments or during very early boot. Guard against crash and fall



    // back to caches rather than force-unwrapping .first.



    if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)



      .first



    {



      self.baseURL = appSupport.appendingPathComponent(AppDirectoryNames.base, isDirectory: true)



      logger.info(



        "FileArtifactStore: using applicationSupportDirectory — \(self.baseURL.path)")



    } else {



      logger.error(



        "FileArtifactStore: applicationSupportDirectory unavailable, using caches fallback")



      self.baseURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!



        .appendingPathComponent(AppDirectoryNames.base, isDirectory: true)



    }







    // Persist the chosen location so future sessions can detect a switch



    // (e.g., if a backup-restore changes sandbox availability).



    let locationCategory = baseURL.path.contains("Caches") ? "caches" : "applicationSupport"



    UserDefaults.standard.set(locationCategory, forKey: AppDirectoryNames.storeLocationKey)



    if locationCategory == "caches" {



      logger.warning(



        "Config data stored in cachesDirectory — may be purged by system. Consider freeing device storage."



      )



    }







    // Ensure base directory exists and validate write access with a sentinel.



    applyBaseProtection()



    validateWriteAccess()







    // Create all standard subdirectories upfront so no service ever writes



    // to a non-existent directory. Idempotent — safe to call repeatedly.



    ensureStandardDirectories()



  }







  // MARK: - Directory initialization & protection







  /// Create the base store directory and apply file protection + backup exclusion.



  /// Errors are logged at `.error` / `.critical` level — the store can limp along



  /// with degraded protection, but we must not silently ignore failures.



  private func applyBaseProtection() {



    do {



      if !fileManager.fileExists(atPath: baseURL.path) {



        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)



      }







      // File protection: encrypt at rest, allow writing while locked



      try fileManager.setAttributes(



        [.protectionKey: FileProtectionType.completeUnlessOpen],



        ofItemAtPath: baseURL.path



      )







      // Exclude from iCloud backup — recordings and derived artifacts are



      // regenerable and can be large (300+ MB/hour). Required by App Store



      // guidelines for non-user-generated / regenerable data.



      var resourceValues = URLResourceValues()



      resourceValues.isExcludedFromBackup = true



      var base = baseURL



      try base.setResourceValues(resourceValues)



    } catch {



      logger.error(



        "FileArtifactStore: applyBaseProtection failed — \(error.localizedDescription)")



    }



  }







  /// Verify that the store can actually write to the chosen baseURL by creating



  /// a small sentinel file. If this fails, the store is effectively read-only



  /// and every subsequent operation will fail.



  private func validateWriteAccess() {



    let sentinel = baseURL.appendingPathComponent(AppDirectoryNames.sentinelFileName)



    let testData = Data("wawa-store-ok".utf8)



    do {



      try testData.write(to: sentinel, options: .atomic)



      logger.debug("FileArtifactStore: write access validated — sentinel OK")



    } catch {



      logger.critical(



        "FileArtifactStore: write access validation FAILED — store may be read-only: \(error.localizedDescription)"



      )



    }



    // Clean up — the sentinel is a one-shot check, not a persistent marker.



    try? fileManager.removeItem(at: sentinel)



  }







  /// Create all standard subdirectories with proper protection and backup exclusion.



  /// Idempotent — directories that already exist are skipped without error.



  public func ensureStandardDirectories() {

    let dirs: [(String, URL)] = [



      (



        AppDirectoryNames.items,



        baseURL.appendingPathComponent(AppDirectoryNames.items, isDirectory: true)



      ),



      (



        AppDirectoryNames.configs,



        baseURL.appendingPathComponent(AppDirectoryNames.configs, isDirectory: true)



      ),



      (



        AppDirectoryNames.chat,



        baseURL.appendingPathComponent(AppDirectoryNames.chat, isDirectory: true)



      ),



      (



        AppDirectoryNames.media,



        baseURL.appendingPathComponent(AppDirectoryNames.media, isDirectory: true)



      ),



      (



        AppDirectoryNames.exports,



        baseURL.appendingPathComponent(AppDirectoryNames.exports, isDirectory: true)



      ),



    ]







    for (name, url) in dirs {



      do {



        if !fileManager.fileExists(atPath: url.path) {



          try fileManager.createDirectory(at: url, withIntermediateDirectories: true)



        }







        // File protection — inherit from base



        try? fileManager.setAttributes(



          [.protectionKey: FileProtectionType.completeUnlessOpen],



          ofItemAtPath: url.path



        )







        // Exclude from iCloud backup



        var values = URLResourceValues()



        values.isExcludedFromBackup = true



        var mutableURL = url



        try mutableURL.setResourceValues(values)



      } catch {



        logger.error(



          "FileArtifactStore: failed to configure \(name)/ directory — \(error.localizedDescription)"



        )



      }



    }







    logger.debug("FileArtifactStore: standard directories ensured")



  }







  // MARK: - Disk space







  /// Returns free space (in bytes) on the volume containing the base store



  /// directory, or nil if the resource values can't be read.



  public func freeSpaceForCurrentRecording() -> Int64? {

    guard



      let values = try? baseURL.resourceValues(forKeys: [



        .volumeAvailableCapacityForImportantUsageKey



      ]),



      let free = values.volumeAvailableCapacityForImportantUsage



    else {



      return nil



    }



    return free



  }







  // MARK: - Directory management







  public func meetingDirectoryURL(for meetingId: UUID) -> URL {



    itemDirectoryURL(for: meetingId)



  }







  // MARK: - New knowledge workspace paths







  public func itemDirectoryURL(for itemId: UUID) -> URL {



    baseURL.appendingPathComponent(AppDirectoryNames.items, isDirectory: true)



      .appendingPathComponent(itemId.uuidString, isDirectory: true)



  }







  public func mediaURL(for contentHash: String, ext: String) -> URL {

    baseURL.appendingPathComponent(AppDirectoryNames.media, isDirectory: true)



      .appendingPathComponent("\(contentHash).\(ext)")



  }







  public func configsDirectoryURL() -> URL {



    baseURL.appendingPathComponent(AppDirectoryNames.configs, isDirectory: true)



  }







  /// Project-level config directory: `projects/{slug}/config/`



  public func projectConfigDirectoryURL(for projectSlug: String) -> URL {



    baseURL.appendingPathComponent("projects/\(projectSlug)/config", isDirectory: true)



  }







  public func chatDirectoryURL() -> URL {

    baseURL.appendingPathComponent(AppDirectoryNames.chat, isDirectory: true)



  }







  // MARK: - Original imported files







  /// Directory where the original imported file is preserved.



  /// e.g. `items/<uuid>/original/`



  public func originalDirectoryURL(for itemId: UUID) -> URL {

    itemDirectoryURL(for: itemId).appendingPathComponent("original", isDirectory: true)



  }







  /// Preserve an imported file in the item's `original/` subdirectory.



  /// The file keeps its original name and format — future re-extraction,



  /// re-export, or inspection uses this copy rather than the temporary



  /// source URL which disappears after import.



  ///



  /// - Parameters:



  ///   - sourceURL: The file to copy (from Share Extension, document picker, etc.)



  ///   - itemId: The KnowledgeItem this file belongs to



  ///   - originalFileName: The file name to use inside `original/`



  /// - Returns: The destination URL where the file was stored



  @discardableResult



  public func storeImportedFile(sourceURL: URL, itemId: UUID, originalFileName: String) throws -> URL {

    try createMeetingDirectory(for: itemId)



    let originalDir = originalDirectoryURL(for: itemId)



    try fileManager.createDirectory(at: originalDir, withIntermediateDirectories: true)







    var values = URLResourceValues()



    values.isExcludedFromBackup = true



    var mutableDir = originalDir



    try? mutableDir.setResourceValues(values)







    let destURL = originalDir.appendingPathComponent(originalFileName)



    if fileManager.fileExists(atPath: destURL.path) {



      try fileManager.removeItem(at: destURL)



    }



    try fileManager.copyItem(at: sourceURL, to: destURL)







    // Apply backup exclusion to the copied file



    var fileValues = URLResourceValues()



    fileValues.isExcludedFromBackup = true



    var mutableFile = destURL



    try? mutableFile.setResourceValues(fileValues)







    logger.info(



      "Preserved imported file: \(originalFileName) for item \(itemId.uuidString.prefix(8))")



    return destURL



  }







  /// Check whether the original imported file exists for an item.



  public func originalFileExists(for itemId: UUID, fileName: String) -> Bool {

    let url = originalDirectoryURL(for: itemId).appendingPathComponent(fileName)



    guard fileManager.fileExists(atPath: url.path) else { return false }



    let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0



    return size > 0



  }







  // MARK: - Directory creation (public, for services that need explicit guarantees)







  public func createMeetingDirectory(for meetingId: UUID) throws {



    let url = meetingDirectoryURL(for: meetingId)



    do {



      try fileManager.createDirectory(at: url, withIntermediateDirectories: true)



    } catch {



      logger.error(



        "FileArtifactStore: createMeetingDirectory failed — \(url.path): \(error.localizedDescription)"



      )



      throw FileArtifactStoreError.directoryCreationFailed(error)



    }







    // File protection



    do {



      try fileManager.setAttributes(



        [.protectionKey: FileProtectionType.completeUnlessOpen],



        ofItemAtPath: url.path



      )



    } catch {



      logger.error(



        "FileArtifactStore: meeting directory protection failed — \(url.path): \(error.localizedDescription)"



      )



    }







    // Backup exclusion



    do {



      var values = URLResourceValues()



      values.isExcludedFromBackup = true



      var mutableURL = url



      try mutableURL.setResourceValues(values)



    } catch {



      logger.warning(



        "FileArtifactStore: meeting directory backup exclusion failed — \(url.path): \(error.localizedDescription)"



      )



    }



  }







  public func createConfigsDirectory() throws {

    let url = configsDirectoryURL()



    guard !fileManager.fileExists(atPath: url.path) else { return }



    do {



      try fileManager.createDirectory(at: url, withIntermediateDirectories: true)



      try fileManager.setAttributes(



        [.protectionKey: FileProtectionType.completeUnlessOpen],



        ofItemAtPath: url.path



      )



      var values = URLResourceValues()



      values.isExcludedFromBackup = true



      var mutableURL = url



      try mutableURL.setResourceValues(values)



    } catch {



      logger.error(



        "FileArtifactStore: createConfigsDirectory failed — \(error.localizedDescription)")



      throw FileArtifactStoreError.directoryCreationFailed(error)



    }



  }







  public func createChatDirectory() throws {

    let url = chatDirectoryURL()



    guard !fileManager.fileExists(atPath: url.path) else { return }



    do {



      try fileManager.createDirectory(at: url, withIntermediateDirectories: true)



      try fileManager.setAttributes(



        [.protectionKey: FileProtectionType.completeUnlessOpen],



        ofItemAtPath: url.path



      )



      var values = URLResourceValues()



      values.isExcludedFromBackup = true



      var mutableURL = url



      try mutableURL.setResourceValues(values)



    } catch {



      logger.error(



        "FileArtifactStore: createChatDirectory failed — \(error.localizedDescription)")



      throw FileArtifactStoreError.directoryCreationFailed(error)



    }



  }







  public func createMediaDirectory() throws {

    let url = baseURL.appendingPathComponent(AppDirectoryNames.media, isDirectory: true)



    guard !fileManager.fileExists(atPath: url.path) else { return }



    do {



      try fileManager.createDirectory(at: url, withIntermediateDirectories: true)



      var values = URLResourceValues()



      values.isExcludedFromBackup = true



      var mutableURL = url



      try mutableURL.setResourceValues(values)



    } catch {



      logger.error(



        "FileArtifactStore: createMediaDirectory failed — \(error.localizedDescription)")



      throw FileArtifactStoreError.directoryCreationFailed(error)



    }



  }







  public func deleteMeetingDirectory(for meetingId: UUID) throws {

    let url = meetingDirectoryURL(for: meetingId)



    guard fileManager.fileExists(atPath: url.path) else { return }



    do {



      try fileManager.removeItem(at: url)



    } catch {



      logger.error(



        "FileArtifactStore: deleteMeetingDirectory failed — \(url.path): \(error.localizedDescription)"



      )



      throw error



    }



  }







  // MARK: - Audio







  public func audioFileURL(for meetingId: UUID) -> URL {



    meetingDirectoryURL(for: meetingId)



      .appendingPathComponent("audio.m4a")



  }







  public func audioFileExists(for meetingId: UUID) -> Bool {

    let path = audioFileURL(for: meetingId).path



    guard fileManager.fileExists(atPath: path) else { return false }



    let size = (try? fileManager.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0



    return size > 0



  }







  public func copyAudioToMeeting(sourceURL: URL, meetingId: UUID) throws {

    try createMeetingDirectory(for: meetingId)



    let destURL = audioFileURL(for: meetingId)



    if fileManager.fileExists(atPath: destURL.path) {



      try fileManager.removeItem(at: destURL)



    }



    try fileManager.copyItem(at: sourceURL, to: destURL)



  }







  public func deleteAudio(for meetingId: UUID) throws {

    let url = audioFileURL(for: meetingId)



    guard fileManager.fileExists(atPath: url.path) else { return }



    try fileManager.removeItem(at: url)



  }







  // MARK: - Segmented recording







  public func segmentsDirectoryURL(for itemId: UUID) -> URL {



    itemDirectoryURL(for: itemId).appendingPathComponent(AppFileConstants.segmentsDirectoryName)



  }







  public func segmentURL(for itemId: UUID, fileName: String) -> URL {

    segmentsDirectoryURL(for: itemId).appendingPathComponent(fileName)



  }







  public func recordingManifestURL(for itemId: UUID) -> URL {

    itemDirectoryURL(for: itemId).appendingPathComponent(AppFileConstants.manifestFileName)



  }







  // MARK: - Manifest (with backup rotation)







  /// Write the recording manifest using backup rotation: .NEW → validate → rotate.



  /// If the write fails, the previous manifest (and its .BAK) remain intact.



  public func writeRecordingManifest(_ manifest: RecordingManifest, for itemId: UUID) throws {

    try createMeetingDirectory(for: itemId)



    let url = recordingManifestURL(for: itemId)



    let data = try JSONEncoder().encode(manifest)







    // Validate the encoded JSON is deserializable before writing



    guard (try? JSONSerialization.jsonObject(with: data)) != nil else {



      logger.error("FileArtifactStore: manifest JSON validation failed — refusing to write")



      throw FileArtifactStoreError.encodingFailed



    }







    try atomicWriteWithBackup(data: data, url: url)



  }







  /// Read the manifest. Falls back to .BAK if the primary is corrupted.



  public func readRecordingManifest(for itemId: UUID) throws -> RecordingManifest {

    let url = recordingManifestURL(for: itemId)



    let bakURL = url.appendingPathExtension("BAK")







    // Try primary first



    if fileManager.fileExists(atPath: url.path) {



      let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0



      if size > 0, let manifest = try? decodeManifest(from: url) {



        return manifest



      }



      logger.warning(



        "FileArtifactStore: manifest parse failed (size=\(size)) — trying backup")



    }







    // Fall back to backup



    if fileManager.fileExists(atPath: bakURL.path) {



      let size = (try? fileManager.attributesOfItem(atPath: bakURL.path)[.size] as? Int64) ?? 0



      if size > 0, let manifest = try? decodeManifest(from: bakURL) {



        logger.info("FileArtifactStore: recovered manifest from backup")



        // Restore the primary from the backup



        if let bakData = try? Data(contentsOf: bakURL) {



          try? bakData.write(to: url, options: .atomic)



        }



        return manifest



      }



    }







    throw FileArtifactStoreError.readFailed(



      NSError(



        domain: "FileArtifactStore", code: -1,



        userInfo: [NSLocalizedDescriptionKey: "Manifest not found or corrupted for \(itemId)"])



    )



  }







  private func decodeManifest(from url: URL) throws -> RecordingManifest {



    let data = try Data(contentsOf: url)



    return try JSONDecoder().decode(RecordingManifest.self, from: data)



  }







  /// Check for manifest existence AND validity (non-zero file size).



  public func recordingManifestExists(for itemId: UUID) -> Bool {

    let url = recordingManifestURL(for: itemId)



    guard fileManager.fileExists(atPath: url.path) else { return false }



    let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0



    return size >= AppFileConstants.minimumValidFileSize



  }







  /// Structured debug report of all recording artifacts for a meeting.



  /// Logs segment files, sizes, manifest validity, and audio.m4a status.



  /// Used on every Finish until route switching is stable.



  public func debugRecordingArtifacts(meetingId: UUID) -> String {

    var lines: [String] = []



    let itemDir = meetingDirectoryURL(for: meetingId)



    lines.append("  itemId: \(meetingId.uuidString)")



    lines.append("  meetingDir: \(itemDir.path)")



    lines.append("  meetingDirExists: \(fileManager.fileExists(atPath: itemDir.path))")







    // Manifest



    let manifestExists = recordingManifestExists(for: meetingId)



    lines.append("  manifestExists: \(manifestExists)")







    var totalValidBytes: Int64 = 0



    var validSegmentCount = 0



    var segmentCount = 0







    if manifestExists, let manifest = try? readRecordingManifest(for: meetingId) {



      segmentCount = manifest.segments.count



      lines.append("  segmentCount: \(segmentCount)")



      for seg in manifest.segments {



        let url = segmentURL(for: meetingId, fileName: seg.fileName)



        let exists = fileManager.fileExists(atPath: url.path)



        let size: Int64 =



          exists ? (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0 : 0



        let marker = size > 0 ? "✓" : "✗"



        lines.append(



          "    \(seg.fileName): \(size) bytes \(marker) (endedAt=\(seg.endedAt?.description ?? "nil"))"



        )



        if size > 0 {



          validSegmentCount += 1



          totalValidBytes += size



        }



      }



      lines.append("  validSegmentCount: \(validSegmentCount)")



      lines.append("  totalValidSegmentBytes: \(totalValidBytes)")



    }







    // Single audio file



    let audioM4AURL = meetingDirectoryURL(for: meetingId).appendingPathComponent(



      AppFileConstants.audioFileName)



    let audioM4AExists = fileManager.fileExists(atPath: audioM4AURL.path)



    let audioM4ASize: Int64 =



      audioM4AExists



      ? (try? fileManager.attributesOfItem(atPath: audioM4AURL.path)[.size] as? Int64) ?? 0 : 0



    lines.append("  audioM4AExists: \(audioM4AExists)")



    lines.append("  audioM4ASize: \(audioM4ASize)")







    // Pipeline input decision



    let pipelineInput: String



    if audioM4AExists && audioM4ASize > 0 {



      pipelineInput = "audio.m4a"



    } else if validSegmentCount > 0 {



      pipelineInput = "manifest (\(validSegmentCount) valid segments)"



    } else {



      pipelineInput = "none — no valid audio"



    }



    lines.append("  pipelineInput: \(pipelineInput)")







    return lines.joined(separator: "\n")



  }







  // MARK: - Artifacts







  public func writeArtifact<T: Encodable>(_ value: T, fileName: String, meetingId: UUID) throws {



    try createMeetingDirectory(for: meetingId)



    let url = meetingDirectoryURL(for: meetingId).appendingPathComponent(fileName)



    do {



      let data = try JSONEncoder().encode(value)



      try data.write(to: url, options: .atomic)



      // Apply backup exclusion to the written file



      var values = URLResourceValues()



      values.isExcludedFromBackup = true



      var mutableURL = url



      try? mutableURL.setResourceValues(values)



    } catch is EncodingError {



      throw FileArtifactStoreError.encodingFailed



    } catch {



      logger.error(



        "FileArtifactStore: writeArtifact failed — \(fileName): \(error.localizedDescription)")



      throw FileArtifactStoreError.writeFailed(error)



    }



  }







  public func readArtifact<T: Decodable>(_ type: T.Type, fileName: String, meetingId: UUID) throws



    -> T



  {



    let url = meetingDirectoryURL(for: meetingId).appendingPathComponent(fileName)



    guard fileManager.fileExists(atPath: url.path) else {



      throw FileArtifactStoreError.fileNotFound



    }



    do {



      let data = try Data(contentsOf: url)



      return try JSONDecoder().decode(T.self, from: data)



    } catch {



      throw FileArtifactStoreError.readFailed(error)



    }



  }







  public func artifactExists(fileName: String, meetingId: UUID) -> Bool {

    let url = meetingDirectoryURL(for: meetingId).appendingPathComponent(fileName)



    guard fileManager.fileExists(atPath: url.path) else { return false }



    let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0



    return size > 0



  }







  // MARK: - Atomic write with backup (for critical JSON files)







  /// Write data atomically with backup rotation. Workflow:



  /// 1. Write to `<url>.NEW`



  /// 2. Validate the new file is deserializable JSON



  /// 3. Rename original → `<url>.BAK`



  /// 4. Rename `<url>.NEW` → `<url>`



  ///



  /// If any step fails, the original file is untouched.



  /// Callers must ensure the parent directory exists before calling.



  public func atomicWriteWithBackup(data: Data, url: URL) throws {



    let newURL = url.appendingPathExtension("NEW")



    let bakURL = url.appendingPathExtension("BAK")







    // 1. Write to .NEW



    do {



      try data.write(to: newURL, options: .atomic)



    } catch {



      logger.error(



        "FileArtifactStore: atomicWriteWithBackup .NEW write failed — \(url.path): \(error.localizedDescription)"



      )



      throw FileArtifactStoreError.writeFailed(error)



    }







    // Apply backup exclusion



    var values = URLResourceValues()



    values.isExcludedFromBackup = true



    var mutableNewURL = newURL



    try? mutableNewURL.setResourceValues(values)







    // 2. Rotate: remove old .BAK, rename current → .BAK



    try? fileManager.removeItem(at: bakURL)



    if fileManager.fileExists(atPath: url.path) {



      do {



        try fileManager.moveItem(at: url, to: bakURL)



      } catch {



        logger.error(



          "FileArtifactStore: atomicWriteWithBackup .BAK rotation failed — \(error.localizedDescription)"



        )



        try? fileManager.removeItem(at: newURL)



        throw FileArtifactStoreError.writeFailed(error)



      }



    }







    // 3. Rename .NEW → final



    do {



      try fileManager.moveItem(at: newURL, to: url)



    } catch {



      // Attempt to restore from .BAK



      logger.error(



        "FileArtifactStore: atomicWriteWithBackup rename .NEW→final failed — \(error.localizedDescription)"



      )



      if fileManager.fileExists(atPath: bakURL.path) {



        try? fileManager.moveItem(at: bakURL, to: url)



      }



      try? fileManager.removeItem(at: newURL)



      throw FileArtifactStoreError.writeFailed(error)



    }







    // Apply backup exclusion to final file



    var finalValues = URLResourceValues()



    finalValues.isExcludedFromBackup = true



    var mutableURL = url



    try? mutableURL.setResourceValues(finalValues)



  }







  // MARK: - Partial transcript (checkpointing)







  private func partialTranscriptURL(for meetingId: UUID) -> URL {



    meetingDirectoryURL(for: meetingId).appendingPathComponent(



      AppFileConstants.partialTranscriptFileName)



  }







  private func partialCheckpointURL(for meetingId: UUID) -> URL {



    meetingDirectoryURL(for: meetingId).appendingPathComponent(AppFileConstants.checkpointFileName)



  }







  public func writePartialTranscript(

    _ transcript: Transcript, checkpoint: TranscriptionCheckpoint, meetingId: UUID



  ) throws {



    try createMeetingDirectory(for: meetingId)







    let tURL = partialTranscriptURL(for: meetingId)



    let tData = try JSONEncoder().encode(transcript)



    try tData.write(to: tURL, options: .atomic)







    let cURL = partialCheckpointURL(for: meetingId)



    let cData = try JSONEncoder().encode(checkpoint)



    try cData.write(to: cURL, options: .atomic)



  }







  public func readPartialCheckpoint(meetingId: UUID) throws -> TranscriptionCheckpoint? {

    let url = partialCheckpointURL(for: meetingId)



    guard fileManager.fileExists(atPath: url.path) else { return nil }



    let data = try Data(contentsOf: url)



    return try JSONDecoder().decode(TranscriptionCheckpoint.self, from: data)



  }







  public func readPartialTranscript(meetingId: UUID) throws -> Transcript? {

    let url = partialTranscriptURL(for: meetingId)



    guard fileManager.fileExists(atPath: url.path) else { return nil }



    let data = try Data(contentsOf: url)



    return try JSONDecoder().decode(Transcript.self, from: data)



  }







  public func commitPartialTranscript(meetingId: UUID) throws {

    let partialURL = partialTranscriptURL(for: meetingId)



    let finalURL = meetingDirectoryURL(for: meetingId).appendingPathComponent(



      AppFileConstants.transcriptFileName)



    guard fileManager.fileExists(atPath: partialURL.path) else { return }







    // Remove previous final transcript safely



    if fileManager.fileExists(atPath: finalURL.path) {



      do {



        try fileManager.removeItem(at: finalURL)



      } catch {



        logger.error(



          "FileArtifactStore: commitPartialTranscript — cannot remove old final transcript: \(error.localizedDescription)"



        )



        throw error



      }



    }







    try fileManager.moveItem(at: partialURL, to: finalURL)



    try? fileManager.removeItem(at: partialCheckpointURL(for: meetingId))



  }







  public func deletePartialTranscript(meetingId: UUID) {

    let pURL = partialTranscriptURL(for: meetingId)



    if fileManager.fileExists(atPath: pURL.path) {



      do {



        try fileManager.removeItem(at: pURL)



      } catch {



        logger.error(



          "FileArtifactStore: deletePartialTranscript failed — \(pURL.path): \(error.localizedDescription)"



        )



      }



    }



    let cURL = partialCheckpointURL(for: meetingId)



    if fileManager.fileExists(atPath: cURL.path) {



      do {



        try fileManager.removeItem(at: cURL)



      } catch {



        logger.error(



          "FileArtifactStore: deletePartialCheckpoint failed — \(cURL.path): \(error.localizedDescription)"



        )



      }



    }



  }







  // MARK: - Sweep (orphan detection)







  /// Scan the `items/` directory and return UUIDs of directories that have no



  /// corresponding record in the provided set of known item IDs.



  /// Callers should log, report to the user, and optionally clean up.



  public func findOrphanedItemDirectories(knownItemIDs: Set<UUID>) -> [UUID] {

    let itemsDir = baseURL.appendingPathComponent(AppDirectoryNames.items, isDirectory: true)



    guard fileManager.fileExists(atPath: itemsDir.path),



      let contents = try? fileManager.contentsOfDirectory(



        at: itemsDir, includingPropertiesForKeys: nil)



    else {



      return []



    }



    return contents.compactMap { url in



      guard let uuid = UUID(uuidString: url.lastPathComponent) else { return nil }



      return knownItemIDs.contains(uuid) ? nil : uuid



    }



  }







  /// Remove orphaned item directories and return the count of removed directories



  /// and total bytes freed.



  public func removeOrphanedDirectories(orphanedIDs: [UUID]) -> (count: Int, bytesFreed: Int64) {

    var removed = 0



    var totalBytes: Int64 = 0



    for id in orphanedIDs {



      let url = itemDirectoryURL(for: id)



      if fileManager.fileExists(atPath: url.path) {



        // Calculate size before removing



        if let size = directorySize(url: url) {



          totalBytes += size



        }



        do {



          try fileManager.removeItem(at: url)



          removed += 1



          logger.info("Swept orphaned directory: \(id.uuidString) (\(totalBytes) bytes)")



        } catch {



          logger.error(



            "Sweep failed to remove orphan: \(id.uuidString) — \(error.localizedDescription)")



        }



      }



    }



    return (removed, totalBytes)



  }







  /// Calculate total size of a directory (recursive).



  public func directorySize(url: URL) -> Int64? {

    guard



      let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])



    else {



      return nil



    }



    var total: Int64 = 0



    for case let fileURL as URL in enumerator {



      let size =



        (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0



      total += size



    }



    return total



  }







  // MARK: - Export







  public func exportsDirectoryURL(for meetingId: UUID) -> URL {

    meetingDirectoryURL(for: meetingId)



      .appendingPathComponent(AppDirectoryNames.exports, isDirectory: true)



  }







  public func createExportsDirectory(for meetingId: UUID) throws {

    let url = exportsDirectoryURL(for: meetingId)



    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)



    var values = URLResourceValues()



    values.isExcludedFromBackup = true



    var mutableURL = url



    try mutableURL.setResourceValues(values)



  }



}







// MARK: - Recording Segment Model







/// One physical audio segment within a logical recording session.



public struct RecordingSegment: Codable, Identifiable, Sendable {



  public let id: UUID

  public let index: Int

  public let fileName: String  // e.g. "segment-000.wav" (no directory prefix)



  public let startedAt: Date

  public var endedAt: Date?

  public let inputPortName: String

  public let inputPortType: String

  public let routeChangeReason: String

  public var sampleRate: Double?

  public var fileSize: Int64?

}







/// Tracks all segments of a recording session.



public struct RecordingManifest: Codable, Sendable {



  public let recordingId: UUID

  public let title: String

  public let startedAt: Date

  public var endedAt: Date?

  public var segments: [RecordingSegment]





  public var totalDuration: TimeInterval {

    segments.compactMap { seg in



      guard let end = seg.endedAt else { return nil }



      return end.timeIntervalSince(seg.startedAt)



    }.reduce(0, +)



  }



}
