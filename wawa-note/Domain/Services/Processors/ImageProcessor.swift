import Foundation
import SwiftData
import UIKit
import Vision
import WawaNoteCore

// Related JIRA: KAN-XX

/// Extracts text from images via OCR + LLM Vision.
final class ImageProcessor: ContentProcessor {

  private let fileStore: FileArtifactStore

  init(fileStore: FileArtifactStore = FileArtifactStore()) {
    self.fileStore = fileStore
  }

  func extract(from item: KnowledgeItem, context: ModelContext) async -> String? {
    guard !Task.isCancelled else {
      fail(item, context: context, error: ExtractionError.taskCancelled)
      return nil
    }

    guard let relativePath = item.imageFileRelativePath else {
      fail(item, context: context, error: ExtractionError.imageUnreadable)
      return nil
    }

    let sandboxURL = fileStore.itemDirectoryURL(for: item.id).appendingPathComponent(relativePath)
    let sharedURL = fileStore.sharedImageURL(for: item.id, relativePath: relativePath)
    let imageURL: URL
    if FileManager.default.fileExists(atPath: sandboxURL.path) {
      imageURL = sandboxURL
    } else if FileManager.default.fileExists(atPath: sharedURL.path) {
      imageURL = sharedURL
    } else {
      fail(item, context: context, error: ExtractionError.imageUnreadable)
      return nil
    }

    guard let imageData = try? Data(contentsOf: imageURL),
      let image = UIImage(data: imageData),
      let cgImage = image.cgImage
    else {
      fail(item, context: context, error: ExtractionError.imageUnreadable)
      return nil
    }

    // Phase 1: Apple OCR
    let ocrText: String? = await withCheckedContinuation { continuation in
      let request = VNRecognizeTextRequest { request, _ in
        let text = (request.results as? [VNRecognizedTextObservation] ?? [])
          .compactMap { $0.topCandidates(1).first?.string }
          .joined(separator: "\n")
        continuation.resume(returning: text.isEmpty ? nil : text)
      }
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true
      try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
    }

    // Phase 2: LLM Vision
    var visualDescription = ""
    if let provider = try? ProviderRouter.resolveActive(context: context) {
      let model = AIConfigService.shared.modelFor(feature: "vision")
      let params = AIConfigService.shared.requestParams(for: "vision", model: model)
      let request = AIRequest(
        model: model,
        messages: [
          AIMessage(
            role: .system,
            content: [
              .text(
                "You are a document image analyst. Describe what you see — document type, layout, visual elements, handwriting, diagrams. Be concise but thorough."
              )
            ]),
          AIMessage(
            role: .user,
            content: [
              .text("Analyze this document image."),
              .imageFile(imageURL),
            ]),
        ],
        temperature: params.temperature,
        maxTokens: min(params.maxTokens ?? 4096, 2048)
      )
      if let response = try? await provider.send(request) {
        visualDescription = response.content.trimmingCharacters(
          in: CharacterSet.whitespacesAndNewlines)
      }
    }

    // Combine results
    var parts: [String] = []
    if let ocr = ocrText, !ocr.isEmpty { parts.append("OCR TEXT:\n\(ocr)") }
    if !visualDescription.isEmpty { parts.append("VISUAL ANALYSIS:\n\(visualDescription)") }

    guard !parts.isEmpty else {
      fail(item, context: context, error: ExtractionError.imageNoContent)
      return nil
    }

    let combined = parts.joined(separator: "\n\n---\n\n")
    item.bodyText = combined
    context.safeSave(context: "image-extraction-success", itemId: item.id)
    return combined
  }

  private func fail(_ item: KnowledgeItem, context: ModelContext, error: ExtractionError) {
    item.status = .failed
    item.lastErrorRaw = error.errorDescription
    context.safeSave(context: "image-extraction-failed", itemId: item.id)
  }
}
