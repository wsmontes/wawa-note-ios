import SwiftData
import SwiftUI
import WawaNoteCore

// MARK: - Block Rendering Views
/// Extracted from ChatView.swift for file size management.
/// These are pure presentation views with no ChatView dependencies.

struct TableBlockView: View {
  let table: TableBlock
  @State private var sortColumn: Int? = nil
  @State private var sortAscending = true

  private var sortedRows: [[String]] {
    guard let col = sortColumn, col < table.headers.count else { return table.rows }
    return table.rows.sorted {
      let a = col < $0.count ? $0[col] : ""
      let b = col < $1.count ? $1[col] : ""
      return sortAscending ? a < b : a > b
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let title = table.title {
        Text(title).font(.headline)
      }
      ScrollView(.horizontal) {
        VStack(spacing: 0) {
          // Header
          HStack(spacing: 0) {
            ForEach(Array(table.headers.enumerated()), id: \.offset) { idx, header in
              Button {
                if sortColumn == idx {
                  sortAscending.toggle()
                } else {
                  sortColumn = idx
                  sortAscending = true
                }
              } label: {
                HStack(spacing: 4) {
                  Text(header).font(.caption).fontWeight(.bold)
                  if sortColumn == idx {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down").font(
                      .system(size: 8))
                  }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Color(.secondarySystemBackground))
              }
              .buttonStyle(.plain)
              if idx < table.headers.count - 1 {
                Divider().frame(width: 1)
              }
            }
          }
          Divider()
          // Rows
          ForEach(Array(sortedRows.enumerated()), id: \.offset) { _, row in
            HStack(spacing: 0) {
              ForEach(Array(row.enumerated()), id: \.offset) { idx, cell in
                Text(cell).font(.caption).foregroundStyle(.primary)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.horizontal, 8).padding(.vertical, 4)
                if idx < row.count - 1 {
                  Divider().frame(width: 1)
                }
              }
            }
            Divider()
          }
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.separator)))
      HStack {
        Spacer()
        Text("\(table.rows.count) rows").font(.caption2).foregroundStyle(.tertiary)
      }
    }
    .padding(.vertical, 4)
  }
}

struct ActionBlockView: View {
  let actions: ActionBlock
  @State private var checked: Set<Int> = []

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let title = actions.title {
        Text(title).font(.headline)
      }
      ForEach(Array(actions.items.enumerated()), id: \.offset) { idx, item in
        HStack(spacing: 8) {
          Button {
            checked.insert(idx)
          } label: {
            Image(systemName: checked.contains(idx) ? "checkmark.circle.fill" : "circle")
              .font(.title3).foregroundStyle(checked.contains(idx) ? .green : .secondary)
          }.buttonStyle(.plain)
          VStack(alignment: .leading, spacing: 1) {
            Text(item.task).font(.subheadline).strikethrough(checked.contains(idx))
            HStack(spacing: 8) {
              if let owner = item.owner {
                Label(owner, systemImage: "person").font(.caption2).foregroundStyle(.secondary)
              }
              if let due = item.dueDate {
                Label(due, systemImage: "calendar").font(.caption2).foregroundStyle(.secondary)
              }
              if let pri = item.priority {
                Label(pri, systemImage: "flag").font(.caption2).foregroundStyle(
                  pri == "high" ? .red : .secondary)
              }
            }
          }
        }
        .padding(.vertical, 2)
      }
    }
    .padding(.vertical, 4)
  }
}

struct CardBlockView: View {
  let card: CardBlock

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(card.title).font(.headline)
        Spacer()
        if let badge = card.badge {
          Text(badge).font(.caption2).fontWeight(.semibold).padding(.horizontal, 8).padding(
            .vertical, 2
          )
          .background(Color.blue.opacity(0.1)).clipShape(Capsule())
        }
      }
      Text(card.body).font(.subheadline).foregroundStyle(.secondary)
      if !card.entities.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 4) {
            ForEach(card.entities, id: \.self) { entity in
              Text(entity).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color(.secondarySystemBackground)).clipShape(Capsule())
            }
          }
        }
      }
    }
    .padding(12)
    .background(Color(.systemBackground))
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.separator)))
    .padding(.vertical, 4)
  }
}

struct BulletListView: View {
  let items: [String]
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(items, id: \.self) { item in
        HStack(alignment: .top, spacing: 8) {
          Text("•").foregroundStyle(.secondary)
          Text(item).font(.subheadline)
        }
      }
    }.padding(.vertical, 2)
  }
}

struct OrderedListView: View {
  let items: [String]
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(Array(items.enumerated()), id: \.element) { idx, item in
        HStack(alignment: .top, spacing: 8) {
          Text("\(idx + 1).").foregroundStyle(.secondary).monospacedDigit()
          Text(item).font(.subheadline)
        }
      }
    }.padding(.vertical, 2)
  }
}

struct CodeBlockView: View {
  let codeBlock: CodeBlock
  @State private var copied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        if let lang = codeBlock.language {
          Text(lang).font(.caption2).foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          UIPasteboard.general.string = codeBlock.code
          copied = true
          Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copied = false
          }
        } label: {
          Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            .font(.caption2)
        }
      }
      Text(codeBlock.code).font(.system(.footnote, design: .monospaced))
        .padding(8)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 6))
      if let caption = codeBlock.caption {
        Text(caption).font(.caption2).foregroundStyle(.tertiary)
      }
    }
    .padding(.vertical, 4)
  }
}

struct KnowledgeItemNavigationView: View {
  let itemID: UUID
  @Environment(\.modelContext) private var modelContext

  var body: some View {
    if let item = try? KnowledgeItemService(context: modelContext).fetchItem(id: itemID) {
      KnowledgeDetailView(item: item)
    } else {
      Text("Item not found").font(.headline).foregroundStyle(.secondary)
    }
  }
}

struct EvidenceCardView: View {
  let itemTitle: String
  let itemID: UUID
  let snippet: String
  let segmentID: String?
  let confidence: Double?
  let edgeType: String?

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "arrow.turn.down.right").font(.system(size: 9)).foregroundStyle(.blue)
      VStack(alignment: .leading, spacing: 2) {
        Text(itemTitle).font(.caption).fontWeight(.medium).lineLimit(1)
        Text(snippet.prefix(120)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        HStack(spacing: 6) {
          if let seg = segmentID {
            Text("Seg \(seg.prefix(8))").font(.system(size: 9)).foregroundStyle(.tertiary)
          }
          if let conf = confidence { ConfidenceBadge(value: conf) }
          if let et = edgeType {
            Text(et).font(.system(size: 9)).padding(.horizontal, 4).padding(.vertical, 1)
              .background(Color.blue.opacity(0.1)).clipShape(Capsule())
          }
        }
      }
      Spacer()
    }
    .padding(8).background(Color(.secondarySystemBackground)).clipShape(
      RoundedRectangle(cornerRadius: 8))
  }
}

struct ConfidenceBadge: View {
  let value: Double
  private var color: Color { value >= 0.8 ? .green : value >= 0.5 ? .orange : .gray }

  var body: some View {
    HStack(spacing: 2) {
      Circle().fill(color).frame(width: 6, height: 6)
      Text("\(Int(value * 100))%").font(.system(size: 9)).foregroundStyle(color)
    }
  }
}

struct AIGeneratedBadge: View {
  let confidence: Double?
  let source: String?

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: "sparkles").font(.system(size: 8))
      Text(source ?? "AI").font(.system(size: 9))
      if let conf = confidence { ConfidenceBadge(value: conf) }
    }
    .padding(.horizontal, 6).padding(.vertical, 2).background(Color.blue.opacity(0.08)).clipShape(
      Capsule())
  }
}

// MARK: - File Link Card

struct FileLinkCardView: View {
  let data: FileLinkData
  var onRunCommand: ((String) -> Void)?

  var body: some View {
    NavigationLink(value: data.itemID) {
      fileLinkContent
    }
    .buttonStyle(.plain)
  }

  private var fileLinkContent: some View {
    HStack(spacing: 10) {
      Image(systemName: typeIcon(data.itemType))
        .font(.title3).foregroundStyle(typeColor(data.itemType)).frame(width: 32)
      VStack(alignment: .leading, spacing: 2) {
        Text(data.title).font(.subheadline).fontWeight(.medium).lineLimit(1)
        Text(data.snippet).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
      }
      Spacer()
      Image(systemName: "doc.text.fill").font(.caption2).foregroundStyle(.tertiary)
    }
    .padding(10).background(Color(.secondarySystemBackground)).clipShape(
      RoundedRectangle(cornerRadius: 10))
  }

  private func typeIcon(_ t: String) -> String {
    switch t {
    case "note": "doc.text"
    case "audio": "mic"
    case "image": "photo"
    case "journalEntry": "book"
    case "webBookmark": "bookmark"
    default: "doc"
    }
  }
  private func typeColor(_ t: String) -> Color {
    switch t {
    case "note": .orange
    case "audio": .blue
    case "image": .pink
    case "journalEntry": .purple
    case "webBookmark": .green
    default: .secondary
    }
  }
}

// MARK: - Document Header Card

struct DocumentHeaderCardView: View {
  let data: DocumentHeaderData

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: docIcon).font(.title2).foregroundStyle(.blue)
        .frame(width: 36, height: 36).background(.blue.opacity(0.1)).clipShape(
          RoundedRectangle(cornerRadius: 8))
      VStack(alignment: .leading, spacing: 2) {
        Text(data.title).font(.subheadline).fontWeight(.semibold)
        Text(data.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        HStack(spacing: 4) {
          Text(data.documentType.replacingOccurrences(of: "-", with: " ").capitalized)
            .font(.caption2).foregroundStyle(.blue)
          Text("· \(data.sectionCount) sections").font(.caption2).foregroundStyle(.tertiary)
        }
      }
      Spacer()
    }
    .padding(10).background(Color(.secondarySystemBackground)).clipShape(
      RoundedRectangle(cornerRadius: 10))
  }

  private var docIcon: String {
    switch data.documentType {
    case "meeting-summary": "person.2.wave.2"
    case "status-report": "chart.bar.doc.horizontal"
    case "decision-log": "checkmark.circle"
    case "action-checklist": "checklist"
    case "research-notes": "book.pages"
    case "comparative-table": "tablecells"
    case "digest": "calendar.badge.clock"
    default: "doc.richtext"
    }
  }
}

// MARK: - Free Text Input

struct FreeTextInputView: View {
  let data: FreeTextInputData
  var onSubmit: ((String) -> Void)?

  @State private var text = ""
  @State private var submitted = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(data.question).font(.subheadline).fontWeight(.medium)
      HStack(spacing: 8) {
        TextField(data.placeholder, text: $text, axis: .vertical)
          .textFieldStyle(.roundedBorder)
          .lineLimit(3...6)
          .disabled(submitted)
        Button(data.submitLabel) {
          guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
          submitted = true
          onSubmit?(text)
        }
        .font(.subheadline).fontWeight(.semibold)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.blue, in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white)
        .disabled(submitted || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      if submitted {
        HStack(spacing: 4) {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
          Text("Response sent").font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .padding(12)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 12))
  }
}

// MARK: - Progress Update

struct ProgressUpdateView: View {
  let data: ProgressUpdateData

  var body: some View {
    VStack(spacing: 6) {
      HStack {
        Text(data.label).font(.caption).fontWeight(.medium)
        Spacer()
        Text("\(data.step)/\(data.total)").font(.caption2).foregroundStyle(.secondary)
          .monospacedDigit()
      }
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 3).fill(Color(.systemFill)).frame(height: 6)
          RoundedRectangle(cornerRadius: 3)
            .fill(progressColor)
            .frame(
              width: geo.size.width * CGFloat(data.step) / CGFloat(max(1, data.total)), height: 6
            )
            .animation(.easeInOut(duration: 0.4), value: data.step)
        }
      }.frame(height: 6)
    }
    .padding(10)
    .background(Color(.secondarySystemBackground))
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  private var progressColor: Color {
    let ratio = Double(data.step) / Double(max(1, data.total))
    if ratio >= 1.0 { return .green }
    if ratio >= 0.5 { return .blue }
    return .orange
  }
}
