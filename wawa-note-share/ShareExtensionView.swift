import SwiftUI
import WawaNoteCore

struct ShareExtensionView: View {
  @ObservedObject var viewModel: ShareExtensionViewModel

  var body: some View {
    NavigationStack {
      Group {
        switch viewModel.state {
        case .loading:
          loadingView
        case .importing(let fileName, let progress):
          importingView(fileName: fileName, progress: progress)
        case .done(let count):
          doneView(count: count)
        case .error(let message):
          errorView(message: message)
        }
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { viewModel.cancel() }
        }
      }
    }
    .task {
      await viewModel.loadItems()
    }
  }

  // MARK: - Loading

  private var loadingView: some View {
    VStack(spacing: 16) {
      ProgressView()
        .scaleEffect(1.2)
      Text("Preparing...")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Importing

  private func importingView(fileName: String, progress: String) -> some View {
    VStack(spacing: 20) {
      Spacer()

      Image(systemName: "arrow.down.doc")
        .font(.system(size: 48))
        .foregroundStyle(.blue)

      Text(fileName)
        .font(.headline)
        .lineLimit(2)
        .multilineTextAlignment(.center)

      if !progress.isEmpty {
        Text(progress)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 12) {
        ProgressView()
          .scaleEffect(0.8)
        Text("Importing...")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      Spacer()
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Done

  private func doneView(count: Int) -> some View {
    VStack(spacing: 20) {
      Spacer()

      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 56))
        .foregroundStyle(.green)

      Text("Imported!")
        .font(.title2.bold())

      Text("Open Wawa Note to process and analyze")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      Spacer()
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Error

  private func errorView(message: String) -> some View {
    VStack(spacing: 20) {
      Spacer()

      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 48))
        .foregroundStyle(.orange)

      Text("Import Failed")
        .font(.title2.bold())

      Text(message)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal)

      Text("Supported formats: audio, images, video, documents, URLs, and text")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
        .padding(.horizontal)

      Button("Dismiss") {
        viewModel.dismissAfterError()
      }
      .buttonStyle(.bordered)

      Spacer()
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
