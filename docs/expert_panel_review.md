# Wawa Note — Expert Panel Review

Date: 2026-05-26
Reviewers: 6 independent experts (ex-Google, ex-Apple, ex-Meta)

---

## Panel

| Role | Name | Background |
|---|---|---|
| Product Management | Priya Mehta | Director of Product, Google (12y). Google Meet recordings, Google Keep. |
| UX Design | Daniel Chen | Senior UX Designer, Apple (8y). Voice Memos, Notes, Shortcuts. |
| UI / Design Systems | Isabella Rossi | Design Systems Lead, Meta (6y). Instagram, WhatsApp design systems. |
| Marketing & Positioning | Marcus Thompson | Product Marketing Lead, Apple (10y). iPhone 14 campaigns, App Store editorial. |
| Usability & Accessibility | Dr. Amara Okafor | Principal Researcher, Google (9y). Google Meet, Google Assistant usability. |
| Commercial & Business | Ricardo Santos | Business Strategy Director, Meta (7y). WhatsApp monetization, creator economy. |

---

## 1. Product Management — Priya Mehta

### MVP Scope

- **Cut:** Chat (Phase 7). "Scope creep. There are twenty ChatGPT apps. There are zero great mobile meeting intelligence apps. You burned cycles on a commodity feature."
- **Add:** Basic speaker diarization. Without it, action item ownership is fiction.

### Sequencing

- Phase 7.5 should not exist. "Meeting ID propagation, artifact folder structure, source evidence mapping — these are Phase 1-5 concerns, not cleanup."
- Phase 8 should run continuously from Phase 2, not be the last checkpoint. "Device validation on day one of Phase 2 would have surfaced iOS background constraints immediately."

### Top 3 Risks

1. **iOS background execution.** "A meeting recorder that requires the user to keep their phone unlocked for 60 minutes is not a meeting companion — it is a hostage situation."
2. **The Swiss Army knife trap.** Competing with Apple Intelligence AND being a meeting tool simultaneously dilutes focus. "Pick one beachhead."
3. **No defensibility.** "A competent iOS team replicates this in six weeks." Moat = structured meeting data layer accumulated across meetings and projects.

### MVP Success Metric

Completed meeting loop rate: percentage of recorded meetings that reach export/share within 48h. Target: >60%.

### Would you fund this?

"I would fund the meeting intelligence vertical with narrow scope. I would not fund the 'Universal AI Client' framing. Phase 8 is not hardening — it is the actual proof the product works."

### This Week's Recommendation

"Remove the Chat tab from the default tab bar. Take a build to an iPhone 14 Plus and run a 15-minute real meeting through it. Document every failure."

---

## 2. UX Design — Daniel Chen

### Biggest UX Mistake

"You drop the user into a void after they stop recording. The post-stop screen says 'Done' and strands the user. No path from that moment into the meeting detail. The app should pull them forward, not eject them."

### Home Tab Decision

"Correct. Defend it. A dedicated Record tab would sit empty 95% of the time, wasting prime tab bar real estate. The Home tab pattern is what Voice Memos does."

### The Love-Trigger Interaction

"Mark Important during recording. Large tappable area, subtle haptic on tap. After the meeting, those markers become the skeleton the summary is organized around. Each marker becomes a section header. The user feels like they conducted the AI, not the other way around."

### Recording → Review → Export Flow

Three breaks:
1. Gap after stopping recording
2. No "Ask about this meeting" from meeting detail — chat and meeting are entirely separate products
3. Source evidence not wired up — traceability promise is paper only

### Post-Recording Redesign

"Stop shows confirmation → inline processing card animates through stages → card transforms into summary preview with first two lines → primary action is 'View Meeting' → processing continues in background → Home screen gets 'New' badge if user navigates away."

### Missing Apple Pattern

"Live Activities. During recording, the Dynamic Island should show timer and stop glyph. An iPhone recording app without this in 2026 feels fundamentally unfinished."

---

## 3. UI / Design Systems — Isabella Rossi

### Component Library: Grade C (3 of 10 built)

| Component | Status | Issue |
|---|---|---|
| AppStatusBadge | Exists | `.error` and `.recording` both return `.red` — indistinguishable. No accessibility label. |
| PrimaryActionButton | Exists | No `role` param — cannot build destructive variant. Spinner + Label conflict. |
| EmptyStateView | Exists | Only one action slot. Manual specs two simultaneous actions for first-launch. |
| ProcessingPipelineView | Missing | — |
| RecordingControlsView | Missing | — |
| AudioLevelMeterView | Missing | Inlined in RecordView (85-112). |
| MeetingCard | Missing | Inlined. |
| InsightCard | Missing | — |
| TranscriptSegmentRow | Missing | Inlined in MeetingDetailView (460-483). |
| ProviderPicker | Missing | — |

### Screen Critiques

**MeetingDetailView (509 lines):** "Most overgrown file in the app. 2 of 5 sections shipped. Tasks and Ask are MIA — the two sections that make AI output actionable. 80+ lines of near-identical card blocks."

**RecordView:** "No Mark Important button anywhere. Done button uses `.borderedProminent` directly instead of PrimaryActionButton. No confirmation dialog before stopping."

### Most Needed Token

"Semantic color namespace. `AppSpacing` exists in the manual but not in the codebase. `AppColor` or `SemanticColor` does not exist anywhere. Every view picks raw `Color.red`, `Color.orange`, `Color.green` ad hoc. A single `.recordingPulse` token, a single `.errorText` token — none exist. If someone changes what red means for recording, they must hunt through six files."

### Chat UI: Not Ready

"No streaming. No message toolbar (copy, regenerate). No provider/model badge in toolbar. No quick prompts. Just 'Send a message to start.' — empty-state copy from 2020."

### Pattern Power Users Will Hate

"No tap-to-seek on transcript timestamps. No long-press to copy. No swipe-to-delete on meeting rows. These are not power-user features; they are iOS platform expectations. When absent, the app feels like a React Native port."

---

## 4. Marketing & Positioning — Marcus Thompson

### The One Sentence

> "Wawa Note records your meetings, transcribes them privately on-device, and gives you a searchable memory of every decision, action item, and commitment — without your data ever touching a server you don't control."

### Target User

"The privacy-conscious knowledge worker who lives in meetings and feels the anxiety of information loss. Works at companies with NDAs or sensitive IP (legal, consulting, tech, finance). Has been burned by a SaaS transcription tool that uploaded their board deck to a cloud they don't control."

### Biggest Positioning Mistake

"The product tries to be two things: a 'universal AI client' AND a 'meeting companion.' That is positioning suicide. A universal AI client competes with ChatGPT, Poe, and every wrapper app. A meeting companion solves one job with precision."

### App Store Pitch

"Headline: Your meetings stay on your phone. Your insights don't. Position it as the privacy answer to Otter.ai, Fireflies, and Fathom. App Store editorial loves a David vs. Goliath privacy story, especially native SwiftUI with on-device intelligence."

### Hero Feature

"Cross-meeting project memory. 'Show me every action item assigned to me across the last 6 GLPR meetings' — nobody has nailed this on mobile. The recording is how you get the data in. The memory is why you keep the app."

### The Name: Change It

"Three problems: sounds like a toy (baby talk, convenience store, or crying infant), says nothing about what the product does, and zero App Store discoverability. Two words maximum, no invented syllables, second word should anchor the category — like 'Boardroom,' 'Meeting Memory,' or 'Recall AI.'"

---

## 5. Usability & Accessibility — Dr. Amara Okafor

### First Launch

"Import Audio button is a non-functional TODO. That is a trust-breach in the first five seconds. Provider setup gates the entire value proposition — a new user is funneled into Base URL, API key, and model name fields before seeing any value. That is not progressive disclosure; that is a gate."

### Most Dangerous Usability Failure

"Meeting ID generated after recording stops. If the app crashes mid-recording, audio exists on disk under a random UUID with no link to any meeting record. The user sees nothing. That audio is lost — invisible and unrecoverable. For a meeting recorder, this is the cardinal sin." *(Note: this was fixed in Phase 7.5)*

### Error Messages

"The UX manual prescribes an excellent formula: what happened, what was preserved, what to do next. But implementation falls short. Provider errors collapsed into 'Could not connect,' 'Could not connect to provider,' 'Failed to get response.' The user cannot distinguish bad URL from wrong API key from network timeout from server incompatibility. Recovery path is different for each."

### Accessibility

"Transcript segments rendered word-by-word from Apple Speech create a wall of tiny, dense text rows. At large Dynamic Type sizes, this view will be completely unusable — overlapping text, indistinguishable tap targets. A transcript is the core artifact of this product, and it has not been designed for anyone who needs accessibility support."

### The 55-Year-Old Manager

"Has a meeting in five minutes. No patience for configuration. Taps Start Meeting. Records. Stops. Sees nothing. App says 'Connect a provider to generate a summary.' Now has to understand OpenAI-compatible vs Anthropic, find an API key, enter a Base URL, type a model name. Closes the app and opens Voice Memos instead. This is the guaranteed outcome of forcing provider setup as a prerequisite."

### Privacy Mode: Marketing, Not Mechanics

"Settings shows 'Local first' — it is static UI text. Privacy mode is not modeled in the data layer. There is no per-meeting processing mode. The app always picks the first provider and sends the transcript to it. A user who believes their audio stayed on-device because they selected 'Local first' has been misled. This is not just a UX gap; it is a privacy promise the product cannot currently keep."

---

## 6. Commercial & Business — Ricardo Santos

### Business Model

"Freemium. One free meeting per week (full analysis). $9.99/month unlimited meetings, structured extraction, project memory, multi-provider. Enterprise $29.99/seat/month for team workspaces, shared glossaries, Jira/Confluence export. Local-first processing is a margin lever — every meeting analyzed on-device costs zero in API fees."

### Competition

"Otter.ai ($300M+ raised), Fireflies.ai, Fathom ($17M), Granola. Crowded field, well-funded, all iterating faster than a solo developer. Differentiator: provider-agnostic, privacy-first. But that is a feature, not a moat. Any of them could add local processing in a quarter."

### TAM

"Global meeting productivity market ~$35B by 2027. But your addressable slice — AI-powered meeting notes for iPhone users who care enough about privacy to choose an indie app — is probably $200M-$500M. Big enough for a $20M-$50M company? Yes. Venture-scale returns? Borderline. Realistic outcome: exit to Notion, Dropbox, or Apple."

### Why Won't Apple Build This?

"They already are. iOS 18 transcribes Voice Memos. Apple Intelligence summarizes audio. Notes has live transcription. The gap shrinks every September. Wedge: Apple will never support third-party AI providers. You are betting Apple's transcription is bad enough and their summarization is closed enough that power users will pay."

### What Would Make Me Invest $500K

"Four things: (1) 200 WAUs, 40% 30-day retention. (2) Five paying users at >$5/month unprompted. (3) App running on real iPhone 14 Plus, 60-minute recording, no crash. (4) One enterprise design partner — a law firm or consultancy — who articulates why Otter/Fireflies is a non-starter for compliance. Get me three of four and I wire the money."

### Paid Differentiator

"Cross-meeting project memory. 'What have we decided about the deployment timeline across the last four standups?' Sticky, hard to build, nobody on iPhone does it credibly. Build it, paywall it, call it 'Project Brain.'"

---

## 7. Consensus: Top 10 Actions

| # | Action | From | Priority |
|---|---|---|---|
| 1 | Remove Chat from main tab bar; make it a secondary feature | PM, UX | P0 |
| 2 | Fix post-recording flow: navigate user directly into meeting detail, never strand them | UX, Usability | P0 |
| 3 | Implement Mark Important button with haptic feedback | UX, UI | P1 |
| 4 | Make provider OPTIONAL for core recording value; ship sample/demo summaries | Usability, PM | P1 |
| 5 | Split `.recording` and `.error` badge colors; build semantic color tokens | UI | P1 |
| 6 | Build the remaining 7 components from the component library spec | UI | P1 |
| 7 | Wire up source evidence: tap a decision → hear the moment it was made | UX, UI | P2 |
| 8 | Rename the product before App Store submission | Marketing | P2 |
| 9 | Narrow positioning: meeting intelligence app, not universal AI client | PM, Marketing | P2 |
| 10 | Validate 60-minute recording on real iPhone 14 Plus before writing more features | PM, Commercial | P0 |

---

## 8. Verdict

**Unanimous:** The architecture is thoughtful, the team has execution capability, and the privacy-first, provider-agnostic approach is a real wedge. But the product is currently telling too many stories, shipping too many half-finished surfaces, and has not yet proven the one thing that matters: that a real meeting can be recorded, transcribed, analyzed, and trusted on a real iPhone 14 Plus.

**The path forward is narrowing, not expanding.** Remove features that dilute focus. Harden the meeting loop until it is bulletproof on real hardware. Then build the AI memory layer nobody else has.

---

*Panel convened 2026-05-26. All reviewers independent. No equity, no consulting fees. Brutal honesty only.*
