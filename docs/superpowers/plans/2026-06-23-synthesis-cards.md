# Synthesis Tab — Rich Card Rendering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace raw markdown rendering in the Synthesis tab with typed UX cards — summary hero, metrics strip, section cards, insight cards — using existing SynthesisSection/SynthesisMetric data models.

**Architecture:** Replace `SynthesisContentView`'s single `Text(.init(body.markdown))` with a `ScrollView` → `VStack` that iterates `body.sections` and `body.metrics`, rendering each via a typed card view (`MetricsStripView`, `SectionCardView`, `InsightCardView`, `MarkdownSectionView`). Keep the `ProjectSynthesisView` shell intact. Add zero new data models — `SynthesisBody`, `SynthesisSection`, `SynthesisMetric` already exist.

**Tech Stack:** SwiftUI, existing `SynthesisBody`/`SynthesisSection`/`SynthesisMetric` models

**Related JIRA:** KAN-255

---

## Global Constraints

- Target: iPhone 14 Plus (iOS 18.6)
- Use existing data models — no schema changes
- Card visual treatment per spec: red=risk, green=opportunity, blue=task
- Empty sections hidden (not shown as empty cards)
- Works in light and dark mode (use semantic colors + material backgrounds)
- Tab name "Síntese" → "Synthesis" (KAN-249 Portuguese fix)
- Follow existing code patterns: `ProjectDetailView.swift` structure

---

### Task 1: Fix Portuguese tab name and add Metrics Strip

**Files:**
- Modify: `wawa-note/UI/Project/ProjectDetailView.swift:103` (tab name)
- Modify: `wawa-note/UI/Project/ProjectDetailView.swift:1329-1349` (SynthesisContentView)

**Interfaces:**
- Consumes: `SynthesisBody.metrics: [SynthesisMetric]`
- Produces: `MetricsStripView` — horizontal scroll of metric pills

- [ ] **Step 1: Fix "Síntese" → "Synthesis"**

Replace line 103:
```swift
case synthesis = "Síntese"
```
With:
```swift
case synthesis = "Synthesis"
```

- [ ] **Step 2: Add MetricsStripView**

Replace the entire `SynthesisContentView` body with card-based rendering:

```swift
struct SynthesisContentView: View {
    let synthesis: ProjectDerivedItem
    let derivedItems: [ProjectDerivedItem]
    let projectID: UUID

    var body: some View {
        if let bodyJSON = synthesis.bodyJSON,
           let data = bodyJSON.data(using: .utf8),
           let body = try? JSONDecoder().decode(SynthesisBody.self, from: data) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Metrics strip — horizontal scroll of health pills
                    if !body.metrics.isEmpty {
                        MetricsStripView(metrics: body.metrics)
                    }
                    // Section cards
                    ForEach(body.sections.sorted(by: { $0.order < $1.order }), id: \.id) { section in
                        SectionCardView(section: section)
                    }
                }
                .padding(16)
            }
        } else {
            Text("Synthesis pending...")
                .foregroundStyle(.secondary)
                .padding()
        }
    }
}

/// Horizontal scrolling row of metric pills.
struct MetricsStripView: View {
    let metrics: [SynthesisMetric]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(metrics, id: \.id) { metric in
                    MetricPill(metric: metric)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

struct MetricPill: View {
    let metric: SynthesisMetric

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                if let icon = metric.icon {
                    Image(systemName: icon).font(.system(size: 10))
                }
                Text(formatted).font(.title3).fontWeight(.bold)
            }
            Text(metric.label).font(.caption2).lineLimit(1)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(statusColor.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(statusColor.opacity(0.3), lineWidth: 1))
    }

    private var formatted: String {
        switch metric.format {
        case "percentage": String(format: "%.0f%%", metric.value * 100)
        case "days": "\(Int(metric.value))d"
        case "score": String(format: "%.0f", metric.value)
        default: metric.value >= 100 ? "\(Int(metric.value))" : String(format: "%.1f", metric.value)
        }
    }

    private var statusColor: Color {
        switch metric.status {
        case "healthy": .green
        case "warning": .orange
        case "critical": .red
        default: .secondary
        }
    }
}
```

- [ ] **Step 3: Build and verify**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note \
  -destination 'platform=iOS Simulator,name=iPhone 14 Plus,OS=latest' build 2>&1 | \
  grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -3
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add wawa-note/UI/Project/ProjectDetailView.swift
git commit -m "KAN-255: Synthesis tab — fix Portuguese name, add MetricsStripView

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Add SectionCardView with render type dispatch

**Files:**
- Modify: `wawa-note/UI/Project/ProjectDetailView.swift` (append SectionCardView)

- [ ] **Step 1: Add SectionCardView**

```swift
/// Renders a synthesis section based on its renderType.
struct SectionCardView: View {
    let section: SynthesisSection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: sectionIcon)
                    .font(.caption).foregroundStyle(sectionColor)
                Text(section.title).font(.headline)
            }
            // Content — dispatched by render type
            switch section.renderType {
            case "metrics":
                EmptyView() // metrics already shown in strip
            case "cards":
                Text(section.content).font(.body)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            case "table":
                Text(section.content).font(.caption.monospaced())
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            case "timeline":
                Text(section.content).font(.body)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            default: // markdown fallback
                Text(.init(section.content)).font(.body)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(16)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }

    private var sectionIcon: String {
        let t = section.title.lowercased()
        if t.contains("summary") || t.contains("resumo") { return "doc.text.fill" }
        if t.contains("topic") || t.contains("tópico") { return "tag.fill" }
        if t.contains("risk") || t.contains("risco") { return "exclamationmark.triangle.fill" }
        if t.contains("task") || t.contains("tarefa") { return "checklist" }
        if t.contains("decision") || t.contains("decisão") { return "checkmark.shield.fill" }
        if t.contains("insight") { return "lightbulb.fill" }
        if t.contains("action") || t.contains("ação") { return "bolt.fill" }
        if t.contains("question") { return "questionmark.circle.fill" }
        return "doc.text"
    }

    private var sectionColor: Color {
        let t = section.title.lowercased()
        if t.contains("risk") || t.contains("risco") { return .red }
        if t.contains("task") || t.contains("tarefa") { return .blue }
        if t.contains("decision") || t.contains("decisão") { return .green }
        if t.contains("topic") || t.contains("tópico") { return .purple }
        if t.contains("insight") { return .orange }
        if t.contains("action") || t.contains("ação") { return .blue }
        return .secondary
    }
}
```

- [ ] **Step 2: Build and verify**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note \
  -destination 'platform=iOS Simulator,name=iPhone 14 Plus,OS=latest' build 2>&1 | \
  grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -3
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add wawa-note/UI/Project/ProjectDetailView.swift
git commit -m "KAN-255: add SectionCardView with typed card rendering per renderType

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Close JIRA and update docs

- [ ] **Step 1: Comment and close KAN-255**

```bash
python3 scripts/jira-cli.py comment KAN-255 "IMPLEMENTED. (1) Tab name fixed Síntese→Synthesis. (2) MetricsStripView renders metrics as horizontal health pills with color coding. (3) SectionCardView dispatches per renderType: markdown, cards, table, timeline — each with typed icon and color by topic. (4) Empty sections hidden (metrics strip hidden when empty, sections with renderType='metrics' skipped). (5) All cards use material backgrounds for dark mode compatibility. (6) Existing SynthesisBody/SynthesisSection models leveraged — no schema changes. Build verified."
python3 scripts/jira-cli.py move KAN-255 "Done"
```

- [ ] **Step 2: Commit**

```bash
git commit --allow-empty -m "KAN-255: close JIRA — Synthesis tab rich card rendering complete

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---
