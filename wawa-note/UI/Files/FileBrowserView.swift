import SwiftData
import SwiftUI

/// Finder-like file browser for navigating the virtual filesystem.
/// Used as a tab within the Explore section.
struct FileBrowserView: View {
    let initialPath: String

    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel: FileBrowserViewModel
    @State private var sortOrder: FileSortOrder = .name
    @State private var showDeleteConfirmation = false
    @State private var nodeToDelete: VFSNode?
    @State private var navigateToEditor: VFSNode?
    @State private var navigateToChildPath: String?
    @State private var selectedNode: VFSNode?
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var nodeToRename: VFSNode?
    @State private var showExported = false
    @State private var exportedText = ""

    init(initialPath: String = "/") {
        self.initialPath = initialPath
        _viewModel = StateObject(wrappedValue: FileBrowserViewModel())
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Navigation bar: back/forward/parent + path breadcrumbs
            navigationBar

            Divider()

            // Sort bar
            sortBar

            Divider()

            // File list or empty state
            if viewModel.isLoading && viewModel.nodes.isEmpty {
                loadingView
            } else if viewModel.nodes.isEmpty {
                emptyView
            } else {
                fileList
            }
        }
        .navigationTitle(viewModel.currentName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(FileSortOrder.allCases, id: \.self) { order in
                        Button {
                            sortOrder = order
                        } label: {
                            Label(order.rawValue, systemImage: sortOrder == order ? "checkmark" : "circle")
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
        }
        .onAppear {
            viewModel.configure(modelContext: modelContext)
            if viewModel.currentPath == "/" && initialPath != "/" {
                viewModel.navigate(to: initialPath)
            } else {
                viewModel.refresh()
            }
        }
        .alert("Delete \"\(nodeToDelete?.name ?? "")\"?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let node = nodeToDelete {
                    viewModel.delete(node)
                }
            }
        } message: {
            Text("This action cannot be undone. Items are moved to trash; some deletions are permanent.")
        }
        .alert("Rename", isPresented: $showRenameAlert) {
            TextField("Name", text: $renameText)
            Button("OK") {
                if let node = nodeToRename, !renameText.isEmpty {
                    viewModel.rename(node, to: renameText)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showExported) {
            NavigationStack {
                ScrollView {
                    Text(exportedText.isEmpty ? "No content to export." : exportedText)
                        .font(.system(.caption, design: .monospaced))
                        .padding()
                }
                .navigationTitle("Export")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showExported = false }
                    }
                }
            }
        }
        .navigationDestination(item: $navigateToChildPath) { path in
            FileBrowserView(initialPath: path)
        }
        .navigationDestination(item: $navigateToEditor) { node in
            FileEditorRouter.editorView(for: node, viewModel: viewModel)
        }
    }

    // MARK: - Navigation Bar

    private var navigationBar: some View {
        VStack(spacing: 0) {
            // Back / Forward / Parent
            HStack(spacing: 2) {
                Button {
                    viewModel.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body).fontWeight(.medium)
                        .frame(width: 32, height: 32)
                }
                .disabled(!viewModel.canGoBack)
                .buttonStyle(.plain)
                .opacity(viewModel.canGoBack ? 1 : 0.3)

                Button {
                    viewModel.goForward()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.body).fontWeight(.medium)
                        .frame(width: 32, height: 32)
                }
                .disabled(!viewModel.canGoForward)
                .buttonStyle(.plain)
                .opacity(viewModel.canGoForward ? 1 : 0.3)

                Button {
                    viewModel.goToParent()
                } label: {
                    Image(systemName: "arrow.up.circle")
                        .font(.body).fontWeight(.medium)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .opacity(viewModel.currentPath == "/" ? 0.3 : 1)
                .disabled(viewModel.currentPath == "/")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)

            // Breadcrumbs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(viewModel.breadcrumbSegments(), id: \.path) { segment in
                        if segment.path != "/" {
                            Image(systemName: "chevron.right")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Button {
                            viewModel.navigate(to: segment.path)
                        } label: {
                            Text(segment.name)
                                .font(.caption).fontWeight(segment.path == viewModel.currentPath ? .semibold : .regular)
                                .foregroundStyle(segment.path == viewModel.currentPath ? .primary : .secondary)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - Sort Bar

    private var sortBar: some View {
        HStack(spacing: 16) {
            Text("\(viewModel.nodes.count) item\(viewModel.nodes.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            ForEach(FileSortOrder.allCases, id: \.self) { order in
                Button {
                    sortOrder = order
                } label: {
                    Text(order.rawValue)
                        .font(.caption2).fontWeight(sortOrder == order ? .semibold : .regular)
                        .foregroundStyle(sortOrder == order ? .primary : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - File List

    private var fileList: some View {
        List {
            ForEach(viewModel.sortedNodes(by: sortOrder)) { node in
                Group {
                    if node.isDirectory {
                        FileRowView(
                            node: node,
                            onOpen: { navigateToChildPath = node.path },
                            onEdit: nil,
                            onDelete: { confirmDelete(node) },
                            onRename: { newName in viewModel.rename(node, to: newName) },
                            onMove: nil,
                            onDuplicate: { duplicateNode(node) },
                            onExport: { exportNode(node) },
                            onInfo: { selectedNode = node }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { navigateToChildPath = node.path }
                    } else {
                        FileRowView(
                            node: node,
                            onOpen: { navigateToEditor = node },
                            onEdit: { navigateToEditor = node },
                            onDelete: { confirmDelete(node) },
                            onRename: { newName in viewModel.rename(node, to: newName) },
                            onMove: nil,
                            onDuplicate: { duplicateNode(node) },
                            onExport: { exportNode(node) },
                            onInfo: { selectedNode = node }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { navigateToEditor = node }
                    }
                }
                .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 12))
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Empty State

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder")
                .font(.system(size: 48)).foregroundStyle(.tertiary)
            Text("Empty Folder")
                .font(.headline)
            Text("No files or folders at this location.")
                .font(.subheadline).foregroundStyle(.secondary)
            if viewModel.currentPath == "/projects" {
                Text("Create a project to get started.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 80)
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading...")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 80)
    }

    // MARK: - Helpers

    private func setupViewModel() {
        // Replace the dummy viewModel with one that has proper context
        // The StateObject init above handles this; this is for late binding
    }

    private func confirmDelete(_ node: VFSNode) {
        nodeToDelete = node
        showDeleteConfirmation = true
    }

    private func startRename(_ node: VFSNode) {
        nodeToRename = node
        renameText = node.name
        showRenameAlert = true
    }

    private func duplicateNode(_ node: VFSNode) {
        guard let content = viewModel.readFileContent(node.path) else { return }
        let newName = "copy-\(node.name)"
        let parentPath = node.path.split(separator: "/").dropLast().joined(separator: "/")
        let newPath = "/\(parentPath)/\(newName)"
        _ = viewModel.writeFileContent(newPath, content: content)
    }

    private func exportNode(_ node: VFSNode) {
        exportedText = viewModel.readFileContent(node.path) ?? "No content"
        showExported = true
    }
}
