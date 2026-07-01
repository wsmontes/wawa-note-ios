import SwiftData
import SwiftUI
import WawaNoteCore

// MARK: - DEPRECATED: Subsumed by file browser with type filter (2026-06-18)
struct EntitySummary: Identifiable {
  let id = UUID()
  let name: String
  let kind: String
  let mentionCount: Int
  let sourceItems: [String]
}

struct ProjectEntitiesView: View {
  let projectID: UUID
  @Environment(\.modelContext) private var modelContext
  @State private var entities: [EntitySummary] = []
  @State private var selectedKind: String?
  @State private var isLoading = true

  private var kinds: [String] {
    Array(Set(entities.map(\.kind))).sorted()
  }

  private var filteredEntities: [EntitySummary] {
    guard let kind = selectedKind else { return entities }
    return entities.filter { $0.kind == kind }
  }

  var body: some View {
    VStack(spacing: 0) {
      if isLoading {
        Spacer()
        ProgressView("Loading entities...")
        Spacer()
      } else if entities.isEmpty {
        Spacer()
        VStack(spacing: AppSpacing.md) {
          Image(systemName: "cube").font(.title).foregroundStyle(.secondary)
          Text("No entities identified").font(.headline)
          Text("Entities like organizations, systems, and locations are extracted during analysis.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
      } else {
        if !kinds.isEmpty {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.xs) {
              Button {
                selectedKind = nil
              } label: {
                Text("All").font(.caption2)
                  .padding(.horizontal, AppSpacing.sm).padding(.vertical, AppSpacing.xs)
                  .background(
                    selectedKind == nil
                      ? Color.accentColor.opacity(0.15) : Color(.tertiarySystemFill)
                  )
                  .clipShape(Capsule())
              }
              ForEach(kinds, id: \.self) { kind in
                Button {
                  selectedKind = kind
                } label: {
                  Text(kind.capitalized).font(.caption2)
                    .padding(.horizontal, AppSpacing.sm).padding(.vertical, AppSpacing.xs)
                    .background(
                      selectedKind == kind
                        ? Color.accentColor.opacity(0.15) : Color(.tertiarySystemFill)
                    )
                    .clipShape(Capsule())
                }
              }
            }
            .padding(.horizontal, AppSpacing.md).padding(.vertical, AppSpacing.xs)
          }
        }

        List {
          Section("\(filteredEntities.count) entities") {
            ForEach(filteredEntities) { e in
              entityRow(e)
            }
          }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
      }
    }
    .task { await loadEntities() }
  }

  private func entityRow(_ e: EntitySummary) -> some View {
    HStack(spacing: AppSpacing.md) {
      Image(systemName: kindIcon(e.kind))
        .font(.caption).foregroundStyle(kindColor(e.kind))
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 2) {
        Text(e.name).font(.subheadline).fontWeight(.medium)
        Text(e.kind.capitalized).font(.caption2).foregroundStyle(.secondary)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 2) {
        Text("\(e.mentionCount)").font(.caption).fontWeight(.semibold)
        Text("mentions").font(.caption2).foregroundStyle(.tertiary)
      }
    }
    .padding(.vertical, AppSpacing.xs)
  }

  private func loadEntities() async {
    let projSvc = ProjectService(context: modelContext)
    let store = FileArtifactStore()
    guard let items = try? projSvc.items(in: projectID) else {
      isLoading = false
      return
    }

    var nameToEntry: [String: (kind: String, count: Int, items: [String])] = [:]

    for item in items {
      guard
        let analysis = try? store.readArtifact(
          MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id)
      else { continue }
      for entity in analysis.entities {
        let key = "\(entity.name)|\(entity.type.rawValue)"
        var entry = nameToEntry[key] ?? (entity.type.rawValue, 0, [])
        entry.count += 1
        if !entry.items.contains(item.title) { entry.items.append(item.title) }
        nameToEntry[key] = entry
      }
    }

    entities = nameToEntry.map {
      EntitySummary(
        name: String($0.key.split(separator: "|")[0]), kind: $1.kind, mentionCount: $1.count,
        sourceItems: $1.items)
    }.sorted { $0.mentionCount > $1.mentionCount }

    isLoading = false
  }

  private func kindIcon(_ kind: String) -> String {
    switch kind {
    case "organization": "building.2"
    case "system": "server.rack"
    case "repository": "chevron.left.forwardslash.chevron.right"
    case "ticket": "tag"
    case "location": "location"
    default: "cube"
    }
  }

  private func kindColor(_ kind: String) -> Color {
    switch kind {
    case "organization": .blue
    case "system": .purple
    case "repository": .green
    case "ticket": .orange
    case "location": .teal
    default: .gray
    }
  }
}
