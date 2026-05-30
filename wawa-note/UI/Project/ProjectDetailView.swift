import SwiftUI
import SwiftData

struct ProjectDetailView: View {
    let project: Project

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \KnowledgeItem.updatedAt, order: .reverse) private var allItems: [KnowledgeItem]

    @State private var tasks: [TaskItem] = []
    @State private var projectItems: [KnowledgeItem] = []
    @State private var selectedTab = 0
    @ObservedObject private var ingestionState = ProjectIngestionState.shared

    var body: some View {
        VStack(spacing: 0) {
            // Project header
            headerSection

            // Tab picker
            Picker("View", selection: $selectedTab) {
                Text("Tasks").tag(0)
                Text("Items").tag(1)
                Text("Graph").tag(2)
                Text("Timeline").tag(3)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // Content — segmented switch, no page swipe
            switch selectedTab {
            case 0:
                ProjectTaskBoardView(tasks: tasks, projectID: project.id)
            case 1:
                projectItemsList
            case 2:
                ProjectGraphView(projectID: project.id)
            case 3:
                ProjectTimelineView(projectID: project.id)
            default:
                EmptyView()
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(project.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    Menu {
                        Button { selectedTab = 0 } label: { Label("Tasks", systemImage: "checklist") }
                        Button { selectedTab = 1 } label: { Label("Items", systemImage: "doc.text") }
                        Button { selectedTab = 2 } label: { Label("Graph", systemImage: "circle.hexagonpath") }
                        Button { selectedTab = 3 } label: { Label("Timeline", systemImage: "clock") }
                    } label: {
                        Label("View", systemImage: "ellipsis.circle")
                    }

                    Menu {
                        Button {
                            exportProject()
                        } label: {
                            Label("Export Markdown", systemImage: "doc.richtext")
                        }
                        Button {
                            Task { await exportTasksToReminders() }
                        } label: {
                            Label("Send Tasks to Reminders", systemImage: "checklist")
                        }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .task { loadData() }
        .onChange(of: ingestionState.activeProjectIDs) { _, newValue in
            if !newValue.contains(project.id) {
                loadData()
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: project.iconName ?? "folder.fill")
                    .font(.title)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.title3)
                        .fontWeight(.semibold)
                    if let summary = project.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text(project.status.rawValue.capitalized)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(project.status == .active ? Color.blue.opacity(0.15) : Color.gray.opacity(0.15))
                    .clipShape(Capsule())
            }

            HStack(spacing: 24) {
                statLabel("\(tasks.count)", "Tasks")
                statLabel("\(tasks.filter { $0.status == .done }.count)", "Done")
                statLabel("\(projectItems.count)", "Items")
            }

            if ingestionState.activeProjectIDs.contains(project.id) {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Analyzing new item...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(16)
        .background(Color(.systemBackground))
    }

    private func statLabel(_ value: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.headline)
                .fontWeight(.bold)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Items list

    private var projectItemsList: some View {
        Group {
            if projectItems.isEmpty {
                VStack(spacing: 12) {
                    Spacer().frame(height: 40)
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.title).foregroundStyle(.secondary)
                    Text("No items in this project")
                        .font(.headline)
                    Text("Promote a meeting or add items from the library.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 40)
                }
            } else {
                List {
                    ForEach(projectItems) { item in
                        NavigationLink {
                            KnowledgeDetailView(item: item)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: item.type.icon)
                                    .font(.title3).foregroundStyle(item.type.color)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title.isEmpty ? "Untitled" : item.title)
                                        .font(.subheadline).foregroundStyle(.primary)
                                    HStack(spacing: 6) {
                                        Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption).foregroundStyle(.secondary)
                                        if item.inboxDate != nil {
                                            Text("·").font(.caption).foregroundStyle(.secondary)
                                            Text("Unprocessed").font(.caption2).foregroundStyle(.orange)
                                        }
                                        if item.analysisProviderId != nil {
                                            Text("·").font(.caption).foregroundStyle(.secondary)
                                            Text("Analyzed").font(.caption2).foregroundStyle(.indigo)
                                        }
                                    }
                                }
                            }
                        }
                        .swipeActions(edge: .leading) {
                            if item.inboxDate != nil {
                                Button {
                                    let svc = KnowledgeItemService(context: modelContext)
                                    try? svc.removeFromInbox(item)
                                    loadData()
                                } label: {
                                    Label("Mark Reviewed", systemImage: "checkmark.circle")
                                }.tint(.green)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                try? ProjectService(context: modelContext).removeItem(item.id)
                                loadData()
                            } label: {
                                Label("Remove", systemImage: "folder.badge.minus")
                            }.tint(.orange)
                            Button(role: .destructive) {
                                let trash = TrashService(context: modelContext)
                                try? trash.moveToTrash(item)
                                loadData()
                            } label: {
                                Label("Trash", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
    }

    // MARK: - Data

    private func loadData() {
        let taskSvc = TaskService(context: modelContext)
        tasks = (try? taskSvc.tasks(for: project.id)) ?? []

        let projSvc = ProjectService(context: modelContext)
        projectItems = (try? projSvc.items(in: project.id)) ?? []
    }

    // MARK: - Export

    private func exportProject() {
        let exporter = ProjectExportService()
        let svc = GraphEdgeService(context: modelContext)
        let allEdges = (try? svc.neighborhood(of: project.id, radius: 2)) ?? []

        let markdown = exporter.exportMarkdown(project: project, items: projectItems, tasks: tasks, edges: allEdges)
        let activityVC = UIActivityViewController(activityItems: [markdown], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = windowScene.windows.first?.rootViewController {
            root.present(activityVC, animated: true)
        }
    }

    private func exportTasksToReminders() async {
        let tasksToExport = tasks
        let service = TaskRemindersService()
        _ = await service.exportTasks(tasksToExport)
    }
}
