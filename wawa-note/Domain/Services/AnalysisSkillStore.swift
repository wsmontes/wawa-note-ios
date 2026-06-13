import Foundation
import OSLog

// MARK: - Extended Skill Template

/// A reusable analysis skill that defines procedure + output template.
///
/// Skills are the bridge between Meetily templates (WHAT to produce)
/// and the AgentLoop (HOW to produce it). Each skill defines:
/// - A procedure (ordered steps)
/// - A linked Meetily template (output format)
/// - Validation rules
/// - Model preference and iteration budget
///
/// Pattern: same as PromptStore — built-in from bundle, user overrides from disk.
struct AnalysisSkill: Codable, Identifiable, Sendable {
    var id: UUID
    let name: String
    var displayName: String
    var description: String
    var category: String
    var templateID: String
    var systemPrompt: String
    var procedure: Procedure?
    var validation: ValidationRules?
    var defaultModel: String
    var maxIterations: Int
    var allowedTools: [String]
    var isUserEdited: Bool
    var updatedAt: Date

    struct Procedure: Codable, Sendable {
        var steps: [Step]

        struct Step: Codable, Sendable {
            let step: Int
            let action: String
            let description: String
        }
    }

    struct ValidationRules: Codable, Sendable {
        var requiredFields: [String]?
        var minArrayItems: [String: Int]?
        var maxArrayItems: [String: Int]?
    }
}

// MARK: - Analysis Skill Store

/// Manages analysis skills as configurable resources.
///
/// Follows the same pattern as PromptStore:
/// 1. Load built-in skills from bundle (Resources/Skills/*.json)
/// 2. Apply user overrides from configs/skills.json
/// 3. Persist edits back to disk
///
/// Skills are resolved per item based on type and content characteristics.
@MainActor
final class AnalysisSkillStore: ObservableObject {
    static let shared = AnalysisSkillStore()

    @Published private(set) var skills: [String: AnalysisSkill] = [:]

    private let fileStore = FileArtifactStore()
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "com.wawa.note", category: "SkillStore")

    private var overridesURL: URL {
        fileStore.configsDirectoryURL().appendingPathComponent("skills.json")
    }

    private init() {
        loadBuiltInSkills()
        applyUserOverrides()
        logger.info("SkillStore: \(self.skills.count) skills loaded")
    }

    // MARK: - Load built-in skills

    private func loadBuiltInSkills() {
        guard let skillsURL = Bundle.main.url(forResource: "Skills", withExtension: nil) else {
            logger.warning("Skills directory not found in bundle")
            return
        }

        do {
            let files = try fileManager.contentsOfDirectory(at: skillsURL, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }

            for fileURL in files {
                guard let data = try? Data(contentsOf: fileURL),
                      var skill = try? JSONDecoder().decode(AnalysisSkill.self, from: data) else {
                    logger.warning("Failed to parse skill: \(fileURL.lastPathComponent)")
                    continue
                }
                skill.isUserEdited = false
                skill.updatedAt = Date()
                self.skills[skill.name] = skill
                logger.debug("Loaded skill: \(skill.displayName)")
            }
        } catch {
            logger.error("Failed to load skills: \(error)")
        }
    }

    private func applyUserOverrides() {
        guard fileManager.fileExists(atPath: overridesURL.path),
              let data = try? Data(contentsOf: overridesURL),
              let overrides = try? JSONDecoder().decode([String: AnalysisSkill].self, from: data) else {
            return
        }
        for (key, skill) in overrides where skill.isUserEdited {
            self.skills[key] = skill
        }
    }

    private func saveOverrides() {
        let overrides = skills.filter { $0.value.isUserEdited }
        guard !overrides.isEmpty else {
            try? fileManager.removeItem(at: overridesURL)
            return
        }
        do {
            try fileManager.createDirectory(at: overridesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(overrides)
            try data.write(to: overridesURL, options: .atomic)
        } catch {
            logger.error("SkillStore: failed to save overrides: \(error)")
        }
    }

    // MARK: - Query

    func skill(named name: String) -> AnalysisSkill? {
        skills[name]
    }

    func skills(in category: String? = nil) -> [AnalysisSkill] {
        let all = Array(skills.values)
        guard let cat = category else { return all.sorted { $0.displayName < $1.displayName } }
        return all.filter { $0.category == cat }.sorted { $0.displayName < $1.displayName }
    }

    var allCategories: [String] {
        Array(Set(skills.values.map(\.category))).sorted()
    }

    // MARK: - Resolution

    /// Resolve the best skill for a given item.
    /// Default: meeting_analysis for audio, quick_extract for others.
    func resolve(for item: KnowledgeItem) -> AnalysisSkill {
        switch item.type {
        case .audio:
            // Check if calendar event title suggests a standup
            if let title = item.contextCalendarEventTitle?.lowercased(),
               title.contains("standup") || title.contains("daily") {
                return skill(named: "daily_standup") ?? defaultSkill
            }
            return skill(named: "meeting_analysis") ?? defaultSkill
        case .note:
            return skill(named: "quick_extract") ?? defaultSkill
        case .journalEntry:
            return skill(named: "journal_entry") ?? defaultSkill
        case .webBookmark, .image:
            return skill(named: "quick_extract") ?? defaultSkill
        }
    }

    private var defaultSkill: AnalysisSkill {
        if let meeting = skills["meeting_analysis"] { return meeting }
        if let first = skills.first?.value { return first }
        // Safety fallback: create a minimal built-in skill if bundle is corrupted
        logger.warning("No skills loaded — using emergency fallback")
        return AnalysisSkill(
            id: UUID(), name: "basic_extract", displayName: "Basic Extract",
            description: "Emergency fallback skill", category: "extraction",
            templateID: "", systemPrompt: "Extract key information from the content.",
            procedure: nil, validation: nil,
            defaultModel: "gpt-5-nano", maxIterations: 3,
            allowedTools: [], isUserEdited: false, updatedAt: Date()
        )
    }

    // MARK: - CRUD

    func updateSkill(named name: String, systemPrompt: String? = nil, templateID: String? = nil) {
        guard var skill = skills[name] else { return }
        if let prompt = systemPrompt { skill.systemPrompt = prompt }
        if let tid = templateID { skill.templateID = tid }
        skill.updatedAt = Date()
        skill.isUserEdited = true
        skills[name] = skill
        saveOverrides()
        logger.info("Updated skill: \(skill.displayName)")
    }

    func createSkill(_ skill: AnalysisSkill) {
        var newSkill = skill
        newSkill.isUserEdited = true
        newSkill.updatedAt = Date()
        skills[newSkill.name] = newSkill
        saveOverrides()
        logger.info("Created skill: \(newSkill.displayName)")
    }

    func resetSkill(named name: String) {
        guard let skill = skills[name] else {
            logger.warning("resetSkill: '\(name)' not found")
            return
        }
        // Check if this skill exists in built-ins — if not, it's user-created and should be removed
        let builtInNames = builtInSkillNames
        if !builtInNames.contains(name) && skill.isUserEdited {
            skills.removeValue(forKey: name)
            saveOverrides()
            logger.info("Removed user-created skill: \(skill.displayName)")
            return
        }
        // Reset built-in skill to its original state
        skills[name]?.isUserEdited = false
        saveOverrides()
        loadBuiltInSkills()
        applyUserOverrides()
        logger.info("Reset skill to built-in: \(skill.displayName)")
    }

    /// List all built-in skill names (not user-created).
    var builtInSkillNames: Set<String> {
        Set(skills.filter { !$0.value.isUserEdited }.keys)
    }
}
