import SwiftUI

/// Routes a VFSNode to the appropriate editor view based on file type.
@MainActor
enum FileEditorRouter {

    @ViewBuilder
    @MainActor
    static func editorView(for node: VFSNode, viewModel: FileBrowserViewModel) -> some View {
        switch node.nodeType {
        case .markdownFile:
            MarkdownEditorView(node: node, viewModel: viewModel)
        case .jsonFile:
            JSONEditorView(node: node, viewModel: viewModel)
        case .projectFile:
            JSONEditorView(node: node, viewModel: viewModel) // project.json is JSON
        case .audioFile:
            audioPlayerView(node: node, viewModel: viewModel)
        case .imageFile:
            ImageFileView(node: node, viewModel: viewModel)
        case .directory:
            FileBrowserView(initialPath: node.path)
        case .unknown:
            textEditorFallback(node: node, viewModel: viewModel)
        }
    }

    // MARK: - Audio Player (real)

    @ViewBuilder
    private static func audioPlayerView(node: VFSNode, viewModel: FileBrowserViewModel) -> some View {
        if let audioURL = viewModel.resolveAudioURL(for: node.path) {
            AudioPlayerView(
                audioURL: audioURL,
                title: node.name.replacingOccurrences(of: ".m4a", with: "").replacingOccurrences(of: ".mp3", with: "").replacingOccurrences(of: ".wav", with: "")
            )
            .padding()
            .navigationTitle(node.name)
        } else {
            VStack(spacing: 16) {
                Image(systemName: "waveform")
                    .font(.system(size: 48)).foregroundStyle(.purple)
                Text(node.name).font(.headline)
                Text("Audio file not found on disk.").font(.subheadline).foregroundStyle(.secondary)
            }
            .navigationTitle(node.name)
        }
    }

    // MARK: - Image placeholder

    @ViewBuilder
    private static func imagePlaceholder(node: VFSNode) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.fill")
                .font(.system(size: 48)).foregroundStyle(.pink)
            Text(node.name)
                .font(.headline)
            Text("Image viewer coming soon")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .navigationTitle(node.name)
    }

    @ViewBuilder
    private static func textEditorFallback(node: VFSNode, viewModel: FileBrowserViewModel) -> some View {
        // For unknown file types, try to read and edit as plain text
        let content = viewModel.readFileContent(node.path) ?? ""
        PlainTextEditorView(
            node: node,
            initialContent: content,
            onSave: { newContent in
                _ = viewModel.writeFileContent(node.path, content: newContent)
            }
        )
    }
}

/// Fallback plain text editor for unknown file types.
struct PlainTextEditorView: View {
    let node: VFSNode
    let initialContent: String
    let onSave: (String) -> Void

    @State private var content: String
    @State private var hasChanges = false
    @Environment(\.dismiss) private var dismiss

    init(node: VFSNode, initialContent: String, onSave: @escaping (String) -> Void) {
        self.node = node
        self.initialContent = initialContent
        self.onSave = onSave
        _content = State(initialValue: initialContent)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $content)
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .onChange(of: content) { _, _ in
                    hasChanges = content != initialContent
                }
        }
        .navigationTitle(node.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if hasChanges {
                    Button("Save") {
                        onSave(content)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - Image File Viewer

struct ImageFileView: View {
    let node: VFSNode
    let viewModel: FileBrowserViewModel

    @State private var image: UIImage?
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0

    var body: some View {
        Group {
            if let image {
                ZoomableImageView(image: image)
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Loading image...").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(node.name)
        .onAppear { loadImage() }
    }

    private func loadImage() {
        // Extract item UUID from path like /projects/{slug}/items/{uuid}/scan_0.jpg
        let parts = node.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        for part in parts {
            let clean = VFSService.stripJSONSuffix(part)
            if let id = UUID(uuidString: clean) {
                let dir = FileArtifactStore().itemDirectoryURL(for: id)
                let filename = parts.last ?? node.name
                let url = dir.appendingPathComponent(filename)
                if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
                    image = img
                    return
                }
                // Try scan_0.jpg as fallback
                let scanURL = dir.appendingPathComponent("scan_0.jpg")
                if let data = try? Data(contentsOf: scanURL), let img = UIImage(data: data) {
                    image = img
                    return
                }
            }
        }
    }
}

/// Simple pinch-to-zoom image view.
struct ZoomableImageView: View {
    let image: UIImage
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastScale: CGFloat = 1.0
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            Image(uiImage: image)
                .resizable().scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnificationGesture()
                        .onChanged { v in scale = lastScale * v }
                        .onEnded { _ in lastScale = scale; if scale < 1 { scale = 1; lastScale = 1; offset = .zero } }
                )
                .gesture(
                    DragGesture()
                        .onChanged { v in offset = CGSize(width: lastOffset.width + v.translation.width, height: lastOffset.height + v.translation.height) }
                        .onEnded { _ in lastOffset = offset }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
        }
        .onTapGesture(count: 2) {
            withAnimation { scale = 1.0; lastScale = 1.0; offset = .zero; lastOffset = .zero }
        }
    }
}
