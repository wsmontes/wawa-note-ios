import SwiftUI
// Related JIRA: KAN-10, KAN-112


// MARK: - Color from Hex

extension Color {
    /// Creates a color from a hex string (e.g. "#2563EB").
    /// Adapts to light/dark mode: slightly lightened in dark mode for visibility.
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = CGFloat((int >> 16) & 0xFF) / 255
        let g = CGFloat((int >> 8) & 0xFF) / 255
        let b = CGFloat(int & 0xFF) / 255
        let uiColor = UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor(red: min(1, r + 0.12), green: min(1, g + 0.12), blue: min(1, b + 0.12), alpha: 1)
            }
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        }
        self.init(uiColor: uiColor)
    }

    static let defaultProjectColor = Color(hex: ProjectPalette.allHexes.first ?? "#3B82F6") // fallback blue
}

// MARK: - Project Color Palette

enum ProjectPalette {
    static let allHexes = [
        "#64748B",  // slateGray  — neutral, professional
        "#0D9488",  // teal       — calm, structured
        "#B45379",  // rose       — warm, creative
        "#B45309",  // amber      — vibrant, earthy
        "#7C3AED",  // lavender   — elegant
        "#4D7C0F",  // sage       — natural, grounded
        "#C2410C",  // terracotta — warm, active
        "#2563EB",  // steelBlue  — trustworthy (default)
        "#6B21A8",  // plum       — sophisticated, deep
        "#5B8C2A",  // moss       — organic
        "#DB2777",  // coral      — energetic, personal
        "#9A3412",  // copper     — rich, archival
    ]
}

enum AppColor {
    // Semantic
    static let recording = Color.red
    static let error = Color.red
    static let success = Color.green
    static let warning = Color.orange
    static let neutral = Color.secondary
    static let privacy = Color.blue
    static let accent = Color.accentColor

    // Brand — wawa-note gradient
    static let brandCyan = Color(red: 0x0C / 255, green: 0xB5 / 255, blue: 0xFF / 255)
    static let brandBlue = Color(red: 0x19 / 255, green: 0x6E / 255, blue: 0xF0 / 255)
    static let brandPurple = Color(red: 0x73 / 255, green: 0x52 / 255, blue: 0xFF / 255)
    static let brandInk = Color(red: 0x14 / 255, green: 0x1C / 255, blue: 0x2A / 255)
    static let brandDeepNavy = Color(red: 0x05 / 255, green: 0x0A / 255, blue: 0x18 / 255)
}

enum AppSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum AppRadius {
    static let sm: CGFloat = 6
    static let md: CGFloat = 10
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16
}

enum AppCopy {
    // MARK: - Home Screen
    static let homeValueProp = "Record audio. Get instant transcripts."

    // MARK: - Empty States
    static let noMeetings = "No recordings yet.\nTap the button below to record your first one."
    static let noProvider = "Connect an AI service to generate summaries and action items."
    static let noTranscript = "Your transcript will appear here.\nTap Transcribe Meeting to get started."
    static let noActionItems = "Action items from your recording will appear here once you generate a summary."
    static let noSummary = "Transcribe this meeting first, then tap Generate Summary."

    // MARK: - Permissions
    static let micPermission = "Wawa Note uses your microphone to record meetings you choose to capture. Audio stays on this iPhone."
    static let speechPermission = "Your recordings are turned into searchable text right on this iPhone. Nothing is sent anywhere."

    // MARK: - Privacy
    static let privacyLocalFirst = "Your audio stays on this iPhone. Nothing leaves your device unless you connect an AI service for summaries."

    // MARK: - AI Service Setup
    static let serviceURLPlaceholder = "Server address (e.g., https://api.openai.com)"
    static let serviceAPIKeyPlaceholder = "Paste your API key here"
    static let serviceModelPlaceholder = "Model name (e.g., gpt-4o)"
    static let serviceConnectionSuccess = "Connected"

    // MARK: - Post-Recording
    static let recordingSaved = "Saved. Your recording is ready."
    static let wantAISummaries = "Want AI-powered summaries?"
    static let connectAIDescription = "Connect an AI service to automatically find action items, decisions, and key points in your meetings."
    static let connectAIButton = "Connect an AI Service"
    static let notNow = "Not Now"
    static let privacyReassurance = "Your recordings and transcripts stay on your iPhone."

    // MARK: - In-Progress
    static let transcribing = "Transcribing your meeting..."
    static let analyzing = "Creating your summary..."

    // MARK: - Button Labels
    static let transcribeButton = "Transcribe Meeting"
    static let generateSummaryButton = "Generate Summary"
    static let retryButton = "Try Again"
    static let startRecordingButton = "Start Recording"

    // MARK: - Error Messages
    static let errorAudioNotFound = "The audio file couldn't be found. It may have been moved or deleted. Try recording again."
    static let errorTranscriptionFailed = "Transcription didn't finish. Your recording is safe. You can try again."
    static let errorAnalysisFailed = "Summary generation didn't finish. Your transcript is safe. Check your AI service connection or try again."
    static let errorNoAIService = "No AI service connected. Go to Settings to connect one, then try again."
    static let errorMicrophoneDenied = "Microphone access is off. Turn it on in Settings > Privacy > Microphone, then come back."
    static let errorPlaybackFailed = "Couldn't play the recording. The audio file may be missing or damaged."
}

// MARK: - UI extensions for Domain types (keeps SwiftUI out of Domain layer)

extension KnowledgeItemType {
    var color: Color {
        switch self {
        case .audio: .blue
        case .note: .orange
        case .journalEntry: .purple
        case .webBookmark: .green
        case .image: .pink
        }
    }
}

extension TimelineEntry {
    var typeColor: Color { contentType?.color ?? .blue }
}

// MARK: - Card Modifier

struct ProjectCard: ViewModifier {
    let padding: CGFloat
    let cornerRadius: CGFloat

    init(padding: CGFloat = AppSpacing.md, cornerRadius: CGFloat = AppRadius.lg) {
        self.padding = padding
        self.cornerRadius = cornerRadius
    }

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }
}

extension View {
    func projectCard(padding: CGFloat = AppSpacing.md, cornerRadius: CGFloat = AppRadius.lg) -> some View {
        modifier(ProjectCard(padding: padding, cornerRadius: cornerRadius))
    }
}

// MARK: - Input Sanitizer

enum InputSanitizer {
    static let maxUserMessageChars = 50000

    static func sanitize(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\0", with: "")
        if s.count > maxUserMessageChars {
            s = String(s.prefix(maxUserMessageChars)) + "\n\n[Truncated]"
        }
        return s
    }
}

// MARK: - AppStorage Keys

/// Single source of truth for all UserDefaults keys.
/// Replace raw string literals across the codebase with these constants.
enum AppStorageKey {
    static let activeProviderID = "active_provider_id"
    static func modelPreference(providerId: String) -> String { "model_pref_\(providerId)" }
    static let transcriptionMode = "transcription_mode"
    static let transcriptionAllowCloud = "transcription_allow_cloud"
    static let autoTranscribe = "automation_auto_transcribe"
    static let autoAnalyze = "automation_auto_analyze"
    static let autoAnalysisModel = "automation_auto_analysis_model"
    static let autoAnalysisProvider = "automation_auto_analysis_provider"
    static let audioRawMode = "audio_raw_mode"
    static let audioSpeakerphoneMode = "audio_speakerphone_mode"
    static let anarlogAutoImport = "anarlog_auto_import"
    static let anarlogAutoExport = "anarlog_auto_export"
    static let anarlogSyncBookmark = "anarlog_sync_bookmark"
    static let developerModeEnabled = "developer_mode_enabled"
    static let modelResolverTiers = "model_resolver_tiers"
    static let meetilySummaryCache = "meetily_summary_cache"
    static let meetilyCustomTemplates = "meetily_custom_templates"
    static let hasCompletedOnboarding = "has_completed_onboarding"
    static let lastSeenVersion = "last_seen_version"
}
