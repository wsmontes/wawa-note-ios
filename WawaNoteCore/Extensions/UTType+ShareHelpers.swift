// WawaNoteCore/Extensions/UTType+ShareHelpers.swift
import UniformTypeIdentifiers

extension UTType {
  /// Types supported by the Share Extension, in detection priority order.
  public static let shareableTypes: [UTType] = [
    .audio,
    .movie,
    .image,
    .fileURL,
    .data,
    .url,
    .plainText,
  ]

  /// Maps a UTType to the corresponding KnowledgeItemType.
  var knowledgeItemType: KnowledgeItemType? {
    if conforms(to: .audio) { return .audio }
    if conforms(to: .movie) { return .audio }  // movies treated as audio items (transcription)
    if conforms(to: .image) { return .image }
    // fileURL checked BEFORE url because UTType.fileURL conforms to UTType.url
    if conforms(to: .fileURL) || conforms(to: .data) || conforms(to: .content) {
      // Generic file — needs ImportRouter to determine specific type
      return nil
    }
    if conforms(to: .url) { return .webBookmark }
    if conforms(to: .plainText) { return .note }
    return nil
  }
}
