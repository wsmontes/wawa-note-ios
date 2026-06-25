import SwiftUI
import SwiftData
// Related JIRA: KAN-9, KAN-46


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
                                if sortColumn == idx { sortAscending.toggle() }
                                else { sortColumn = idx; sortAscending = true }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(header).font(.caption).fontWeight(.bold)
                                    if sortColumn == idx {
                                        Image(systemName: sortAscending ? "chevron.up" : "chevron.down").font(.system(size: 8))
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
            HStack { Spacer(); Text("\(table.rows.count) rows").font(.caption2).foregroundStyle(.tertiary) }
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
                    Button { checked.insert(idx) } label: {
                        Image(systemName: checked.contains(idx) ? "checkmark.circle.fill" : "circle")
                            .font(.title3).foregroundStyle(checked.contains(idx) ? .green : .secondary)
                    }.buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.task).font(.subheadline).strikethrough(checked.contains(idx))
                        HStack(spacing: 8) {
                            if let owner = item.owner { Label(owner, systemImage: "person").font(.caption2).foregroundStyle(.secondary) }
                            if let due = item.dueDate { Label(due, systemImage: "calendar").font(.caption2).foregroundStyle(.secondary) }
                            if let pri = item.priority { Label(pri, systemImage: "flag").font(.caption2).foregroundStyle(pri == "high" ? .red : .secondary) }
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
                    Text(badge).font(.caption2).fontWeight(.semibold).padding(.horizontal, 8).padding(.vertical, 2)
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
                    Task { try? await Task.sleep(nanoseconds: 2_000_000_000); copied = false }
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

    var body: some View {
        KnowledgeDetailView(itemID: itemID)
    }
}

struct EvidenceCardView: View {
    let itemTitle: String; let itemID: UUID; let snippet: String
    let segmentID: String?; let confidence: Double?; let edgeType: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.turn.down.right").font(.system(size: 9)).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(itemTitle).font(.caption).fontWeight(.medium).lineLimit(1)
                Text(snippet.prefix(120)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 6) {
                    if let seg = segmentID { Text("Seg \(seg.prefix(8))").font(.system(size: 9)).foregroundStyle(.tertiary) }
                    if let conf = confidence { ConfidenceBadge(value: conf) }
                    if let et = edgeType { Text(et).font(.system(size: 9)).padding(.horizontal,4).padding(.vertical,1).background(Color.blue.opacity(0.1)).clipShape(Capsule()) }
                }
            }
            Spacer()
        }
        .padding(8).background(Color(.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 8))
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
    let confidence: Double?; let source: String?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles").font(.system(size: 8))
            Text(source ?? "AI").font(.system(size: 9))
            if let conf = confidence { ConfidenceBadge(value: conf) }
        }
        .padding(.horizontal, 6).padding(.vertical, 2).background(.thinMaterial).clipShape(Capsule())
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
        .padding(10).background(Color(.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func typeIcon(_ t: String) -> String {
        switch t { case "note": "doc.text"; case "audio": "mic"; case "image": "photo"; case "journalEntry": "book"; case "webBookmark": "bookmark"; default: "doc" }
    }
    private func typeColor(_ t: String) -> Color {
        switch t { case "note": .orange; case "audio": .blue; case "image": .pink; case "journalEntry": .purple; case "webBookmark": .green; default: .secondary }
    }
}

// MARK: - Document Header Card

struct DocumentHeaderCardView: View {
    let data: DocumentHeaderData

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: docIcon).font(.title2).foregroundStyle(.blue)
                .frame(width: 36, height: 36).background(.blue.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 8))
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
        .padding(10).background(Color(.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 10))
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
                Text("\(data.step)/\(data.total)").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color(.systemFill)).frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(progressColor)
                        .frame(width: geo.size.width * CGFloat(data.step) / CGFloat(max(1, data.total)), height: 6)
                        .animation(.easeInOut(duration: 0.4), value: data.step)
                }
            }.frame(height: 6)
        }
    }

    private var progressColor: Color {
        let ratio = Double(data.step) / Double(max(1, data.total))
        if ratio >= 1.0 { return .green }
        if ratio >= 0.5 { return .blue }
        return .orange
    }
}

// MARK: - Chat Block Router (from ChatView.swift)

struct ChatBlockView: View {
    let block: ChatBlock
    var projectColorHex: String?
    var onSendMessage: ((String) -> Void)?
    var onRunCommand: ((String) -> Void)?
    var onChooseOption: ((String) -> Void)?

    var body: some View {
        switch block {
        case .text(let text):
            Text(text).font(.body)
        case .table(let data):
            TableBlockView(table: TableBlock(title: data.title, headers: data.headers, rows: data.rows))
        case .code(let data):
            CodeBlockView(codeBlock: CodeBlock(code: data.code, language: data.language, caption: data.caption))
        case .bulletList(let items):
            BulletListView(items: items)
        case .orderedList(let items):
            OrderedListView(items: items)
        case .projectContext(let ctx):
            ProjectContextCardView(data: ctx, onRunCommand: onRunCommand)
        case .taskCard(let task):
            TaskCardView(data: task, onRunCommand: onRunCommand, onChooseOption: onChooseOption)
        case .itemCard(let item):
            ItemCardView(data: item, onRunCommand: onRunCommand, onChooseOption: onChooseOption)
        case .searchResults(let results):
            SearchResultsCardView(data: results)
        case .analysisAccordion(let analysis):
            AnalysisAccordionView(data: analysis)
        case .choicePrompt(let prompt):
            ChoicePromptView(data: prompt, onChooseOption: onChooseOption)
        case .confirmation(let confirm):
            ConfirmationView(data: confirm, onChooseOption: onChooseOption)
        case .fileLink(let data):
            FileLinkCardView(data: data, onRunCommand: onRunCommand)
        case .documentHeader(let data):
            DocumentHeaderCardView(data: data)
        case .freeTextInput(let data):
            FreeTextInputView(data: data, onSubmit: { text in onChooseOption?(text) })
        case .progressUpdate(let data):
            ProgressUpdateView(data: data)
        }
    }
}

// MARK: - Project Context Card

struct ProjectContextCardView: View {
    let data: ProjectContextData
    var onRunCommand: ((String) -> Void)?
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                RoundedRectangle(cornerRadius: 4).fill(Color.blue).frame(width: 4, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(data.projectName).font(.subheadline).fontWeight(.semibold)
                    HStack(spacing: 8) {
                        HStack(spacing: 3) { Image(systemName: "checklist").font(.system(size: 9)); Text("\(data.taskCount)").font(.caption2) }.foregroundStyle(.secondary)
                        HStack(spacing: 3) { Image(systemName: "doc").font(.system(size: 9)); Text("\(data.itemCount)").font(.caption2) }.foregroundStyle(.secondary)
                        if data.signalCount > 0 {
                            HStack(spacing: 3) { Image(systemName: "waveform.path.ecg").font(.system(size: 9)); Text("\(data.signalCount)").font(.caption2) }.foregroundStyle(.orange)
                        }
                    }
                }
                Spacer()
            }
            if expanded {
                Divider().padding(.vertical, 6)
                HStack(spacing: 6) {
                    ForEach(["ls tasks/", "ls items/", "cat project.json"], id: \.self) { cmd in
                        Button { onRunCommand?(cmd) } label: {
                            Text(cmd).font(.caption2).padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.ultraThinMaterial).clipShape(Capsule())
                        }.buttonStyle(.plain)
                    }
                }
            }
            Button { withAnimation { expanded.toggle() } } label: {
                HStack(spacing: 2) {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9))
                    Text(expanded ? "Less" : "Actions").font(.caption2)
                }.foregroundStyle(.blue)
            }.buttonStyle(.plain).padding(.top, 4)
        }
        .padding(12)
        .background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Task Card

struct TaskCardView: View {
    let data: TaskCardData
    var onRunCommand: ((String) -> Void)?
    var onChooseOption: ((String) -> Void)?
    @State private var confirmed = false
    @State private var dismissed = false
    @State private var showActions = false
    @State private var offsetX: CGFloat = 0
    private let swipeThreshold: CGFloat = -80

    var body: some View {
        if dismissed { EmptyView() } else {
            ZStack {
                HStack(spacing: 0) {
                    Spacer()
                    Button {
                        withAnimation(.spring(response: 0.3)) { confirmed = true; offsetX = 0 }
                        let path = "tasks/\(data.taskID)"
                        onRunCommand?("echo '{\"status\":\"done\"}' > \(path)")
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill").font(.title3)
                            Text("Done").font(.caption2)
                        }.foregroundStyle(.white).frame(width: 70).frame(maxHeight: .infinity).background(Color.green)
                    }
                    Button {
                        withAnimation(.spring(response: 0.3)) { offsetX = 0 }
                        onChooseOption?("Show me details about the task: \(data.title)")
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "info.circle.fill").font(.title3)
                            Text("Details").font(.caption2)
                        }.foregroundStyle(.white).frame(width: 70).frame(maxHeight: .infinity).background(Color.blue)
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: confirmed ? "checkmark.circle.fill" : "circle")
                            .font(.title3).foregroundStyle(confirmed ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(data.title).font(.subheadline).fontWeight(.semibold)
                            HStack(spacing: 6) {
                                priorityBadge(data.priority)
                                if let o = data.owner { Text(o).font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                        Spacer()
                        if confirmed { Image(systemName: "checkmark").font(.caption).foregroundStyle(.green) }
                        if !confirmed && !showActions {
                            Image(systemName: "chevron.left").font(.system(size: 10)).foregroundStyle(.tertiary)
                                .opacity(offsetX < -20 ? 0 : 0.4)
                        }
                    }
                    if !confirmed && data.needsConfirmation && !showActions {
                        HStack(spacing: 8) {
                            Button {
                                confirmed = true
                                let path = "tasks/\(data.taskID)"
                                onRunCommand?("echo '{\"status\":\"done\"}' > \(path)")
                            } label: {
                                Label("Confirm", systemImage: "checkmark").font(.caption2).fontWeight(.medium)
                                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                                    .background(.thinMaterial).clipShape(RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                            Button { dismissed = true } label: {
                                Label("Cancel", systemImage: "xmark").font(.caption2)
                                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                                    .background(.thinMaterial).clipShape(RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).foregroundStyle(.secondary)
                        }.padding(.top, 10)
                    }
                }
                .padding(12).background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
                .offset(x: offsetX)
                .gesture(DragGesture()
                    .onChanged { value in
                        guard !confirmed else { return }
                        let translation = value.translation.width
                        if translation < 0 { offsetX = max(translation, -150) }
                        else if offsetX < 0 { offsetX = min(translation + offsetX, 0) }
                    }
                    .onEnded { value in
                        guard !confirmed else { return }
                        let velocity = value.predictedEndTranslation.width - value.translation.width
                        if offsetX < swipeThreshold || velocity < -200 {
                            withAnimation(.spring(response: 0.3)) { offsetX = -140 }
                            showActions = true
                        } else {
                            withAnimation(.spring(response: 0.3)) { offsetX = 0 }
                            showActions = false
                        }
                    }
                )
            }
        }
    }

    func priorityBadge(_ p: String) -> some View {
        let (color, icon): (Color, String) = {
            switch p {
            case "critical": (.red, "exclamationmark.triangle.fill")
            case "high": (.orange, "arrow.up")
            case "medium": (.blue, "minus")
            default: (.secondary, "minus")
            }
        }()
        return HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 8))
            Text(p.capitalized).font(.caption2)
        }.padding(.horizontal, 6).padding(.vertical, 2)
        .background(color.opacity(0.12)).clipShape(Capsule()).foregroundStyle(color)
    }
}

// MARK: - Item Card

struct ItemCardView: View {
    let data: ItemCardData
    var onRunCommand: ((String) -> Void)?
    var onChooseOption: ((String) -> Void)?
    @State private var offsetX: CGFloat = 0
    @State private var showActions = false
    private let swipeThreshold: CGFloat = -80

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.3)) { offsetX = 0 }
                    onChooseOption?("Show me details about: \(data.title)")
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "info.circle.fill").font(.title3)
                        Text("Details").font(.caption2)
                    }.foregroundStyle(.white).frame(width: 70).frame(maxHeight: .infinity).background(Color.blue)
                }
                if let uuid = UUID(uuidString: data.itemID) {
                    Button {
                        withAnimation(.spring(response: 0.3)) { offsetX = 0 }
                        NotificationCenter.default.post(name: .pipelineCompleted, object: data.itemID, userInfo: ["action": "reprocess"])
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "sparkles").font(.title3)
                            Text("Analyze").font(.caption2)
                        }.foregroundStyle(.white).frame(width: 70).frame(maxHeight: .infinity).background(Color.purple)
                    }
                }
            }.clipShape(RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 10) {
                Image(systemName: typeIcon(data.type)).font(.title3).foregroundStyle(typeColor(data.type)).frame(width: 32).padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(data.title).font(.subheadline).fontWeight(.medium).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(data.type.capitalized).font(.caption2).foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.tertiary)
                        Text(data.status.capitalized).font(.caption2).foregroundStyle(.secondary)
                        if let dur = data.durationSeconds { Text("·").foregroundStyle(.tertiary); Text(formatDuration(dur)).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                Spacer()
                if !showActions {
                    Image(systemName: "chevron.left").font(.system(size: 10)).foregroundStyle(.tertiary)
                        .opacity(offsetX < -20 ? 0 : 0.4)
                }
            }
            .padding(12).background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
            .offset(x: offsetX)
            .gesture(DragGesture()
                .onChanged { value in
                    let translation = value.translation.width
                    if translation < 0 { offsetX = max(translation, -150) }
                    else if offsetX < 0 { offsetX = min(translation + offsetX, 0) }
                }
                .onEnded { value in
                    let velocity = value.predictedEndTranslation.width - value.translation.width
                    if offsetX < swipeThreshold || velocity < -200 {
                        withAnimation(.spring(response: 0.3)) { offsetX = -140 }
                        showActions = true
                    } else {
                        withAnimation(.spring(response: 0.3)) { offsetX = 0 }
                        showActions = false
                    }
                }
            )
        }
    }
    private func typeIcon(_ t: String) -> String {
        switch t { case "audio": "mic.fill"; case "note": "doc.text.fill"; case "image": "photo.fill"; default: "doc.fill" }
    }
    private func typeColor(_ t: String) -> Color {
        switch t { case "audio": .red; case "note": .blue; case "image": .purple; default: .secondary }
    }
    private func formatDuration(_ s: Double) -> String { let m = Int(s)/60; let sec = Int(s)%60; return "\(m):\(String(format:"%02d",sec))" }
}

// MARK: - Search Results + Analysis + Choice + Confirmation

struct SearchResultsCardView: View {
    let data: SearchResultsData
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\"\(data.query)\" — \(data.results.count) results", systemImage: "magnifyingglass")
                .font(.subheadline).fontWeight(.medium).foregroundStyle(.blue)
            ForEach(data.results.prefix(5), id: \.itemID) { r in
                HStack(spacing: 8) {
                    Image(systemName: "doc.text").font(.system(size: 10)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.title).font(.caption).fontWeight(.medium).lineLimit(1)
                        Text(r.snippet).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }.padding(12).background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct AnalysisAccordionView: View {
    let data: AnalysisData
    var body: some View {
        VStack(spacing: 0) {
            ForEach(data.sections, id: \.title) { section in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(section.items.prefix(10), id: \.self) { item in
                            HStack(alignment: .top, spacing: 6) {
                                Circle().fill(.secondary).frame(width: 4, height: 4).padding(.top, 7)
                                Text(item).font(.caption).foregroundStyle(.primary)
                            }
                        }
                        if section.items.count > 10 {
                            Text("... and \(section.items.count - 10) more").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }.padding(.leading, 4).padding(.top, 2)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: sectionIcon(section.title)).font(.system(size: 10)).foregroundStyle(.blue)
                        Text(section.title).font(.caption).fontWeight(.semibold)
                        Text("(\(section.count))").font(.caption2).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 3)
                if section.title != data.sections.last?.title { Divider().padding(.leading, 22) }
            }
        }.padding(12).background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
    }
    private func sectionIcon(_ t: String) -> String {
        switch t.lowercased() {
        case let s where s.contains("decision"): "checkmark.shield"
        case let s where s.contains("action"): "bolt"
        case let s where s.contains("risk"): "exclamationmark.triangle"
        case let s where s.contains("question"): "questionmark.circle"
        case let s where s.contains("entit"): "person.2"
        default: "doc.text"
        }
    }
}

struct ChoicePromptView: View {
    let data: ChoicePromptData
    var onChooseOption: ((String) -> Void)?
    @State private var selectedIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(data.question).font(.subheadline).fontWeight(.semibold)
            ForEach(Array(data.options.enumerated()), id: \.offset) { idx, option in
                Button {
                    selectedIndex = idx
                    let prompt = option.value
                    onChooseOption?(prompt)
                } label: {
                    HStack(spacing: 10) {
                        if let sel = selectedIndex, sel == idx {
                            Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green).frame(width: 20, height: 20)
                        } else {
                            Text("\(idx + 1)").font(.caption).fontWeight(.bold).foregroundStyle(.blue)
                                .frame(width: 20, height: 20).background(Circle().fill(.blue.opacity(0.1)))
                        }
                        Text(option.label).font(.subheadline).lineLimit(2)
                        Spacer()
                        Image(systemName: "arrow.up.forward").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(.thinMaterial).clipShape(RoundedRectangle(cornerRadius: 10))
                    .opacity(selectedIndex != nil && selectedIndex != idx ? 0.5 : 1.0)
                }.buttonStyle(.plain).disabled(selectedIndex != nil)
            }
        }.padding(12).background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct ConfirmationView: View {
    let data: ConfirmationData
    var onChooseOption: ((String) -> Void)?
    @State private var resolved: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(data.title).font(.subheadline).fontWeight(.semibold)
                    Text(data.message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            if !resolved {
                HStack(spacing: 8) {
                    Button {
                        resolved = true; onChooseOption?(data.confirmValue)
                    } label: {
                        Label(data.confirmLabel, systemImage: "checkmark").font(.caption).fontWeight(.medium)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(.thinMaterial).clipShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                    Button {
                        resolved = true; onChooseOption?(data.cancelValue)
                    } label: {
                        Text(data.cancelLabel).font(.caption).frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(.thinMaterial).clipShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                    Text("Response sent").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(12).background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
