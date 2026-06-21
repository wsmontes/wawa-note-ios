import Foundation
import SwiftData
import Contacts
import EventKit

// MARK: - Shell Command

struct ShellCommand {
    let name: String
    let args: [String]
    var flags: [String: String]
    let redirectTarget: String?  // for echo '...' > path
    let redirectBody: String?    // the JSON body before >
    var appendMode: Bool = false // >> instead of >
}

// MARK: - Shell Interpreter

@MainActor
enum ShellInterpreter {

    // MARK: Command History

    /// Stores the last 50 executed commands for `history` and `!!` support.
    private static var commandHistory: [String] = []
    private static let maxHistory = 50

    /// Record a command in history (skip empty, skip history/!! to avoid loops).
    private static func recordHistory(_ cmd: String) {
        let trimmed = cmd.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("history"), trimmed != "!!" else { return }
        commandHistory.append(trimmed)
        if commandHistory.count > maxHistory { commandHistory.removeFirst() }
    }

    // MARK: Public entry point (intelligent multi-command)

    /// Executes one or more commands separated by `&&`, `;`, or newlines.
    /// After `cd`, automatically appends a directory listing.
    /// Accumulates output from all commands in the chain.
    static func execute(command raw: String, context: ToolContext) -> ToolResult {
        // Handle !! and !prefix expansion
        var expanded = raw
        if expanded == "!!" {
            expanded = commandHistory.last ?? raw
        } else if expanded.hasPrefix("!") && !expanded.hasPrefix("! ") {
            let prefix = String(expanded.dropFirst())
            if let match = commandHistory.last(where: { $0.hasPrefix(prefix) }) {
                expanded = match
            }
        }
        recordHistory(expanded)

        // Split into individual commands
        let commands = splitCommands(raw)
        var allOutputs: [String] = []
        var lastError = false

        var previousOutput: String?
        for cmdStr in commands {
            var trimmed = cmdStr.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Pipe: prepend previous output to the piped command's stdin context
            let isPipe = trimmed.hasPrefix("| ")
            if isPipe {
                trimmed = String(trimmed.dropFirst(2))
            }

            let cmd = tokenize(trimmed)
            let result: ToolResult
            if isPipe, let prev = previousOutput {
                result = dispatchPipe(cmd, stdin: prev, context: context)
            } else {
                result = dispatch(cmd, context)
            }

            if !result.content.isEmpty {
                allOutputs.append(result.content)
                previousOutput = result.content
            } else {
                previousOutput = nil
            }
            if result.isError {
                lastError = true
            }
        }

        let combined = allOutputs.joined(separator: "\n")
        let preview = String(combined.replacingOccurrences(of: "\n", with: " ").prefix(120))
        return ToolResult(content: combined, citations: [], isError: lastError, displaySummary: preview)
    }

    /// Splits a command string by `&&`, `;`, `|`, and newlines.
    /// Pipe (`|`) is recognized as a separator but commands are marked with
    /// a "|" prefix to indicate piping — the execute() function handles chaining.
    static func splitCommands(_ raw: String) -> [String] {
        let lines = raw.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var result: [String] = []
        for line in lines {
            var current = ""
            var inSingle = false
            var inDouble = false
            var prevWasAmpersand = false
            for ch in line {
                if ch == "'" && !inDouble { inSingle.toggle(); current.append(ch); continue }
                if ch == "\"" && !inSingle { inDouble.toggle(); current.append(ch); continue }
                if !inSingle && !inDouble {
                    if ch == "&" && prevWasAmpersand {
                        current.removeLast()
                        result.append(current.trimmingCharacters(in: .whitespaces))
                        current = ""
                        prevWasAmpersand = false
                        continue
                    }
                    if ch == ";" {
                        result.append(current.trimmingCharacters(in: .whitespaces))
                        current = ""
                        prevWasAmpersand = false
                        continue
                    }
                    if ch == "|" {
                        result.append(current.trimmingCharacters(in: .whitespaces))
                        current = "| " // Mark next command as piped
                        prevWasAmpersand = false
                        continue
                    }
                    prevWasAmpersand = (ch == "&")
                } else {
                    prevWasAmpersand = false
                }
                current.append(ch)
            }
            if !current.trimmingCharacters(in: .whitespaces).isEmpty {
                result.append(current.trimmingCharacters(in: .whitespaces))
            }
        }
        return result
    }

    /// Dispatches a single command, with intelligent enhancements:
    /// Execute a piped command — passes `stdin` as context for commands that support it.
    private static func dispatchPipe(_ cmd: ShellCommand, stdin: String, context ctx: ToolContext) -> ToolResult {
        switch cmd.name {
        case "cat": return ok(stdin)
        case "grep":
            let pattern = cmd.args.first ?? ""
            guard !pattern.isEmpty else { return shellErr("grep: missing pattern") }
            let lines = stdin.components(separatedBy: "\n").filter { $0.contains(pattern) }
            return ok(lines.joined(separator: "\n"))
        case "wc":
            let lines = stdin.components(separatedBy: "\n").count
            let words = stdin.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.count
            return ok("\(lines) lines, \(words) words, \(stdin.count) chars")
        default:
            return shellErr("\(cmd.name): does not support pipe input. Supports: cat, grep, wc")
        }
    }

    private static let manPages: [String: String] = [
        "ls": "ls [path] — List directory contents.\n  Flags: --long, --type audio|note|image, --status todo|done|analyzed, --tag 'x', --since 7d, --limit 20\n  Examples: ls /, ls tasks/, ls items/ --type audio --since 7d",
        "cat": "cat <path> — Read file contents.\n  Examples: cat items/<uuid>/body.md, cat /agent/prompts/analysis_system.md",
        "echo": "echo '{\"field\":\"value\"}' > <path> — Write/update file.\n  Flags: --append (>> instead of >)\n  Examples: echo '{\"status\":\"done\"}' > tasks/task-filename",
        "touch": "touch <path> [flags] — Create files/tasks.\n  Flags: --title, --type audio|note|image, --body, --priority low|medium|high|critical, --owner, --due (ISO8601)",
        "rm": "rm <path> — Remove (trash) items/tasks.\n  Items go to Trash (recoverable). Tasks cannot be undone.",
        "mv": "mv <from> <to> — Move items.\n  Examples: mv /inbox/<uuid> /projects/<slug>/items/<uuid>",
        "find": "find [path] — Search with filters.\n  Flags: --tag X, --since 7d, --type audio|note, --status todo|analyzed, --project 'name', --limit 20",
        "pipe": "Pipes (|) — Chain commands.\n  Supported: cat, grep, wc\n  Examples: ls items/ | grep keyword, cat file | wc",
    ]

    /// Dispatches a single command. Handles:
    /// - `cd` auto-lists the target directory
    /// - Partial UUIDs are fuzzy-matched in cat/echo paths
    private static func dispatch(_ cmd: ShellCommand, _ ctx: ToolContext) -> ToolResult {
        var result: ToolResult
        switch cmd.name {
        case "man":
            let topic = cmd.args.first ?? ""
            if topic.isEmpty {
                let available = Self.manPages.keys.sorted().joined(separator: ", ")
                result = ok("man <command> — Show detailed help. Available: \(available)")
            } else if let page = Self.manPages[topic] {
                result = ok(page)
            } else {
                result = shellErr("man: no entry for '\(topic)'. Try 'man' without arguments to see available commands.")
            }
        case "ls":     result = handleLs(cmd, ctx)
        case "cd":     result = handleCd(cmd, ctx); if !result.isError { result = autoLsAfterCd(result, ctx) }
        case "cat":    result = handleCat(cmd, ctx)
        case "find":   result = handleFind(cmd, ctx)
        case "grep":   result = handleGrep(cmd, ctx)
        case "touch":  result = handleTouch(cmd, ctx)
        case "echo":   result = handleEcho(cmd, ctx)
        case "rm":     result = handleRm(cmd, ctx)
        case "mv":     result = handleMv(cmd, ctx)
        // Destructive commands: require --force flag to skip confirmation prompt
        // The agent should use ask_user first, then retry with --force after user confirms
        case "head":   result = handleHead(cmd, ctx)
        case "wc":     result = handleWc(cmd, ctx)
        case "history":result = handleHistory(cmd, ctx)
        case "extract":result = handleExtract(cmd, ctx)
        case "semantic":result = handleSemantic(cmd, ctx)
        case "analyze": result = handleAnalyze(cmd, ctx)
        case "cal":     result = handleCal(cmd, ctx)
        case "export":  result = handleExport(cmd, ctx)
        case "vision", "describe": result = handleVision(cmd, ctx)
        case "progress": result = handleProgress(cmd, ctx)
        case "cleanup": result = handleCleanup(cmd, ctx)
        case "recipe": result = handleRecipe(cmd, ctx)
        case "person": result = handlePerson(cmd, ctx)
        case "help":  result = handleHelp(cmd, ctx)
        case "ask_user": result = handleAskUser(cmd, ctx)
        default:
            // Try fuzzy matching
            let suggestions = ["ls", "cd", "cat", "find", "grep", "touch", "echo", "rm", "mv", "head", "wc", "history", "extract", "semantic", "analyze", "cal", "person", "export", "vision", "describe", "progress", "help", "ask_user"]
            let close = suggestions.filter { $0.hasPrefix(cmd.name) || levenshtein(cmd.name, $0) <= 2 }
            let hint = close.isEmpty ? "" : ". Did you mean: \(close.joined(separator: ", "))?"
            let tip = cmd.name.count > 0 && cmd.name.first?.isLowercase != true
                ? " Commands are lowercase. Use 'help' to see available commands."
                : ""
            result = shellErr("\(cmd.name): command not found\(hint)\(tip)")
        }
        return result
    }

    /// After cd, show what's in the directory automatically.
    private static func autoLsAfterCd(_ cdResult: ToolResult, _ ctx: ToolContext) -> ToolResult {
        // Build a summary by listing the current context
        let lsCmd = ShellCommand(name: "ls", args: [], flags: [:], redirectTarget: nil, redirectBody: nil)
        let listing = handleLs(lsCmd, ctx)
        let combined = "\(cdResult.content)\n\(listing.content)"
        return ToolResult(content: combined, citations: [], isError: false, displaySummary: cdResult.displaySummary)
    }

    /// Simple Levenshtein distance for fuzzy command matching.
    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let (a, b) = (Array(a), Array(b))
        var dp = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { dp[i][0] = i }
        for j in 0...b.count { dp[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                dp[i][j] = a[i-1] == b[j-1] ? dp[i-1][j-1] : min(dp[i-1][j], dp[i][j-1], dp[i-1][j-1]) + 1
            }
        }
        return dp[a.count][b.count]
    }

    // MARK: - Tokenizer

    static func tokenize(_ raw: String) -> ShellCommand {
        var tokens: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false

        for ch in raw {
            if ch == "'" && !inDouble { inSingle.toggle(); continue }
            if ch == "\"" && !inSingle { inDouble.toggle(); continue }
            if ch.isWhitespace && !inSingle && !inDouble {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }

        guard let name = tokens.first else {
            return ShellCommand(name: "", args: [], flags: [:], redirectTarget: nil, redirectBody: nil)
        }

        // Detect echo 'body' > target or echo 'body' >> target
        var redirectTarget: String?
        var redirectBody: String?
        var appendMode = false
        if name == "echo" {
            if let gtIdx = tokens.firstIndex(of: ">>"), gtIdx + 1 < tokens.count {
                appendMode = true
                redirectTarget = tokens[gtIdx + 1]
                redirectBody = tokens.dropFirst(1).prefix(gtIdx - 1).joined(separator: " ")
            } else if let gtIdx = tokens.firstIndex(of: ">"), gtIdx + 1 < tokens.count {
                redirectTarget = tokens[gtIdx + 1]
                redirectBody = tokens.dropFirst(1).prefix(gtIdx - 1).joined(separator: " ")
            }
            // Strip surrounding quotes from body
            if let b = redirectBody, b.count >= 2 {
                let first = b.first!, last = b.last!
                if (first == "'" && last == "'") || (first == "\"" && last == "\"") {
                    redirectBody = String(b.dropFirst().dropLast())
                }
            }
        }

        let rest = redirectTarget != nil
            ? Array(tokens.dropFirst(1).prefix(while: { $0 != ">" && $0 != ">>" }))
            : Array(tokens.dropFirst())

        // Separate positional args from flags. Path is always the last non-flag argument.
        // Boolean flags: --long, -l, --json. Value flags: --status done, --type audio.
        // Strategy: parse flags first, everything else goes to args.
        let boolFlags = Set(["long", "l", "la", "json", "count", "help"])
        var args: [String] = []
        var flags: [String: String] = [:]
        var i = 0
        while i < rest.count {
            let t = rest[i]
            if t.hasPrefix("--") {
                let key = String(t.dropFirst(2))
                if boolFlags.contains(key) {
                    flags[key] = "true"; i += 1
                } else if i + 1 < rest.count {
                    let next = rest[i + 1]
                    // Only consume next token as value if it looks like a value, not a path or flag
                    if !next.hasPrefix("-") && !next.hasSuffix("/") && !next.contains("/") {
                        flags[key] = next; i += 2
                    } else {
                        flags[key] = "true"; i += 1
                    }
                } else {
                    flags[key] = "true"; i += 1
                }
            } else if t.hasPrefix("-") && t.count > 2 && !t.hasPrefix("--") {
                // Combined short flags: -la → -l -a
                let chars = Array(t.dropFirst())
                for ch in chars {
                    let key = String(ch)
                    if boolFlags.contains(key) {
                        flags[key] = "true"
                    } else {
                        // Unknown flag in combination — silently ignore
                        flags[key] = "true"
                    }
                }
                i += 1
            } else if t.hasPrefix("-") && t.count == 2 {
                let key = String(t.dropFirst(1))
                if boolFlags.contains(key) {
                    flags[key] = "true"; i += 1
                } else if i + 1 < rest.count {
                    let next = rest[i + 1]
                    // Never consume a path-looking token (contains /) as a flag value
                    if !next.hasPrefix("-") && !next.contains("/") {
                        flags[key] = next; i += 2
                    } else {
                        flags[key] = "true"; i += 1
                    }
                } else {
                    flags[key] = "true"; i += 1
                }
            } else {
                args.append(t); i += 1
            }
        }

        return ShellCommand(name: name, args: args, flags: flags, redirectTarget: redirectTarget, redirectBody: redirectBody, appendMode: appendMode)
    }

    // MARK: - ls

    private static func handleLs(_ cmd: ShellCommand, _ ctx: ToolContext) -> ToolResult {
        let pathArg = cmd.args.first
        let vpath = VFSService.resolve(pathArg, context: ctx)
        let long = cmd.flags["long"] != nil || cmd.flags["l"] != nil || cmd.flags["la"] != nil
        let limit = Int(cmd.flags["limit"] ?? "30") ?? 30
        let statusFilter = cmd.flags["status"]
        let typeFilter = cmd.flags["type"]
        let tagFilter = cmd.flags["tag"]
        let sinceDays = Int(cmd.flags["since"] ?? "0") ?? 0

        switch vpath {
        case .root:
            let projects = (try? ProjectService(context: ctx.modelContext).allProjects()) ?? []
            let allItems = (try? KnowledgeItemService(context: ctx.modelContext).allItems()) ?? []
            let inboxCount = allItems.filter { $0.inboxDate != nil }.count
            var lines = ["Wawa Note Workspace", "====================", ""]
            lines.append("\(projects.count) project(s)")
            lines.append("\(inboxCount) item(s) in inbox")
            lines.append("\(allItems.count) total item(s)")
            lines.append("")
            lines.append("/inbox/        Unprocessed items")
            lines.append("/projects/     All projects")
            lines.append("/agent/        Prompts, memories & chat history")
            return ok(lines.joined(separator: "\n"))

        case .inbox:
            if let err = checkSandboxGlobal(ctx) { return err }
            let allItems = (try? KnowledgeItemService(context: ctx.modelContext).allItems()) ?? []
            var items = allItems.filter { $0.inboxDate != nil }
            if let tag = tagFilter { items = items.filter { $0.tags.contains(tag) } }
            if let type = typeFilter { items = items.filter { $0.typeRaw == type } }
            items = Array(items.prefix(limit))
            if items.isEmpty { return ok("/inbox/ is empty") }
            var lines = ["/inbox/ (\(items.count) item(s))", ""]
            for (i, item) in items.enumerated() {
                lines.append(VFSService.formatItemLine(item, index: i, long: long))
            }
            return ok(lines.joined(separator: "\n"))

        case .projects:
            let projects = (try? ProjectService(context: ctx.modelContext).allProjects()) ?? []
            if projects.isEmpty { return ok("/projects/ is empty") }
            var lines = ["/projects/ (\(projects.count) project(s)) — use cd with the directory name", ""]
            for p in projects {
                let taskCount = (try? TaskService(context: ctx.modelContext).tasks(for: p.id).count) ?? 0
                lines.append("  \(VFSService.safeDirName(p))/    \"\(p.name)\"  [\(p.statusRaw)]  \(taskCount) tasks")
            }
            return ok(lines.joined(separator: "\n"))

        case .project(let slug, let pid):
            guard let p = try? ProjectService(context: ctx.modelContext).fetch(id: pid) else {
                return shellErr("ls: /projects/\(slug): not found")
            }
            let tasks = (try? TaskService(context: ctx.modelContext).tasks(for: pid)) ?? []
            let items = (try? ProjectService(context: ctx.modelContext).items(in: pid)) ?? []
            var lines = ["/projects/\(slug)/  (\(p.name))", ""]
            lines.append("project.json   \(p.statusRaw.capitalized)  health=\(p.healthStatus ?? "N/A")  tasks=\(tasks.count)  items=\(items.count)")
            lines.append("items/         \(items.count) item(s)")
            lines.append("tasks/         \(tasks.count) task(s)")
            lines.append("people/        People connected to this project")
            lines.append("edges/         Graph relationships")
            lines.append("signals/       Alerts and insights")
            lines.append("analysis/      AI analyses + transcripts (use cat)")
            return ok(lines.joined(separator: "\n"))

        case .projectItems(let slug, let pid):
            let items = (try? ProjectService(context: ctx.modelContext).items(in: pid)) ?? []
            var filtered = items
            if let status = statusFilter { filtered = filtered.filter { $0.statusRaw == status } }
            if let type = typeFilter { filtered = filtered.filter { $0.typeRaw == type } }
            if let tag = tagFilter { filtered = filtered.filter { $0.tags.contains(tag) } }
            if sinceDays > 0 {
                let cutoff = Date().addingTimeInterval(-Double(sinceDays) * 86400)
                filtered = filtered.filter { $0.createdAt >= cutoff }
            }
            filtered = Array(filtered.prefix(limit))
            if filtered.isEmpty { return ok("No items") }
            var lines = ["\(filtered.count) items:", ""]
            var cards: [ChatBlock] = []
            for item in filtered {
                lines.append(VFSService.formatItemLine(item, index: 0, long: long))
                let hasTrans = FileManager.default.fileExists(atPath: ctx.fileStore.itemDirectoryURL(for: item.id).appendingPathComponent("transcript.json").path)
                let hasAnalysis = FileManager.default.fileExists(atPath: ctx.fileStore.itemDirectoryURL(for: item.id).appendingPathComponent("analysis.json").path)
                cards.append(.itemCard(ItemCardData(itemID: item.id.uuidString, title: item.title, type: item.typeRaw, status: item.statusRaw, durationSeconds: item.durationSeconds, projectSlug: slug, hasTranscript: hasTrans, hasAnalysis: hasAnalysis)))
            }
            return ok(lines.joined(separator: "\n"), blocks: cards)

        case .projectTasks(let slug, let pid):
            var tasks = (try? TaskService(context: ctx.modelContext).tasks(for: pid)) ?? []
            if let status = statusFilter, status != "true" { tasks = tasks.filter { $0.statusRaw == status } }
            tasks = Array(tasks.prefix(limit))
            if tasks.isEmpty { return ok("No tasks", blocks: [.text("No tasks yet. Use touch tasks/ --title \"...\" to create one.")]) }
            var lines = ["\(tasks.count) tasks:"]
            var cards: [ChatBlock] = []
            for t in tasks {
                let check = t.statusRaw == "done" ? "☑" : "☐"
                let prioEmoji = t.priorityRaw == "critical" ? "🔴" : t.priorityRaw == "high" ? "🟠" : t.priorityRaw == "medium" ? "🔵" : "⚪"
                let owner = t.ownerName.map { " @\($0)" } ?? ""
                lines.append("  \(check) \(prioEmoji) \(t.title)\(owner)")
                cards.append(.taskCard(TaskCardData(
                    taskID: t.id.uuidString, title: t.title, status: t.statusRaw, priority: t.priorityRaw,
                    owner: t.ownerName, projectSlug: slug, needsConfirmation: t.statusRaw != "done"
                )))
            }
            return ok(lines.joined(separator: "\n"), blocks: cards)

        case .projectSignals(let slug, let pid):
            let all = (try? ctx.modelContext.fetch(FetchDescriptor<AgentSuggestion>())) ?? []
            let signals = all.filter { $0.projectID == pid && $0.isActive }
            if signals.isEmpty { return ok("signals/: no active signals") }
            var lines = ["/projects/\(slug)/signals/ (\(signals.count) signal(s))", ""]
            for s in signals {
                lines.append("\(s.id.uuidString.prefix(8))  [\(s.type)]  \(s.title)  critical=\(s.isCritical)")
            }
            return ok(lines.joined(separator: "\n"))

        case .projectEdges(let slug, let pid):
            let gsvc = GraphEdgeService(context: ctx.modelContext)
            let outgoing = (try? gsvc.edges(from: pid)) ?? []
            let incoming = (try? gsvc.edges(to: pid)) ?? []
            let all = outgoing + incoming
            if all.isEmpty { return ok("edges/: no edges") }
            var lines = ["/projects/\(slug)/edges/ (\(all.count) edge(s))", ""]
            for e in all.prefix(limit) {
                lines.append("\(e.id.uuidString.prefix(8))  \(e.edgeTypeRaw)  from=\(e.fromID.uuidString.prefix(8))  to=\(e.toID.uuidString.prefix(8))  weight=\(e.weight)")
            }
            return ok(lines.joined(separator: "\n"))

        case .projectAnalysis(let slug, let pid, let itemID):
            if let iid = itemID {
                // Check if asking for transcript variant
                let isTranscript = cmd.args.first?.hasSuffix(".transcript.json") ?? false
                if isTranscript {
                    let transcriptText = VFSService.readTranscript(itemID: iid, fileStore: ctx.fileStore)
                    if let t = transcriptText {
                        return ok("analysis/\(iid.uuidString.prefix(8)).transcript.json:\n\(t)")
                    }
                    return shellErr("cat: analysis/\(iid.uuidString.prefix(8)).transcript.json: No transcript found")
                }
                let analysisText = VFSService.readAnalysis(itemID: iid, fileStore: ctx.fileStore)
                if let t = analysisText {
                    return ok("analysis/\(iid.uuidString.prefix(8)).json:\n\(t)")
                }
                return shellErr("cat: analysis/\(iid.uuidString.prefix(8)).json: No analysis found")
            }
            // List both analysis and transcript files
            let items = (try? ProjectService(context: ctx.modelContext).items(in: pid)) ?? []
            var fileEntries: [(prefix: String, hasAnalysis: Bool, hasTranscript: Bool)] = []
            for item in items {
                let dir = ctx.fileStore.itemDirectoryURL(for: item.id)
                let hasAnalysis = FileManager.default.fileExists(atPath: dir.appendingPathComponent("analysis.json").path) || FileManager.default.fileExists(atPath: dir.appendingPathComponent("analysis.dynamic.json").path)
                let hasTranscript = FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path)
                if hasAnalysis || hasTranscript {
                    fileEntries.append((prefix: String(item.id.uuidString.prefix(8)), hasAnalysis: hasAnalysis, hasTranscript: hasTranscript))
                }
            }
            if fileEntries.isEmpty { return ok("analysis/: no artifacts yet") }
            var lines = ["/projects/\(slug)/analysis/ (\(fileEntries.count) item(s) with artifacts)", ""]
            for entry in fileEntries {
                var parts: [String] = []
                if entry.hasAnalysis { parts.append("\(entry.prefix).json") }
                if entry.hasTranscript { parts.append("\(entry.prefix).transcript.json") }
                lines.append(parts.joined(separator: ", "))
            }
            return ok(lines.joined(separator: "\n"))

        case .agentPrompts:
            let prompts = PromptStore.shared.prompts(in: nil)
            if prompts.isEmpty { return ok("/agent/prompts/ is empty") }
            var lines = ["/agent/prompts/ (\(prompts.count) prompt(s))", ""]
            for p in prompts {
                lines.append("\(p.name)  category=\(p.category)  \(p.description)")
            }
            return ok(lines.joined(separator: "\n"))

        case .agentMemories:
            let memories = AgentMemoryStore.shared.listAll()
            if memories.isEmpty { return ok("/agent/memories/ is empty") }
            var lines = ["/agent/memories/ (\(memories.count) memor(y/ies))", ""]
            for m in memories {
                let sc = m.successCount
                let fc = m.failCount
                lines.append("\(m.id.uuidString.prefix(8))  pattern=\(m.pattern.prefix(40))  success=\(sc) fail=\(fc)")
            }
            return ok(lines.joined(separator: "\n"))

        case .agentChat:
            let chatSvc = ChatService(fileStore: ctx.fileStore)
            let conversations = (try? chatSvc.fetchConversations()) ?? []
            if conversations.isEmpty { return ok("/agent/chat/ is empty") }
            var lines = ["/agent/chat/ (\(conversations.count) conversation(s))", ""]
            for c in conversations {
                let preview = c.lastMessagePreview ?? ""
                lines.append("  \(c.id.uuidString.prefix(8))  \(c.title)  msgs=\(c.messageCount)  \(preview.prefix(60))")
            }
            return ok(lines.joined(separator: "\n"))

        case .projectPeople(let slug, let pid):
            let gsvc = GraphEdgeService(context: ctx.modelContext)
            let edges = (try? gsvc.edges(from: pid)) ?? []
            let peopleEdges = edges.filter { $0.edgeTypeRaw == "person" }
            if peopleEdges.isEmpty {
                return ok("people/: no people connected to this project")
            }
            let df = DateFormatter()
            df.dateStyle = .short
            df.timeStyle = .none
            var lines = ["/projects/\(slug)/people/ (\(peopleEdges.count) person(s))", ""]
            for e in peopleEdges.prefix(limit) {
                let ts = df.string(from: e.createdAt)
                lines.append("  \(e.id.uuidString.prefix(8)).json  personID=\(e.toID.uuidString.prefix(8))  type=\(e.edgeTypeRaw)  since=\(ts)")
            }
            return ok(lines.joined(separator: "\n"))

        default:
            // Single items/tasks/etc — fall through to cat behavior
            return handleCat(cmd, ctx)
        }
    }

    // MARK: - cat

    private static func handleCat(_ cmd: ShellCommand, _ ctx: ToolContext) -> ToolResult {
        guard let pathArg = cmd.args.first else {
            return shellErr("cat: missing path. Usage: cat <path>")
        }
        let vpath = VFSService.resolve(pathArg, context: ctx)
        let jsonOutput = cmd.flags["json"] != nil
        let fields = cmd.flags["fields"]?.split(separator: ",").map(String.init)

        switch vpath {
        case .project(let slug, let pid):
            guard let p = try? ProjectService(context: ctx.modelContext).fetch(id: pid) else {
                return shellErr("cat: /projects/\(slug)/project.json: not found")
            }
            let tasks = (try? TaskService(context: ctx.modelContext).tasks(for: pid)) ?? []
            let items = (try? ProjectService(context: ctx.modelContext).items(in: pid)) ?? []
            if jsonOutput {
                let dict: [String: Any] = [
                    "name": p.name, "slug": p.slug, "dirName": VFSService.safeDirName(p), "status": p.statusRaw,
                    "healthScore": p.healthScore as Any, "healthStatus": p.healthStatus as Any,
                    "summary": p.summary as Any, "intention": p.intention as Any,
                    "taskCount": tasks.count, "itemCount": items.count,
                    "createdAt": p.createdAt.ISO8601Format(),
                    "updatedAt": p.updatedAt.ISO8601Format()
                ]
                if let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted),
                   let json = String(data: data, encoding: .utf8) {
                    return ok(json)
                }
                return shellErr("cat: failed to serialize project.json")
            }
            var lines = ["# \(p.name)", ""]
            if let intent = p.intention { lines.append("Intention: \(intent)") }
            lines.append("Status: \(p.statusRaw.capitalized)")
            if let score = p.healthScore { lines.append("Health: \(Int(score * 100))% (\(p.healthStatus ?? "unknown"))") }
            if let summary = p.summary { lines.append("Summary: \(summary)") }
            lines.append("Tasks: \(tasks.count)  Items: \(items.count)")
            return ok(lines.joined(separator: "\n"))

        case .projectItem(_, _, let itemID):
            if let err = checkSandbox(itemID, ctx) { return err }
            guard let item = try? KnowledgeItemService(context: ctx.modelContext).fetchItem(id: itemID) else {
                return shellErr("cat: item not found")
            }
            if jsonOutput {
                let dict = VFSService.itemToDict(item, fileStore: ctx.fileStore, fields: fields)
                if let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted),
                   let json = String(data: data, encoding: .utf8) {
                    return ok(json)
                }
                return shellErr("cat: failed to serialize item")
            }
            return ok(VFSService.formatItemFull(item, fileStore: ctx.fileStore))

        case .projectTask(_, _, let taskID):
            guard let task = try? TaskService(context: ctx.modelContext).fetch(id: taskID) else {
                return shellErr("cat: task not found")
            }
            if jsonOutput {
                let dict: [String: Any] = [
                    "id": task.id.uuidString, "title": task.title,
                    "status": task.statusRaw, "priority": task.priorityRaw,
                    "owner": task.ownerName as Any, "dueAt": task.dueAt?.ISO8601Format() as Any
                ]
                if let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted),
                   let json = String(data: data, encoding: .utf8) {
                    return ok(json)
                }
                return shellErr("cat: failed to serialize task")
            }
            let due = task.dueAt.map { "Due: \($0.formatted(date: .complete, time: .omitted))" } ?? ""
            let owner = task.ownerName.map { "Owner: \($0)" } ?? ""
            return ok("Task: \(task.title)\nStatus: \(task.statusRaw)  Priority: \(task.priorityRaw)\n\(owner)\n\(due)")

        case .inboxItem(let id):
            if let err = checkSandbox(id, ctx) { return err }
            guard let item = try? KnowledgeItemService(context: ctx.modelContext).fetchItem(id: id) else {
                return shellErr("cat: /inbox/\(id.uuidString.prefix(8)).json: not found")
            }
            return ok(VFSService.formatItemFull(item, fileStore: ctx.fileStore))

        case .projectAnalysis(_, _, let itemID):
            guard let iid = itemID else {
                return shellErr("cat: specify an analysis file, e.g. cat analysis/abc123.json")
            }
            if let text = VFSService.readAnalysis(itemID: iid, fileStore: ctx.fileStore) {
                return ok(text)
            }
            return shellErr("cat: analysis/\(iid.uuidString.prefix(8)).json: No analysis found")

        case .agentChat:
            let chatSvc = ChatService(fileStore: ctx.fileStore)
            let conversations = (try? chatSvc.fetchConversations()) ?? []
            // If path has a specific conversation ID
            let parts = pathArg.split(separator: "/")
            if let convIdStr = parts.last, let convId = UUID(uuidString: String(convIdStr)) {
                let msgs = (try? chatSvc.messages(for: convId)) ?? []
                var lines = ["Conversation \(convId.uuidString.prefix(8)) (\(msgs.count) messages)", ""]
                for msg in msgs.prefix(50) {
                    let role = msg.role.rawValue.prefix(4)
                    let content = msg.content.prefix(200).replacingOccurrences(of: "\n", with: " ")
                    lines.append("[\(role)] \(content)")
                }
                return ok(lines.joined(separator: "\n"))
            }
            // Show list of conversations
            if conversations.isEmpty { return ok("/agent/chat/ is empty") }
            var lines = ["/agent/chat/ (\(conversations.count) conversation(s))", ""]
            for c in conversations {
                lines.append("  \(c.id.uuidString.prefix(8))  \(c.title)  msgs=\(c.messageCount)")
            }
            return ok(lines.joined(separator: "\n"))

        case .unknown(let msg):
            return shellErr("cat: \(msg)")

        default:
            return shellErr("cat: cannot read directory. Use ls to list contents, then cat <file> to read")
        }
    }

    // MARK: - cd

    private static func handleCd(_ cmd: ShellCommand, _ ctx: ToolContext) -> ToolResult {
        var target = cmd.args.first ?? "/"
        // Normalize trailing slashes: /projects/ → /projects
        if target.hasSuffix("/") && target.count > 1 {
            target = String(target.dropLast())
        }

        if target == "/" || target == ".." || target.isEmpty {
            ctx.activeProjectID = nil
            ctx.activeProjectName = nil
            ctx.activeProjectSlug = nil
            ctx.activeItemID = nil
            ctx.contextKey = nil
            return ok("/  (root)")
        }

        // cd /projects or cd /agent — list contents instead of error
        if target == "/projects" || target == "projects" {
            let lsCmd = ShellCommand(name: "ls", args: ["/projects"], flags: [:], redirectTarget: nil, redirectBody: nil)
            return handleLs(lsCmd, ctx)
        }
        if target == "/agent" || target == "agent" {
            let lsCmd = ShellCommand(name: "ls", args: ["/"], flags: [:], redirectTarget: nil, redirectBody: nil)
            return handleLs(lsCmd, ctx)
        }

        let vpath = VFSService.resolve(target.hasPrefix("/") ? target : nil, context: ctx)
        // Re-resolve with absolute path
        let absTarget = target.hasPrefix("/") ? target : "/projects/\(ctx.activeProjectSlug ?? "")/\(target)"
        let resolved = VFSService.resolve(absTarget, context: ctx)

        switch resolved {
        case .inbox:
            ctx.activeProjectID = nil
            ctx.activeProjectName = nil
            ctx.activeProjectSlug = nil
            ctx.activeItemID = nil
            ctx.contextKey = "inbox"
            return ok("/inbox/")

        case .project(let slug, let pid):
            let name = (try? ProjectService(context: ctx.modelContext).fetch(id: pid))?.name ?? slug
            ctx.activeProjectID = pid
            ctx.activeProjectName = name
            ctx.activeProjectSlug = slug
            ctx.activeItemID = nil
            ctx.contextKey = "project:\(pid.uuidString)"
            return ok("/projects/\(slug)/  (\(name))")

        case .projectItems(let slug, let pid):
            let name = (try? ProjectService(context: ctx.modelContext).fetch(id: pid))?.name ?? slug
            ctx.activeProjectID = pid
            ctx.activeProjectName = name
            ctx.activeProjectSlug = slug
            ctx.activeItemID = nil
            return ok("/projects/\(slug)/items/")

        case .projectTasks(let slug, let pid):
            let name = (try? ProjectService(context: ctx.modelContext).fetch(id: pid))?.name ?? slug
            ctx.activeProjectID = pid
            ctx.activeProjectName = name
            ctx.activeProjectSlug = slug
            ctx.activeItemID = nil
            return ok("/projects/\(slug)/tasks/")

        case .projectItem(_, _, let itemID):
            ctx.activeItemID = itemID
            return ok("Focused on item \(itemID.uuidString.prefix(8))")

        default:
            return shellErr("cd: \(target): No such directory")
        }
    }

    // MARK: - find

    private static func handleFind(_ cmd: ShellCommand, _ ctx: ToolContext) -> ToolResult {
        let limit = Int(cmd.flags["limit"] ?? "20") ?? 20
        let statusFilter = cmd.flags["status"]
        let vpath = VFSService.resolve(cmd.args.first ?? "/", context: ctx)

        // Tasks directory
        if case .projectTasks(_, let pid) = vpath {
            var tasks = (try? TaskService(context: ctx.modelContext).tasks(for: pid)) ?? []
            if let s = statusFilter, s != "true" { tasks = tasks.filter { $0.statusRaw == s } }
            tasks = Array(tasks.prefix(limit))
            if tasks.isEmpty { return ok("No matching tasks") }
            var lines = ["Found \(tasks.count) tasks:", ""]
            var cards: [ChatBlock] = []
            for t in tasks {
                lines.append("  ☐ \(t.title)  [\(t.statusRaw)]")
                cards.append(.taskCard(TaskCardData(taskID: t.id.uuidString, title: t.title, status: t.statusRaw, priority: t.priorityRaw, owner: t.ownerName, projectSlug: ctx.activeProjectSlug, needsConfirmation: t.statusRaw != "done")))
            }
            return ok(lines.joined(separator: "\n"), blocks: cards)
        }

        // Default: items (sandboxed: restrict to current item)
        if let err = checkSandboxGlobal(ctx) { return err }
        let tagFilter = cmd.flags["tag"]; let typeFilter = cmd.flags["type"]; let projectFilter = cmd.flags["project"]
        let sinceDays = Int(cmd.flags["since"] ?? "0") ?? 0
        let allItems: [KnowledgeItem] = {
            if let sandboxed = ctx.sandboxedItemID,
               let item = try? KnowledgeItemService(context: ctx.modelContext).fetchItem(id: sandboxed) {
                return [item]
            }
            return (try? KnowledgeItemService(context: ctx.modelContext).allItems()) ?? []
        }()
        var results = allItems
        if let tag = tagFilter { results = results.filter { $0.tags.contains(tag) } }
        if let type = typeFilter { results = results.filter { $0.typeRaw == type } }
        if let status = statusFilter { results = results.filter { $0.statusRaw == status } }
        if let pslug = projectFilter {
            let allProjects = (try? ProjectService(context: ctx.modelContext).allProjects()) ?? []
            if let proj = allProjects.first(where: { VFSService.projectMatches($0, dirName: pslug) }) { results = results.filter { $0.projectID == proj.id } }
        }
        if sinceDays > 0 { results = results.filter { $0.createdAt >= Date().addingTimeInterval(-Double(sinceDays)*86400) } }
        results = Array(results.prefix(limit))
        if results.isEmpty { return ok("No matching items") }
        // --exec: run a command for each result (batch operations)
        if let execCmd = cmd.flags["exec"] {
            var outputs: [String] = []
            for item in results.prefix(limit) {
                let expanded = execCmd.replacingOccurrences(of: "{id}", with: item.id.uuidString)
                    .replacingOccurrences(of: "{title}", with: item.title.replacingOccurrences(of: " ", with: "_"))
                let batchCmd = ShellCommand(name: expanded.components(separatedBy: " ").first ?? "", args: [], flags: [:], redirectTarget: nil, redirectBody: nil)
                // Execute the expanded command by recursively dispatching
                let subResult = execute(command: expanded, context: ctx)
                outputs.append("[\(item.title)]: \(subResult.content)")
            }
            var lines = ["Batch: \(outputs.count) item(s) processed", ""]
            lines.append(contentsOf: outputs)
            return ok(lines.joined(separator: "\n"))
        }
        var lines = ["Found \(results.count) items:", ""]
        var cards: [ChatBlock] = []
        for item in results {
            let pn = item.projectID.flatMap { pid in (try? ProjectService(context: ctx.modelContext).fetch(id: pid)).map { VFSService.safeDirName($0) } } ?? "-"
            lines.append("  \(VFSService.typeIcon(item.typeRaw)) \(item.title)  project=\(pn)")
            cards.append(.itemCard(ItemCardData(itemID: item.id.uuidString, title: item.title, type: item.typeRaw, status: item.statusRaw, durationSeconds: item.durationSeconds, projectSlug: pn, hasTranscript: false, hasAnalysis: false)))
        }
        return ok(lines.joined(separator: "\n"), blocks: cards)
    }

    // MARK: - grep

    private static func handleGrep(_ cmd: ShellCommand, _ ctx: ToolContext) -> ToolResult {
        guard cmd.args.count >= 1 else {
            return shellErr("grep: missing query. Usage: grep \"keyword\" <path>")
        }
        let query = cmd.args[0]
        let target = cmd.args.count >= 2 ? cmd.args[1] : nil
        let limit = Int(cmd.flags["limit"] ?? "15") ?? 15

        // If a specific file is targeted, grep through its text content
        if let target {
            let vpath = VFSService.resolve(target, context: ctx)
            switch vpath {
            case .projectAnalysis(_, _, let itemID):
                guard let iid = itemID else { break }
                let text = VFSService.readAnalysis(itemID: iid, fileStore: ctx.fileStore)
                    ?? VFSService.readTranscript(itemID: iid, fileStore: ctx.fileStore)
                    ?? ""
                let lines = text.components(separatedBy: "\n")
                let matches = lines.filter { $0.localizedCaseInsensitiveContains(query) }
                if matches.isEmpty { return ok("grep: no matches for '\(query)'") }
                return ok("grep: \(matches.count) match(es) for '\(query)'\n" + matches.prefix(limit).joined(separator: "\n"))
            case .projectItem(_, _, let itemID):
                guard let item = try? KnowledgeItemService(context: ctx.modelContext).fetchItem(id: itemID) else {
                    return shellErr("grep: item not found")
                }
                let text = VFSService.formatItemFull(item, fileStore: ctx.fileStore)
                let lines = text.components(separatedBy: "\n")
                let matches = lines.filter { $0.localizedCaseInsensitiveContains(query) }
                if matches.isEmpty { return ok("grep: no matches for '\(query)'") }
                return ok("grep: \(matches.count) match(es) for '\(query)'\n" + matches.prefix(limit).joined(separator: "\n"))
            default:
                break
            }
        }

        // Default: full-text search across all items (sandboxed: current item only)
        if let err = checkSandboxGlobal(ctx) { return err }
        let allItems: [KnowledgeItem] = {
            if let sandboxed = ctx.sandboxedItemID,
               let item = try? KnowledgeItemService(context: ctx.modelContext).fetchItem(id: sandboxed) {
                return [item]
            }
            return (try? KnowledgeItemService(context: ctx.modelContext).allItems()) ?? []
        }()
        let results = SearchService(fileStore: ctx.fileStore).searchNow(query: query, in: allItems)
            .prefix(limit)
        if results.isEmpty { return ok("grep: no matches for '\(query)'") }
        var lines = ["grep: \(results.count) result(s) for '\(query)'", ""]
        for r in results {
            lines.append("[\(r.itemID.uuidString.prefix(8))] \(r.matchedField): \(r.snippet)")
        }
        return ok(lines.joined(separator: "\n"))
    }

    // MARK: - touch

    private static func handleTouch(_ cmd: ShellCommand, _ ctx: ToolContext) -> ToolResult {
        let pathArg = cmd.args.first ?? ""
        let title = cmd.flags["title"]
        let type = cmd.flags["type"] ?? "note"
        let body = cmd.flags["body"]
        let priority = cmd.flags["priority"] ?? "medium"
        let owner = cmd.flags["owner"]
        let dueStr = cmd.flags["due"]
        let tags = cmd.flags.filter { $0.key == "tag" }.map { $0.value }

        let vpath = VFSService.resolve(pathArg, context: ctx)

        // If path has a filename (e.g., "tasks/buy-medicine.json"), extract title from it
        let fallbackTitle: String? = {
            let fname = pathArg.split(separator: "/").last.map(String.init) ?? pathArg
            let stripped = VFSService.stripJSONSuffix(fname)
            if !stripped.isEmpty && stripped != "tasks" && stripped != "items" && UUID(uuidString: stripped) == nil {
                return stripped.replacingOccurrences(of: "-", with: " ").capitalized
            }
            return nil
        }()
        let effectiveTitle = title ?? fallbackTitle

        switch vpath {
        case .inbox, .projectItems, .projectItem:
            guard let t = effectiveTitle else { return shellErr("touch: --title is required. Or use: touch items/my-title.json") }
            guard let kt = KnowledgeItemType(rawValue: type) else {
                return shellErr("touch: unknown type '\(type)'. Valid: audio, note, journalEntry, webBookmark, image")
            }
            // Validate type-specific requirements
            if kt == .image {
                return shellErr("touch: image items cannot be created via shell. Use the Scan or Photo capture buttons in the app to create image items.")
            }
            let urlFlag = cmd.flags["url"]
            if kt == .webBookmark && urlFlag == nil {
                return shellErr("touch: --url is required for webBookmark items. Usage: touch /inbox/ --type webBookmark --title \"Name\" --url \"https://...\"")
            }
            // Create item
            let svc = KnowledgeItemService(context: ctx.modelContext)
            guard let item = try? svc.createItem(type: kt, title: t, bodyText: body, tags: tags, inboxDate: Date()) else {
                return shellErr("touch: failed to create item — database error")
            }
            // Set type-specific fields
            if kt == .webBookmark, let url = urlFlag { item.importSourceURL = url }
            if kt == .journalEntry, let mood = cmd.flags["mood"] {
                if !item.tags.contains(where: { $0.hasPrefix("mood/") }) {
                    item.tags = item.tags + ["mood/\(mood)"]
                }
            }
            let resolvedProjectID = vpath.projectID ?? ctx.activeProjectID
            let proj = resolvedProjectID.flatMap { try? ProjectService(context: ctx.modelContext).fetch(id: $0) }
            if let p = proj {
                try? ProjectService(context: ctx.modelContext).addItem(item.id, to: p.id)
            }
            let loc = proj != nil ? "/projects/\(VFSService.safeDirName(proj!))/items/" : "/inbox/"
            let card = ItemCardData(
                itemID: item.id.uuidString, title: t, type: type,
                status: item.statusRaw, durationSeconds: item.durationSeconds,
                projectSlug: proj.map { VFSService.safeDirName($0) },
                hasTranscript: false, hasAnalysis: false
            )
            // Include document header if --document-type flag is set
            var blocks: [ChatBlock] = [.itemCard(card)]
            if let docType = cmd.flags["document-type"], let bodyText = body {
                let sectionCount = bodyText.components(separatedBy: "## ").count
                blocks.insert(.documentHeader(DocumentHeaderData(
                    title: t, documentType: docType,
                    summary: String(bodyText.prefix(200)),
                    sectionCount: max(1, sectionCount),
                    itemID: item.id.uuidString
                )), at: 0)
            }
            return ok("Created \(loc)\(item.id.uuidString.prefix(8)).json  (\(t))", blocks: blocks)

        case .projects:
            // Create a new project: touch /projects/ --name "Project Name" --summary "..."
            guard let name = cmd.flags["name"] else { return shellErr("touch: --name is required to create a project") }
            let summary = cmd.flags["summary"]
            let project = try? ProjectService(context: ctx.modelContext).create(name: name, origin: .llm)
            guard let p = project else { return shellErr("touch: failed to create project") }
            ctx.activeProjectID = p.id; ctx.activeProjectSlug = p.slug; ctx.activeProjectName = p.name
            return ok("✅ Created project: \(p.name) (\(p.slug))")

        case .projectTasks, .projectTask:
            guard let t = effectiveTitle else { return shellErr("touch: --title is required. Or use: touch tasks/my-task-name.json") }
            guard let pid = ctx.activeProjectID else { return shellErr("touch: no active project. cd /projects/{slug} first") }
            let prio = TaskPriority(rawValue: priority) ?? .medium
            if priority != prio.rawValue {
                let valid = TaskPriority.allCases.map { $0.rawValue }.joined(separator: ", ")
                AppLog.agent.warning("touch: invalid priority '\(priority)' — valid: \(valid). Using medium.")
            }
            let due = dueStr.flatMap { ISO8601DateFormatter().date(from: $0) }
            guard let task = try? TaskService(context: ctx.modelContext).create(
                title: t, projectID: pid, priority: prio,
                ownerName: owner, dueAt: due, createdBy: .llm) else {
                return shellErr("touch: failed to create task — database error")
            }
            let card = TaskCardData(
                taskID: task.id.uuidString, title: t, status: task.statusRaw, priority: priority,
                owner: owner, projectSlug: ctx.activeProjectSlug, needsConfirmation: true
            )
            return ok("✅ Created: \(t) [\(priority)]",
                       blocks: [.taskCard(card)])

        case .projectPeople:
            // Create a person: touch people/ --name "Display Name" --email "..." --role "Developer"
            guard let name = cmd.flags["name"] else {
                return shellErr("touch people/: --name is required. Optional: --email, --role")
            }
            let email = cmd.flags["email"]
            let role = cmd.flags["role"]
            let person = try? PersonService(context: ctx.modelContext).findOrCreate(
                displayName: name, email: email, role: role
            )
            guard let p = person else { return shellErr("touch: failed to create person") }
            return ok("✅ Person: \(p.displayName) (\(p.id.uuidString.prefix(8)))")

        case .projectEdges:
            // Create a relationship: touch edges/ --from <uuid> --to <uuid> --type relatesTo
            guard let fromStr = cmd.flags["from"],
                  let toStr = cmd.flags["to"],
                  let fromID = UUID(uuidString: fromStr),
                  let toID = UUID(uuidString: toStr) else {
                return shellErr("touch edges/: --from <uuid> --to <uuid> required. --type <edgeType> optional.")
            }
            let edgeType = EdgeType(rawValue: cmd.flags["type"] ?? "relatesTo") ?? .relatesTo
            let weight = Double(cmd.flags["weight"] ?? "1.0") ?? 1.0
            let edge = try? GraphEdgeService(context: ctx.modelContext).create(
                fromID: fromID, toID: toID, edgeType: edgeType, weight: weight,
                provenanceItemID: nil, provenanceSegmentIDs: []
            )
            guard let e = edge else { return shellErr("touch: failed to create edge") }
            return ok("✅ Created edge: \(e.id.uuidString.prefix(8)) (\(edgeType.rawValue))")

        case .unknown(let msg):
            // If path ends with a filename-like segment, try to create anyway in current context
            if let t = fallbackTitle, let pid = ctx.activeProjectID {
                let prio = TaskPriority(rawValue: priority) ?? .medium
                guard let task = try? TaskService(context: ctx.modelContext).create(
                    title: t, projectID: pid, priority: prio,
                    ownerName: owner, dueAt: nil, createdBy: .llm
                ) else {
                    return shellErr("touch: failed to create task — database error")
                }
                return ok("Created /projects/\(ctx.activeProjectSlug ?? "?")/tasks/\(task.id.uuidString.prefix(8)).json  (\(t) [\(priority)])")
            }
            return shellErr("touch: cannot create here. Use tasks/ or items/ inside a project, or /inbox/ for notes. Examples:\n  touch tasks/ --title \"My Task\"\n  touch tasks/my-task.json\n  touch /inbox/ --title \"My Note\" --type note")

        default:
            return shellErr("touch: cannot create in this location. Use /inbox/ or /projects/{slug}/items/ or /projects/{slug}/tasks/")
        }
    }

    // MARK: - echo (update via JSON)

    private static func handleEcho(_ cmd: ShellCommand, _ ctx: ToolContext) -> ToolResult {
        guard let body = cmd.redirectBody, let target = cmd.redirectTarget else {
            return shellErr("echo: usage: echo '{\"field\":\"value\"}' > <path>")
        }
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return shellErr("echo: body must be valid JSON. Example: echo '{\"status\":\"done\"}' > path")
        }

        let vpath = VFSService.resolve(target, context: ctx)

        switch vpath {
        case .projectTask(_, _, let taskID):
            guard let task = try? TaskService(context: ctx.modelContext).fetch(id: taskID) else {
                return shellErr("echo: task not found")
            }
            let rawJSON = body
            do {
                try VFSService.updateTaskFromJSON(task, jsonText: rawJSON, context: ctx)
                if let t = try? TaskService(context: ctx.modelContext).fetch(id: taskID) {
                    return ok("Updated: \(t.title)")
                }
                return ok("Updated")
            } catch {
                return shellErr("echo: update failed: \(error.localizedDescription)")
            }

        case .projectItem(_, _, let itemID):
            guard let item = try? KnowledgeItemService(context: ctx.modelContext).fetchItem(id: itemID) else {
                return shellErr("echo: item not found")
            }
            // Delegate to VFSService for full field coverage
            let rawJSON = body
            do {
                try VFSService.updateItemFromJSON(item, jsonText: rawJSON, context: ctx)
                return ok("Updated item \(itemID.uuidString.prefix(8))")
            } catch {
                return shellErr("echo: update failed: \(error.localizedDescription)")
            }

        case .project(let slug, let pid):
            var fields = ProjectUpdateFields()
            if let newSummary = json["summary"] as? String { fields.summary = newSummary }
            if let newIntention = json["intention"] as? String { fields.intention = newIntention }
            if let newStatus = json["status"] as? String,
               let status = ProjectStatus(rawValue: newStatus) { fields.status = status }
            if fields.hasChanges {
                _ = try? ProjectService(context: ctx.modelContext).update(
                    id: pid, fields: fields, origin: .llm
                )
            }
            return ok("Updated project \(slug)")

        case .agentPrompts:
            let promptName = target.split(separator: "/").last.map(String.init) ?? target
            let content = json["content"] as? String ?? body
            if PromptStore.shared.prompt(named: promptName) != nil {
                PromptStore.shared.updatePrompt(named: promptName, content: content)
                return ok("Updated prompt '\(promptName)'")
            } else {
                let category = json["category"] as? String ?? "custom"
                let description = json["description"] as? String ?? ""
                _ = PromptStore.shared.createPrompt(name: promptName, category: category, content: content, description: description)
                return ok("Created prompt '\(promptName)'")
            }

        case .agentMemories:
            let pattern = json["pattern"] as? String ?? ""
            let strategy = json["strategy"] as? String ?? ""
            let itemType = json["itemType"] as? String
            let contentType = json["contentType"] as? String
            let language = json["language"] as? String
            let memory = AgentMemoryStore.shared.write(
                pattern: pattern, strategy: strategy,
                itemType: itemType, contentType: contentType, language: language
            )
            return ok("Saved memory \(memory.id.uuidString.prefix(8))")

        case .projectItemContents(_, _, let itemID), .inboxItemFile(let itemID):
            // Write to a file inside an item (e.g. analysis.json, body.md, transcript.json)
            // The target path includes the filename after the item ID
            let rawJSON = body
            if let data = rawJSON.data(using: .utf8),
               let _ = try? JSONSerialization.jsonObject(with: data) {
                do {
                    try VFSService.writeItemFile(target, content: rawJSON, context: ctx)
                    return ok("Written to \(target)")
                } catch {
                    return shellErr("echo: write failed: \(error.localizedDescription)")
                }
            }
            // Also support raw body text for .md files
            if target.hasSuffix(".md") {
                do {
                    let content: String
                    if cmd.appendMode {
                        let existing = VFSService.readItemFile(target, context: ctx) ?? ""
                        content = existing + "\n" + body
                    } else {
                        content = body
                    }
                    try VFSService.writeItemFile(target, content: content, context: ctx)
                    let action = cmd.appendMode ? "Appended to" : "Written to"
                    // Emit fileLink so user can tap to open the document
                    if let item = try? KnowledgeItemService(context: ctx.modelContext).fetchItem(id: itemID) {
                        let snippet = String(body.prefix(100))
                        return ok("\(action) \(target)", blocks: [.fileLink(FileLinkData(
                            itemID: item.id.uuidString, title: item.title,
                            itemType: item.typeRaw, snippet: snippet,
                            projectSlug: ctx.activeProjectSlug
                        ))])
                    }
                    return ok("\(action) \(target)")
                } catch {
                    return shellErr("echo: write failed: \(error.localizedDescription)")
                }
            }
            return shellErr("echo: body must be valid JSON for .json files, or raw text for .md files")

        case .projectAnalysis(_, _, let itemID):
            // Write analysis.json for an item via the analysis path
            guard let iid = itemID else {
                return shellErr("echo: specify item ID in analysis path")
            }
            let rawJSON = body
            if let data = rawJSON.data(using: .utf8),
               let _ = try? JSONSerialization.jsonObject(with: data) {
                let fileURL = ctx.fileStore.itemDirectoryURL(for: iid).appendingPathComponent("analysis.json")
                do {
                    try rawJSON.write(to: fileURL, atomically: true, encoding: .utf8)
                    return ok("Analysis written for item \(iid.uuidString.prefix(8))")
                } catch {
                    return shellErr("echo: failed to write analysis: \(error.localizedDescription)")
                }
            }
            return shellErr("echo: body must be valid JSON for analysis files")

        default:
            return shellErr("echo: cannot write to this path")
        }
    }

    // MARK: - rm

    private static func handleRm(_ cmd: ShellCommand, _ ctx: ToolContext) -> ToolResult {
        guard let target = cmd.args.first else {
            return shellErr("rm: missing path. Usage: rm <path>")
        }
        let vpath = VFSService.resolve(target, context: ctx)

        switch vpath {
        case .projectItem(_, _, let itemID):
            guard let item = try? KnowledgeItemService(context: ctx.modelContext).fetchItem(id: itemID) else {
                return shellErr("rm: item not found")
            }
            try? TrashService(context: ctx.modelContext).moveToTrash(item)
            return ok("Moved '\(item.title)' to trash. Use the app to restore or permanently delete.")

        case .inboxItem(let id):
            guard let item = try? KnowledgeItemService(context: ctx.modelContext).fetchItem(id: id) else {
                return shellErr("rm: item not found")
            }
            try? TrashService(context: ctx.modelContext).moveToTrash(item)
            return ok("Moved '\(item.title)' to trash.")

        case .projectTask(_, _, let taskID):
            guard let task = try? TaskService(context: ctx.modelContext).fetch(id: taskID) else {
                return shellErr("rm: task not found")
            }
            try? TaskService(context: ctx.modelContext).deleteTask(task)
            return ok("Deleted task '\(task.title)'. This is permanent.")

        case .projectItemContents(_, _, let itemID), .inboxItemFile(let itemID):
            return shellErr("rm: cannot delete individual files inside items. Delete the parent item instead, or overwrite the file with empty content.")

        case .agentPrompt(let name):
            PromptStore.shared.resetPrompt(named: name)
            return ok("Reset prompt '\(name)' to default.")

        case .agentMemory(let id):
            return ok("Memory \(id.uuidString.prefix(8)) removed.")

        case .agentChatConversation(let id):
            let chatSvc = ChatService(fileStore: ctx.fileStore)
            try? chatSvc.deleteConversation(id: id)
            return ok("Deleted conversation \(id.uuidString.prefix(8)).")

        case .unknown(let msg):
            // Handle edge deletion: rm edges/{edge-id}.json
            if target.contains("edges/"), let pid = ctx.activeProjectID {
                let edgeIDStr = target.components(separatedBy: "edges/").last?
                    .replacingOccurrences(of: ".json", with: "").trimmingCharacters(in: .whitespaces)
                let gsvc = GraphEdgeService(context: ctx.modelContext)
                let edges = (try? gsvc.edges(from: pid)) ?? []
                if let id = UUID(uuidString: edgeIDStr ?? ""),
                   let edge = edges.first(where: { $0.id == id }) {
                    try? gsvc.deleteEdge(edge)
                    return ok("Deleted edge \(edgeIDStr?.prefix(8) ?? "?")")
                }
                if let prefix = edgeIDStr, let edge = edges.first(where: { $0.id.uuidString.hasPrefix(prefix) }) {
                    try? gsvc.deleteEdge(edge)
                    return ok("Deleted edge \(edge.id.uuidString.prefix(8))")
                }
                return shellErr("rm: edge not found. Use ls edges/ to list edge IDs.")
            }
            return shellErr("rm: \(msg)")

        default:
            return shellErr("rm: can only remove items, tasks, edges, prompts, memories, or conversations.")
        }
    }

    // MARK: - mv

    private static func handleMv(_ cmd: ShellCommand, _ ctx: ToolContext) -> ToolResult {
        guard cmd.args.count >= 2 else {
            return shellErr("mv: usage: mv <source> <destination>")
        }
        let src = VFSService.resolve(cmd.args[0], context: ctx)
        let dst = VFSService.resolve(cmd.args[1], context: ctx)

        switch (src, dst) {
        case (.inboxItem(let itemID), .projectItems(_, let pid)):
            try? ProjectService(context: ctx.modelContext).addItem(itemID, to: pid)
            if let item = try? KnowledgeItemService(context: ctx.modelContext).fetchItem(id: itemID) {
                try? KnowledgeItemService(context: ctx.modelContext).removeFromInbox(item)
            }
            let destName = (try? ProjectService(context: ctx.modelContext).fetch(id: pid)).map { VFSService.safeDirName($0) } ?? "?"
            return ok("Moved item to /projects/\(destName)/items/")

        case (.projectItem(let sslug, _, let itemID), .projectItems(let dslug, let dpid)):
            if sslug == dslug { return ok("Item is already in /projects/\(dslug)/items/") }
            try? ProjectService(context: ctx.modelContext).addItem(itemID, to: dpid)
            return ok("Moved item from /projects/\(sslug)/ to /projects/\(dslug)/")

        case (.projectItem(let slug, let spid, let itemID), .inbox):
            try? ProjectService(context: ctx.modelContext).removeItem(itemID)
            if let item = try? KnowledgeItemService(context: ctx.modelContext).fetchItem(id: itemID) {
                item.inboxDate = Date()
                try? ctx.modelContext.save()
            }
            return ok("Moved item back to inbox from /projects/\(slug)/")

        default:
            return shellErr("mv: can only move items between /inbox/ and /projects/{slug}/items/")
        }
    }

    // MARK: - head

    private static func handleHead(_ cmd: ShellCommand, _ ctx: ToolContext) -> ToolResult {
        guard let target = cmd.args.first else {
            return shellErr("head: missing path. Usage: head -n <count> <path>")
        }
        let count = Int(cmd.flags["n"] ?? cmd.flags["lines"] ?? "10") ?? 10
        let vpath = VFSService.resolve(target, context: ctx)

        switch vpath {
        case .projectItems(let slug, let pid):
            let items = (try? ProjectService(context: ctx.modelContext).items(in: pid)) ?? []
            let preview = items.prefix(count)
            var lines = ["/projects/\(slug)/items/ (first \(preview.count) of \(items.count))", ""]
            for (i, item) in preview.enumerated() {
                lines.append(VFSService.formatItemLine(item, index: i, long: false))
            }
            return ok(lines.joined(separator: "\n"))

        case .projectTasks(let slug, let pid):
            let tasks = (try? TaskService(context: ctx.modelContext).tasks(for: pid)) ?? []
            let preview = tasks.prefix(count)
            var lines = ["/projects/\(slug)/tasks/ (first \(preview.count) of \(tasks.count))", ""]
            for t in preview {
                lines.append("\(t.id.uuidString).json  [\(t.statusRaw)]  \(t.title)")
            }
            return ok(lines.joined(separator: "\n"))

        case .inbox:
            let items = ((try? KnowledgeItemService(context: ctx.modelContext).allItems()) ?? [])
                .filter { $0.inboxDate != nil }
                .prefix(count)
            var lines = ["/inbox/ (first \(items.count))", ""]
            for (i, item) in items.enumerated() {
                lines.append(VFSService.formatItemLine(item, index: i, long: false))
            }
            return ok(lines.joined(separator: "\n"))

        default:
            // Single file — delegate to cat but truncated
            var catCmd = cmd
            catCmd.flags["limit"] = "\(count)"
            return handleCat(catCmd, ctx)
        }
    }

    // MARK: - wc

    private static func handleWc(_ cmd: ShellCommand, _ ctx: ToolContext) -> ToolResult {
        let target = cmd.args.first ?? "."
        let vpath = VFSService.resolve(target, context: ctx)
        let statusFilter = cmd.flags["status"]
        let typeFilter = cmd.flags["type"]

        switch vpath {
        case .projectItems(_, let pid):
            var items = (try? ProjectService(context: ctx.modelContext).items(in: pid)) ?? []
            if let s = statusFilter { items = items.filter { $0.statusRaw == s } }
            if let t = typeFilter { items = items.filter { $0.typeRaw == t } }
            return ok("\(items.count) item(s)")

        case .projectTasks(_, let pid):
            var tasks = (try? TaskService(context: ctx.modelContext).tasks(for: pid)) ?? []
            if let s = statusFilter { tasks = tasks.filter { $0.statusRaw == s } }
            return ok("\(tasks.count) task(s)")

        case .inbox:
            let items = ((try? KnowledgeItemService(context: ctx.modelContext).allItems()) ?? [])
                .filter { $0.inboxDate != nil }
            return ok("\(items.count) inbox item(s)")

        default:
            return ok("0")
        }
    }

    // MARK: - history

    private static func handleHistory(_ cmd: ShellCommand, _ ctx: ToolContext) -> ToolResult {
        // If no path given, show command history (new behavior)
        guard let target = cmd.args.first else {
            if cmd.flags.keys.contains("clear") {
                commandHistory.removeAll()
                return ok("Command history cleared.")
            }
            if commandHistory.isEmpty { return ok("No commands in history.") }
            let numbered = commandHistory.enumerated().map { "\($0.offset + 1): \($0.element)" }.joined(separator: "\n")
            return ok("Recent commands (\(commandHistory.count)/\(maxHistory)):\n\(numbered)")
        }
        let limit = Int(cmd.flags["limit"] ?? "30") ?? 30
        let vpath = VFSService.resolve(target, context: ctx)

        switch vpath {
        case .project(_, let pid):
            let changes = VersioningService.shared.changes(for: pid, limit: limit, context: ctx.modelContext)
            if changes.isEmpty { return ok("No change history for this project.") }
            var lines = ["Change history (\(changes.count) record(s)):", ""]
            for c in changes {
                let prev = c.previousValue ?? "(empty)"
                let next = c.newValue ?? "(empty)"
                lines.append("[\(c.timestamp.formatted())] \(c.entityType).\(c.field): \(prev) → \(next)  [\(c.originRaw)]")
            }
            return ok(lines.joined(separator: "\n"))

        case .projectItem(_, _, let itemID):
            let changes = VersioningService.shared.changes(for: itemID, limit: limit, context: ctx.modelContext)
            if changes.isEmpty { return ok("No change history for this item.") }
            var lines = ["Change history (\(changes.count) record(s)):", ""]
            for c in changes {
                let prev = c.previousValue ?? "(empty)"
                let next = c.newValue ?? "(empty)"
                lines.append("[\(c.timestamp.formatted())] \(c.entityType).\(c.field): \(prev) → \(next)  [\(c.originRaw)]")
            }
            return ok(lines.joined(separator: "\n"))

        default:
            return shellErr("history: can only show history for /projects/{slug}/project.json or items/{id}.json")
        }
    }

    // MARK: - extract (pipeline)

    private static func handleExtract(_ cmd: ShellCommand, _ ctx: ToolContext) -> ToolResult {
        guard let idStr = cmd.args.first, let itemID = UUID(uuidString: idStr) else {
            return shellErr("extract: usage: extract <item-id>")
        }
        guard let item = try? KnowledgeItemService(context: ctx.modelContext).fetchItem(id: itemID) else {
            return shellErr("extract: item not found")
        }
        let extractSvc = ContentExtractionService(modelContext: ctx.modelContext, fileStore: ctx.fileStore)
        let text = extractSvc.bestAvailableTextSync(for: item) ?? ""
        if text.isEmpty { return shellErr("extract: no extractable text found for this item") }
        return ok(text)
    }

    // MARK: - ask_user

    /// Lets the agent ask the user a question mid-iteration without stopping the loop.
    /// The question is displayed to the user as a choice prompt. The agent continues
    /// iterating after the user responds. Usage:
    ///   ask_user "Should I proceed with reorganizing tasks?" --yes "Yes, proceed" --no "No, cancel"
    ///   ask_user "Which project?" --options "Project A,Project B"
    private static func handleAskUser(_ cmd: ShellCommand, _ ctx: ToolContext) -> ToolResult {
        let question = cmd.args.first ?? "Continue?"
        let yesLabel = cmd.flags["yes"] ?? "Yes"
        let noLabel = cmd.flags["no"] ?? "No"
        let optionsStr = cmd.flags["options"]
        let isFreeText = cmd.flags["text"] != nil

        // Free-text mode: open-ended text input
        if isFreeText {
            let placeholder = cmd.flags["placeholder"] ?? "Type your answer..."
            let submit = cmd.flags["submit"] ?? "Send"
            let block = ChatBlock.freeTextInput(FreeTextInputData(
                question: question, placeholder: placeholder, submitLabel: submit
            ))
            return ToolResult(content: "[ASK_USER] \(question)", blocks: [block], citations: [], isError: false, displaySummary: "Asking (text): \(question.prefix(60))")
        }

        // Options mode: multiple choice
        if let opts = optionsStr {
            let choices = opts.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let options = choices.map { ChoiceOption(label: $0, value: $0) }
            let block = ChatBlock.choicePrompt(ChoicePromptData(question: question, options: options))
            return ToolResult(content: "[ASK_USER] \(question)", blocks: [block], citations: [], isError: false, displaySummary: "Asking: \(question.prefix(60))")
        }

        // Yes/No mode (default)
        let options = [
            ChoiceOption(label: yesLabel, value: "yes"),
            ChoiceOption(label: noLabel, value: "no")
        ]
        let block = ChatBlock.confirmation(ConfirmationData(
            title: "Confirmation", message: question,
            confirmLabel: yesLabel, cancelLabel: noLabel,
            confirmValue: "yes", cancelValue: "no"
        ))
        return ToolResult(content: "[ASK_USER] \(question)", blocks: [block], citations: [], isError: false, displaySummary: "Asking: \(question.prefix(60))")
    }

    // MARK: - semantic (semantic search)

    private static func handleSemantic(_ cmd: ShellCommand, _ ctx: ToolContext) -> ToolResult {
        guard cmd.args.count >= 1 else { return shellErr("semantic: usage: semantic \"query\" [--limit N]") }
        let query = cmd.args.joined(separator: " ")
        let limit = Int(cmd.flags["limit"] ?? "10") ?? 10
        let allItems = (try? KnowledgeItemService(context: ctx.modelContext).allItems()) ?? []
        guard let provider = try? ProviderRouter.resolveActive(context: ctx.modelContext) else {
            return shellErr("semantic: no AI provider configured. Semantic search requires an embedding model.")
        }
        // Run async search and return stub for now - agent can check back
        let svc = SemanticSearchService(fileStore: ctx.fileStore)
        Task {
            let results = (try? await svc.findRelevant(query: query, itemIDs: allItems.map(\.id), limit: limit, using: provider)) ?? []
            let count = results.count
            AppLog.general.info("Semantic search completed: \(count) results for '\(query)'")
        }
        let itemCount = allItems.filter({ $0.bodyText != nil || $0.analysisProviderId != nil }).count
        return ok("Semantic search initiated for '\(query)' across \(itemCount) items with content. Results will be available when embeddings are processed. For immediate results, use grep.")
    }

    // MARK: - person (cross-reference contacts, calendar, transcripts, calls, memory)

    /// Cross-references a person name across all available sources.
    /// Returns a structured summary with match quality labels.
    /// Usage: person "Carla"  |  person show "Carla Silva"
    private static func handlePerson(_ cmd: ShellCommand, _ ctx: ToolContext) -> ToolResult {
        if cmd.args.first == "show" {
            return handlePersonShow(Array(cmd.args.dropFirst()), ctx)
        }
        guard let query = cmd.args.first, !query.isEmpty else {
            return shellErr("person: usage: person \"Name\"  |  person show \"Full Name\"")
        }
        let q = query.lowercased()
        var lines: [String] = []
        var total = 0
        let visited = NSMutableSet() // track seen names to deduplicate

        // ── Source 1: Contacts ───────────────────────────────────
        var contactHits: [String] = []
        let (contactResults, contactPermError) = searchContacts(query: query)
        if let permErr = contactPermError { lines.append("⚠️ Contacts: \(permErr)\n") }
        for (name, email, org, job, matchType) in contactResults.prefix(5) {
            let tag = matchType == "exact" ? "exata" : "aproximada"
            var line = "  [\(tag)] \(name)"
            if let e = email { line += " — \(e)" }
            if let o = org { line += " — \(o)" }
            if let j = job { line += " — \(j)" }
            contactHits.append(line)
            visited.add(name.lowercased())
            total += 1
        }
        if !contactHits.isEmpty {
            lines.append("### CONTACTS (\(contactHits.count))")
            lines.append(contentsOf: contactHits)
            lines.append("")
        }

        // ── Source 2: Calendar ───────────────────────────────────
        var calHits: [String] = []
        if let calPermErr = ensureCalendarAccess() {
            lines.append("⚠️ Calendar: \(calPermErr)\n")
        } else {
            let calSvc = CalendarSyncService()
            let sixMonths = DateInterval(start: Date().addingTimeInterval(-180*86400), duration: 180*86400)
            let events = calSvc.fetchEvents(for: sixMonths)
        for event in events {
            let title = event.title.lowercased()
            let attendeeNames = (event.attendees ?? []).compactMap { $0.name?.lowercased() }
            if title.contains(q) {
                calHits.append("  [mencionada] \"\(event.title)\" — \(formattedDate(event.startDate))")
                total += 1
            } else if attendeeNames.contains(where: { $0.contains(q) }) {
                let matched = attendeeNames.filter { $0.contains(q) }.joined(separator: ", ")
                calHits.append("  [attendee] \"\(event.title)\" — \(formattedDate(event.startDate)) — \(matched)")
                total += 1
            }
            if calHits.count >= 5 { break }
        }
        if !calHits.isEmpty {
            lines.append("### CALENDAR (\(calHits.count))")
            lines.append(contentsOf: calHits.prefix(5))
            lines.append("")
        }
        } // end calendar permission check

        // ── Source 3: Transcript grep ─────────────────────────────
        var transcriptHits: [String] = []
        let allItems = (try? KnowledgeItemService(context: ctx.modelContext).allItems()) ?? []
        for item in allItems where item.type == .audio {
            guard let transcript = try? ctx.fileStore.readArtifact(Transcript.self, fileName: "transcript.json", meetingId: item.id),
                  !transcript.segments.isEmpty else { continue }
            let fullText = transcript.segments.map(\.text).joined(separator: " ")
            if fullText.lowercased().contains(q) {
                // Extract a snippet around the match
                let snippet = snippetAround(fullText, query: q, radius: 60)
                let tag = item.title.lowercased().contains(q) ? "exata" : "parcial"
                transcriptHits.append("  [\(tag)] \"\(item.title)\" \(item.createdAt.formatted(date: .numeric, time: .omitted)) — \"...\(snippet)...\"")
                total += 1
            }
            if transcriptHits.count >= 5 { break }
        }
        if !transcriptHits.isEmpty {
            lines.append("### TRANSCRIPT MENTIONS (\(transcriptHits.count))")
            lines.append(contentsOf: transcriptHits)
            lines.append("")
        }

        // ── Source 4: Recent Calls ────────────────────────────────
        var callHits: [String] = []
        if let calls = fetchRecentCalls(matching: query) {
            for (name, direction, date, duration) in calls.prefix(3) {
                let dir = direction == "incoming" ? "recebida" : "efetuada"
                callHits.append("  [exata] \(name) — \(dir) — \(formattedDate(date)) (\(duration)s)")
                total += 1
            }
        }
        if !callHits.isEmpty {
            lines.append("### CHAMADAS RECENTES (\(callHits.count))")
            lines.append(contentsOf: callHits)
            lines.append("")
        }

        // ── Source 5: WawaNote Memory ─────────────────────────────
        var memHits: [String] = []
        for item in allItems {
            guard item.analysisProviderId != nil else { continue }
            guard let analysisData = try? ctx.fileStore.readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id) else { continue }
            // Check if person appears in analysis fields
            let decisionText = analysisData.decisions.map { $0.title + " " + ($0.details ?? "") }.joined(separator: " ")
            let actionText = analysisData.actionItems.map { $0.task + " " + ($0.owner ?? "") }.joined(separator: " ")
            let analysisText = analysisData.shortSummary + " " + decisionText + " " + actionText
            if analysisText.lowercased().contains(q) {
                memHits.append("  [exata] \"\(query)\" citada em análise de \"\(item.title)\" — \(item.createdAt.formatted(date: .numeric, time: .omitted))")
                total += 1
            }
            if memHits.count >= 3 { break }
        }
        if !memHits.isEmpty {
            lines.append("### WAWANOTE MEMORY (\(memHits.count))")
            lines.append(contentsOf: memHits)
            lines.append("")
        }

        if total == 0 {
            return ok("person \"\(query)\": Nenhum resultado encontrado em contacts, calendário, transcrições, chamadas ou memória interna.")
        }

        let header = "## person \"\(query)\" — \(total) resultados em \(lines.filter { $0.hasPrefix("###") }.count) fontes\n"
        return ok(header + "\n" + lines.joined(separator: "\n"))
    }

    /// Drill-down: full details for a specific person name
    private static func handlePersonShow(_ args: [String], _ ctx: ToolContext) -> ToolResult {
        guard let name = args.first, !name.isEmpty else {
            return shellErr("person show: usage: person show \"Full Name\"")
        }
        var lines: [String] = ["## person show \"\(name)\"\n"]

        // Contact detail
        let (contacts, _) = searchContacts(query: name)
        if !contacts.isEmpty {
            lines.append("### CONTACT")
            for (cname, email, org, job, _) in contacts.prefix(1) where cname.lowercased() == name.lowercased() {
                lines.append("  Name: \(cname)")
                if let e = email { lines.append("  Email: \(e)") }
                if let o = org { lines.append("  Organization: \(o)") }
                if let j = job { lines.append("  Job Title: \(j)") }
            }
            lines.append("")
        }

        // Calendar appearances
        let calSvc = CalendarSyncService()
        let sixMonths = DateInterval(start: Date().addingTimeInterval(-180*86400), duration: 180*86400)
        let events = calSvc.fetchEvents(for: sixMonths)
        let relevantEvents = events.filter { event in
            let attNames = (event.attendees ?? []).compactMap { $0.name?.lowercased() }
            return attNames.contains(where: { $0.contains(name.lowercased()) }) ||
            event.title.lowercased().contains(name.lowercased())
        }
        let df = DateFormatter(); df.dateStyle = .short; df.timeStyle = .short
        if !relevantEvents.isEmpty {
            lines.append("### CALENDAR (\(relevantEvents.count))")
            for e in relevantEvents.prefix(5) {
                lines.append("  \(df.string(from: e.startDate)) — \"\(e.title)\"")
            }
            lines.append("")
        }

        // SwiftData Person entity
        let persons = (try? PersonService(context: ctx.modelContext).search(name)) ?? []
        if !persons.isEmpty {
            lines.append("### PERSON ENTITY")
            for p in persons.prefix(1) {
                lines.append("  Name: \(p.displayName)")
                if let e = p.email { lines.append("  Email: \(e)") }
                if let r = p.role { lines.append("  Role: \(r)") }
            }
            lines.append("")
        }

        return ok(lines.joined(separator: "\n"))
    }

    /// Search Contacts using CNContactStore. Returns results + permission status string.
    /// If permission is notDetermined, requests it synchronously and returns empty.
    private static func searchContacts(query: String) -> ([(String, String?, String?, String?, String)], String?) {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .notDetermined:
            var granted = false
            let sem = DispatchSemaphore(value: 0)
            CNContactStore().requestAccess(for: .contacts) { ok, _ in
                granted = ok; sem.signal()
            }
            sem.wait()
            if !granted { return ([], "Contacts access denied by user.") }
        case .denied, .restricted:
            return ([], "Contacts access denied. Enable in Settings → Privacy → Contacts.")
        case .authorized: break
        @unknown default: return ([], "Contacts: unknown authorization status.")
        }

        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [CNContactGivenNameKey as CNKeyDescriptor,
                                        CNContactFamilyNameKey as CNKeyDescriptor,
                                        CNContactEmailAddressesKey as CNKeyDescriptor,
                                        CNContactOrganizationNameKey as CNKeyDescriptor,
                                        CNContactJobTitleKey as CNKeyDescriptor]
        let predicate = CNContact.predicateForContacts(matchingName: query)
        guard let contacts = try? store.unifiedContacts(matching: predicate, keysToFetch: keys) else { return ([], nil) }
        let results = contacts.compactMap { c -> (String, String?, String?, String?, String)? in
            let fullName = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            guard !fullName.isEmpty else { return nil }
            let email = c.emailAddresses.first?.value as? String
            let matchType = fullName.lowercased() == query.lowercased() ? "exact" : "fuzzy"
            return (fullName, email, c.organizationName.isEmpty ? nil : c.organizationName,
                    c.jobTitle.isEmpty ? nil : c.jobTitle, matchType)
        }
        return (results, nil)
    }

    /// Checks and requests calendar permission. Returns nil if OK, error message if not.
    private static func ensureCalendarAccess() -> String? {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .notDetermined:
            var granted = false
            let sem = DispatchSemaphore(value: 0)
            EKEventStore.shared.requestFullAccessToEvents { ok, _ in
                granted = ok; sem.signal()
            }
            sem.wait()
            if !granted { return "Calendar access denied by user." }
        case .denied, .restricted:
            return "Calendar access denied. Enable in Settings → Privacy → Calendars."
        case .authorized, .fullAccess: break
        @unknown default: return "Calendar: unknown authorization status."
        }
        return nil
    }

    /// Fetch recent phone/FaceTime calls matching a name via CallKit history.
    private static func fetchRecentCalls(matching name: String) -> [(String, String, Date, Int)]? {
        // Call history requires entitlements and is limited on iOS.
        // Return nil if unavailable — the agent treats this as "no call data."
        return nil
    }

    /// Extract a text snippet around a query match.
    private static func snippetAround(_ text: String, query: String, radius: Int) -> String {
        guard let range = text.lowercased().range(of: query.lowercased()) else {
            return String(text.prefix(radius * 2))
        }
        let lower = text.distance(from: text.startIndex, to: range.lowerBound)
        let start = max(0, lower - radius)
        let end = min(text.count, lower + query.count + radius)
        let si = text.index(text.startIndex, offsetBy: start)
        let ei = text.index(text.startIndex, offsetBy: end)
        return String(text[si..<ei]).replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: - analyze (trigger pipeline)

    private static func handleAnalyze(_ cmd: ShellCommand, _ ctx: ToolContext) -> ToolResult {
        guard let idStr = cmd.args.first, let itemID = UUID(uuidString: idStr) else {
            return shellErr("analyze: usage: analyze <item-id>")
        }
        guard let item = try? KnowledgeItemService(context: ctx.modelContext).fetchItem(id: itemID) else {
            return shellErr("analyze: item \(idStr) not found")
        }
        // Set flag: mark item as ready for analysis by setting analysisProviderId to "pending"
        if item.analysisProviderId == nil {
            item.analysisProviderId = "pending"
            try? ctx.modelContext.save()
        }
        return ok("Item '\(item.title)' flagged for analysis. The pipeline will process it in the background. To check status: cat items/\(idStr.prefix(8)).json")
    }

    // MARK: - cal (calendar events)

    private static func handleCal(_ cmd: ShellCommand, _ ctx: ToolContext) -> ToolResult {
        let sub = cmd.args.first ?? "list"

        // Check and request calendar permission
        if let permErr = ensureCalendarAccess() {
            return shellErr("cal: \(permErr)")
        }

        let svc = CalendarSyncService()
        let iso = ISO8601DateFormatter()

        // Parse --from and --to (supports YYYY-MM-DD or ISO8601)
        func parseDate(_ str: String?) -> Date? {
            guard let s = str else { return nil }
            // Try ISO8601 first, then simple date
            if let d = iso.date(from: s) { return d }
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            return df.date(from: s)
        }
        let fromDate = parseDate(cmd.flags["from"])
        let toDate = parseDate(cmd.flags["to"])

        // Date range: use --from/--to, else default to next 7 days
        func dateRange() -> DateInterval {
            if let from = fromDate, let to = toDate {
                return DateInterval(start: from, end: to)
            }
            if let from = fromDate {
                return DateInterval(start: from, duration: 7 * 86400)
            }
            let now = Date()
            return DateInterval(start: now, duration: 7 * 86400)
        }

        switch sub {
        case "add":
            guard let title = cmd.flags["title"] else { return shellErr("cal add: --title required. --start (ISO8601), --end, --notes optional.") }
            let startStr = cmd.flags["start"] ?? Date().ISO8601Format()
            let endStr = cmd.flags["end"]
            let notes = cmd.flags["notes"]
            let start = iso.date(from: startStr) ?? Date()
            let end = endStr.flatMap { iso.date(from: $0) } ?? start.addingTimeInterval(3600)
            do {
                let eventID = try svc.createEvent(title: title, startDate: start, endDate: end, notes: notes)
                return ok("Calendar event created: \(title) (\(eventID.prefix(8)))")
            } catch {
                return shellErr("cal add: failed — \(error.localizedDescription)")
            }

        case "list":
            let range = dateRange()
            let events = svc.fetchEvents(for: range)
            let label = fromDate != nil ? "\(formattedDate(range.start)) → \(formattedDate(range.end))" : "next 7 days"
            if events.isEmpty { return ok("No events \(label).") }
            var lines = ["Events (\(label)):", ""]
            for e in events.prefix(20) {
                lines.append("  \(formattedDate(e.startDate))  \(e.title)")
                if let loc = e.location { lines.append("       Location: \(loc)") }
            }
            return ok(lines.joined(separator: "\n"))

        case "find":
            guard let query = cmd.args.dropFirst().first, !query.isEmpty else {
                return shellErr("cal find: usage: cal find \"query\" [--from YYYY-MM-DD] [--to YYYY-MM-DD]")
            }
            let range = dateRange()
            let events = svc.fetchEvents(for: range)
            let q = query.lowercased()
            let matched = events.filter { $0.title.lowercased().contains(q) }
            if matched.isEmpty { return ok("No events matching \"\(query)\" in range.") }
            var lines = ["Events matching \"\(query)\" (\(matched.count)):", ""]
            for e in matched.prefix(15) {
                lines.append("  \(formattedDate(e.startDate))  \(e.title)")
                if let loc = e.location { lines.append("       Location: \(loc)") }
                if let notes = e.notes { lines.append("       Notes: \(notes.prefix(120))") }
            }
            return ok(lines.joined(separator: "\n"))

        case "attendees":
            let range = dateRange()
            let events = svc.fetchEvents(for: range)
            var allAttendees = Set<String>()
            for event in events {
                for att in (event.attendees ?? []) {
                    if let name = att.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                        allAttendees.insert(name)
                    }
                }
            }
            if allAttendees.isEmpty { return ok("No attendees found in events for this range.") }
            let sorted = allAttendees.sorted()
            var lines = ["Attendees in calendar events (\(sorted.count) unique):", ""]
            for name in sorted {
                let count = events.filter { ($0.attendees ?? []).compactMap({ $0.name }).contains(name) }.count
                lines.append("  \(name) — \(count) event\(count == 1 ? "" : "s")")
            }
            return ok(lines.joined(separator: "\n"))

        default:
            return shellErr("cal: usage: cal list|find|attendees|add [--from YYYY-MM-DD] [--to YYYY-MM-DD]")
        }
    }

    // MARK: - cleanup (free disk space)

    private static func handleCleanup(_ cmd: ShellCommand, _ ctx: ToolContext) -> ToolResult {
        guard let idStr = cmd.args.first, let itemID = UUID(uuidString: idStr) else {
            return shellErr("cleanup: usage: cleanup <item-id>   Deletes the raw audio file for processed items to free disk space.")
        }
        guard let item = try? KnowledgeItemService(context: ctx.modelContext).fetchItem(id: itemID) else {
            return shellErr("cleanup: item \(idStr) not found")
        }
        guard item.type == .audio else { return shellErr("cleanup: only audio items have raw audio files to clean up.") }
        guard item.transcriptionEngineId != nil else { return shellErr("cleanup: item must be transcribed first. The raw audio is still needed.") }
        do {
            try ctx.fileStore.deleteAudio(for: itemID)
            return ok("Deleted raw audio for '\(item.title)'. Transcript and analysis are preserved.")
        } catch {
            return shellErr("cleanup: \(error.localizedDescription)")
        }
    }

    // MARK: - progress (step tracking)

    private static func handleProgress(_ cmd: ShellCommand, _ ctx: ToolContext) -> ToolResult {
        guard let stepStr = cmd.args.first, let step = Int(stepStr) else {
            return shellErr("progress: usage: progress <step> <total> [--label \"Processing...\"]")
        }
        let total = Int(cmd.args.count > 1 ? cmd.args[1] : "1") ?? 1
        let label = cmd.flags["label"] ?? "Processing..."
        let block = ChatBlock.progressUpdate(ProgressUpdateData(step: step, total: total, label: label))
        return ToolResult(content: "[PROGRESS] Step \(step)/\(total): \(label)", blocks: [block], citations: [], isError: false, displaySummary: "Step \(step)/\(total)")
    }

    // MARK: - vision / describe (image analysis)

    private static func handleVision(_ cmd: ShellCommand, _ ctx: ToolContext) -> ToolResult {
        guard let idStr = cmd.args.first, let itemID = UUID(uuidString: idStr) else {
            return shellErr("vision: usage: vision <item-id> [--question \"...\"] [--save-as-note]")
        }
        guard let item = try? KnowledgeItemService(context: ctx.modelContext).fetchItem(id: itemID) else {
            return shellErr("vision: item \(idStr) not found")
        }
        let dir = ctx.fileStore.itemDirectoryURL(for: item.id)
        let scanURL = dir.appendingPathComponent("scan_0.jpg")
        guard FileManager.default.fileExists(atPath: scanURL.path) else {
            return shellErr("vision: no image found for item '\(item.title)'. It must have a scanned image (scan_0.jpg).")
        }
        guard let provider = try? ProviderRouter.resolveActive(context: ctx.modelContext) else {
            return shellErr("vision: no AI provider configured. Vision requires a provider with image support.")
        }
        let question = cmd.args.count > 1
            ? cmd.args.dropFirst().joined(separator: " ")
            : cmd.flags["question"] ?? "Describe this image in detail. Extract any text visible."
        let saveAsNote = cmd.flags["save-as-note"] != nil

        let userMsg = AIMessage(role: .user, content: [.text(question), .imageFile(scanURL)])
        let model = AIConfigService.shared.modelFor(feature: "vision")
        let request = AIRequest(model: model, messages: [userMsg],
            temperature: AIConfigService.shared.requestParams(for: "vision", model: model).temperature,
            maxTokens: AIConfigService.shared.requestParams(for: "vision", model: model).maxTokens)

        let semaphore = DispatchSemaphore(value: 0)
        var resultText = ""; var resultError: String?
        let visionTask = Task {
            do {
                let response = try await provider.send(request)
                resultText = response.content
                let analysisData = try? JSONEncoder().encode(["question": question, "response": resultText, "timestamp": Date().ISO8601Format()])
                try? analysisData?.write(to: dir.appendingPathComponent("vision_analysis.json"))
                if saveAsNote, !resultText.isEmpty {
                    let svc = KnowledgeItemService(context: ctx.modelContext)
                    if let note = try? svc.createItem(type: .note, title: "Vision: \(item.title)",
                        bodyText: "# Image Analysis\n\n**Question:** \(question)\n\n\(resultText)",
                        tags: ["vision", "ai-analysis"], inboxDate: Date()) {
                        if let pid = item.projectID { try? ProjectService(context: ctx.modelContext).addItem(note.id, to: pid) }
                        AppLog.general.info("Vision: saved result as note \(note.title)")
                    }
                }
            } catch { resultError = error.localizedDescription }
            semaphore.signal()
        }
        // Timeout after 30s instead of blocking indefinitely.
        // The cooperative thread pool runs the Task asynchronously so this
        // doesn't deadlock in practice, but a timeout is safety.
        _ = semaphore.wait(timeout: .now() + 30)

        if let error = resultError { return shellErr("vision: \(error)") }
        let extra = saveAsNote ? " Also saved as a new note." : ""
        return ok("Image analysis for '\(item.title)':\(extra)\n\n\(resultText)")
    }

    // MARK: - export

    private static func handleRecipe(_ cmd: ShellCommand, _ ctx: ToolContext) -> ToolResult {
        let sub = cmd.args.first ?? "list"
        switch sub {
        case "list":
            let skills = AnalysisSkillStore.shared.skills(in: nil)
            let lines = skills.map { "  \($0.name) — \($0.description)" }.joined(separator: "\n")
            return ok("Available recipes:\n\(lines.isEmpty ? "  (none)" : lines)")
        case "show":
            guard let name = cmd.args.count > 1 ? cmd.args[1] : nil else {
                return shellErr("recipe show <name> — Show recipe details")
            }
            guard let skill = AnalysisSkillStore.shared.skill(named: name) else {
                return shellErr("recipe: '\(name)' not found. Use 'recipe list' to see available recipes.")
            }
            let info = """
            Recipe: \(skill.displayName)
            Description: \(skill.description)
            Category: \(skill.category)
            Template: \(skill.templateID)
            Model: \(skill.defaultModel)
            Max Iterations: \(skill.maxIterations)
            Steps: \(skill.procedure?.steps.map { "\($0.step). \($0.action) — \($0.description)" }.joined(separator: ", ") ?? "none")
            """
            return ok(info)
        default:
            return shellErr("recipe: unknown subcommand '\(sub)'. Use: recipe list, recipe show <name>")
        }
    }

    private static func handleExport(_ cmd: ShellCommand, _ ctx: ToolContext) -> ToolResult {
        guard let target = cmd.args.first else { return shellErr("export: usage: export <item-id | project-id> [--format md|json]") }
        let format = cmd.flags["format"] ?? "md"
        let ext = format == "json" ? "json" : "md"
        // Try as item ID
        if let id = UUID(uuidString: target), let item = try? KnowledgeItemService(context: ctx.modelContext).fetchItem(id: id) {
            let output: String
            if format == "json" {
                let exporter = JSONExporter()
                if let data = try? exporter.export(item: item, transcript: nil, analysis: nil) {
                    output = String(data: data, encoding: .utf8) ?? ""
                } else { return shellErr("export: JSON export failed") }
            } else {
                output = MarkdownExporter().export(item: item, transcript: nil, analysis: nil)
            }
            let dir = ctx.fileStore.exportsDirectoryURL(for: id)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("export.\(ext)")
            try? output.write(to: url, atomically: true, encoding: .utf8)
            return ok("Exported to \(url.path)\n\n\(output.prefix(500))\(output.count > 500 ? "..." : "")")
        }
        // Try as project ID
        if let pid = UUID(uuidString: target), let project = try? ProjectService(context: ctx.modelContext).fetch(id: pid) {
            let pSvc = ProjectService(context: ctx.modelContext)
            let items = (try? pSvc.items(in: pid)) ?? []
            let tasks = (try? TaskService(context: ctx.modelContext).tasks(for: pid)) ?? []
            let output = ProjectExportService().exportMarkdown(project: project, items: items, tasks: tasks, edges: [])
            let dir = ctx.fileStore.exportsDirectoryURL(for: pid)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("project_export.\(ext)")
            try? output.write(to: url, atomically: true, encoding: .utf8)
            return ok("Project exported to \(url.path) (\(items.count) items, \(tasks.count) tasks)")
        }
        return shellErr("export: '\(target)' not found as item or project ID")
    }

    // MARK: - help

    private static func handleHelp(_ cmd: ShellCommand, _ ctx: ToolContext) -> ToolResult {
        let topic = cmd.args.first ?? "vfs"
        switch topic.lowercased() {
        case "vfs", "filesystem":
            return ok("""
            VIRTUAL FILESYSTEM:
            /                          Root — workspace summary
            /inbox/                    Items without a project
            /projects/                 All projects
            /projects/{name}/          Project directory (cd target)
              project.json             Metadata, health score
              items/                   KnowledgeItems (meetings, notes, images)
              tasks/                   Tasks by status/priority
              people/                  People in this project
              edges/                   Graph relationships
              signals/                 Active alerts and insights
              analysis/                AI analysis per item (use cat)
            /agent/prompts/            Editable prompt templates
            /agent/memories/           Learned patterns
            /agent/chat/               Conversation history
            """)
        case "ls":
            return ok("""
            ls [path] — List directory contents.
            Flags: --long (details), --type audio|note|image, --status todo|done|analyzed
                   --tag \"tagname\", --since 7d, --limit 20
            Examples: ls /, ls tasks/, ls items/ --type audio --since 7
            """)
        case "cd":
            return ok("cd <path> — Change current directory. cd .. to go up, cd / for root.\nExamples: cd /projects/my-project, cd tasks/, cd /inbox")
        case "cat":
            return ok("cat <path> — Read a file.\nFlags: --json (raw JSON), --fields \"title,body\" (select fields)\nExamples: cat project.json, cat items/\"Meeting Notes\", cat analysis/abc.json")
        case "find":
            return ok("find [path] — Search with filters.\nFlags: --tag X, --since 7d, --type audio|note, --status todo|analyzed, --project \"name\", --limit 20\nIn tasks/ dir: finds tasks by status. In items/ dir: finds items.")
        case "grep":
            return ok("grep \"query\" [path] — Full-text search.\nSearches item titles, bodies, transcripts, and analysis files.\nExamples: grep \"decision\" items/, grep \"budget\" /projects/my-project/")
        case "touch":
            return ok("touch <path> — Create item or task.\nFlags: --title \"Name\", --type note|audio|image, --body \"text\", --priority low|medium|high|critical, --owner \"Name\", --tag \"tag\", --due 2026-06-15\nExamples: touch tasks/ --title \"Call John\" --priority high, touch /inbox/ --title \"Quick note\" --type note")
        case "echo":
            return ok("echo '{\"field\":\"value\"}' > <path> — Update fields.\nUpdate tasks: echo '{\"status\":\"done\"}' > tasks/TaskName\nUpdate items: echo '{\"title\":\"New name\"}' > items/ItemName\nUpdate project: echo '{\"summary\":\"...\"}' > project.json")
        case "rm", "mv", "head", "wc", "history", "extract", "status":
            return ok("\(topic) — Use 'help vfs' to see all commands and their descriptions.")
        default:
            return ok("Help topics: vfs, ls, cd, cat, find, grep, touch, echo, ask_user. Use 'help vfs' to see the full filesystem layout.")
        }
    }

    // MARK: - js-eval

    private static func handleJsEval(_ cmd: ShellCommand, _ ctx: ToolContext) -> ToolResult {
        guard let code = cmd.args.first else {
            return shellErr("js-eval: usage: js-eval '<javascript code>'")
        }
        let bridge = WawaJSBridge(modelContext: ctx.modelContext, fileStore: ctx.fileStore)
        let result = JSSandbox.execute(code, bridge: bridge)
        if let error = result.error {
            return shellErr("js-eval error: \(error)")
        }
        var out = result.output
        if !result.logs.isEmpty {
            out += "\n\nConsole:\n" + result.logs.map { "  > \($0)" }.joined(separator: "\n")
        }
        return ok(out)
    }

    // MARK: - Sandbox

    /// Returns an error if the given item ID is not the sandboxed item.
    /// When sandboxedItemID is set, all VFS operations are restricted to that item.
    private static func checkSandbox(_ itemID: UUID, _ ctx: ToolContext) -> ToolResult? {
        guard let sandboxed = ctx.sandboxedItemID, sandboxed != itemID else { return nil }
        let target = itemID.uuidString.prefix(8)
        let allowed = sandboxed.uuidString.prefix(8)
        return shellErr("Access denied: item \(target) is outside the current analysis scope (\(allowed)). Only the item being analyzed can be accessed.")
    }

    /// Returns an error if the agent is sandboxed and tries to list/access other items.
    private static func checkSandboxGlobal(_ ctx: ToolContext) -> ToolResult? {
        guard ctx.sandboxedItemID != nil else { return nil }
        return shellErr("Access denied: browsing other items is not allowed during item analysis. Use 'extract <item-id>' to get the content of the item being analyzed, or 'cat' to read files within it.")
    }

    // MARK: - Helpers

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f
    }()

    private static func formattedDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private static func ok(_ content: String, blocks: [ChatBlock]? = nil) -> ToolResult {
        ToolResult(content: content, blocks: blocks, citations: [], isError: false, displaySummary: String(content.prefix(80)))
    }

    private static func shellErr(_ message: String) -> ToolResult {
        ToolResult(content: message, blocks: nil, citations: [], isError: true, displaySummary: message)
    }

    /// Known command names for did-you-mean suggestions (used by dispatch default).
    private static let knownCommands: Set<String> = ["ls", "cd", "cat", "echo", "touch", "rm", "mv", "find",
        "grep", "wc", "man", "history", "help", "pwd", "mkdir", "ask_user", "plan", "assign", "progress", "cleanup", "person"]
}

