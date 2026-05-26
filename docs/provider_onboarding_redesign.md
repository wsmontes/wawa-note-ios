# Wawa Note: Provider Onboarding Redesign

**Author:** Helena Vogel, Product Lead (ex-Duolingo, ex-Spotify)
**Date:** 2026-05-26
**Status:** Strategic hiring + redesign mandate

---

## 1. Situation Assessment

The app has a provider setup screen that is a blank form. It asks a non-technical user to choose between "OpenAI Compatible" and "OpenAI" (what is the difference?), type a Base URL (what is that?), paste an API key (where do I get one?), and type a model name manually (what is a model name?). There are zero pre-configured providers. There is no help text. There are no defaults. There are no templates.

Meanwhile, Apple Speech transcription works locally without any provider at all. Recording works without any provider. The app's core value -- capture a meeting, get a transcript -- is available immediately. But the user does not know this, because the provider setup is presented as a gate.

The expert panel documented the 55-year-old manager scenario: opens app, sees provider setup as prerequisite, closes app, opens Voice Memos. This is not hypothetical. This is the guaranteed outcome of the current design.

---

## 2. The Five Specialists

### Specialist 1: Onboarding Designer — Camille Moreau

**Background:** 12 years in mobile onboarding. Led first-launch redesign at Headspace (+40% trial starts), designed onboarding at Calm, consulted for Duolingo on reducing time-to-first-lesson. Previously UX Director at Headspace.

**Deliverable:** First-launch flow specification (wireframes, copy, interaction rules):
- Screen 1: Value proposition + "Start Recording" as primary action (no signup, no config)
- Screen 2: Post-recording result showing transcript (Apple Speech, free, local)
- Screen 3: Optional prompt: "Get AI summaries? Connect an AI service." with pre-configured one-tap options
- Skip/dismiss path that never feels like failure

**Key questions:**
1. What is the absolute minimum the user must do before they experience value? Can we get that to zero?
2. Where exactly in the flow should we introduce connecting an AI service — and how do we make it feel like an upgrade, not a requirement?
3. What does the empty state on the Home screen look like when a user has recorded but has no provider?
4. If a user skips provider setup entirely, what does their first meeting detail screen look like?
5. How do we handle the moment a user taps "Generate Summary" without a provider?

---

### Specialist 2: Provider UX Specialist — Ravi Krishnamurthy

**Background:** 14 years designing technical configuration for non-technical users. Led setup flow at 1Password, device pairing at Sonos, home-network setup at Eero. Currently Principal UX Designer at 1Password.

**Deliverable:** Complete redesign of provider setup screen:
- Pre-configured provider templates (OpenAI, Anthropic, Gemini, LM Studio, Ollama) with pre-filled URLs
- "One-tap connect" flow: pick service → paste API key → auto-test → done
- "Connect your own computer" flow with local network auto-detection
- Progressive disclosure: basic mode (3 fields max) vs. advanced mode behind toggle
- Connection status that is human-readable and actionable

**Key questions:**
1. For 95% of users on OpenAI/Anthropic, can we collapse provider setup to exactly two fields: "Choose your service" and "Paste your API key"?
2. How do we present local network models in a way a non-technical user can understand? Can we auto-detect them?
3. What does the provider setup screen look like with pre-configured templates vs. the current blank form?
4. How do we handle model selection? Auto-discover instead of typing model names?
5. What is the fallback when auto-detection fails? How do we make manual setup feel guided?

---

### Specialist 3: Content & Copywriter — Lina Johansson

**Background:** 16 years in product writing. Led content design at Spotify (Spotify Connect onboarding, voice UI), Head of Content at Notion (rewrote every string during 2.0 redesign), consulted for Figma on AI feature naming. Currently independent.

**Deliverable:** Complete string audit and rewrite for every user-facing string, plus copy style guide:
- Provider type names rewritten for humans
- Form labels, placeholders, help text in plain language
- Error messages: what happened + what was preserved + what to do
- Empty states that educate without lecturing
- One-sentence value proposition
- Product naming recommendation

**Key questions:**
1. What do we call each provider type in user-facing text? What does a non-technical user call "OpenAI Compatible"?
2. What is the one-sentence value proposition? Can we say it in 8 words or fewer?
3. How do we rewrite the provider setup form so every field has a clear, plain-language label?
4. What do we call the product? Give us three alternatives to "Wawa Note."
5. What is the voice and tone? Write a 10-point style guide for developers writing new strings.

---

### Specialist 4: Technical Integration Architect — Dr. Soren Lindqvist

**Background:** 18 years in developer tools and API design. Built API client SDKs at Stripe, designed the plugin system at Figma, architected provider abstraction layer at Vercel AI SDK. Currently Principal Engineer at Vercel.

**Deliverable:** Technical specification for pre-configured provider templates, auto-detection, and smart defaults:
- JSON template format: base URL, auth type, model discovery endpoint, default model, required/optional fields
- Local network auto-detection logic: scan common ports (1234 for LM Studio, 11434 for Ollama)
- Model auto-discovery: call provider's models endpoint, parse response, present picker
- Smart defaults: pick "OpenAI" → pre-fill URL, only ask for API key
- Migration path for existing users with manually configured providers

**Key questions:**
1. What is the minimum data we need per pre-configured provider template?
2. How do we auto-detect local network models? Bonjour/mDNS? Port probing?
3. How do we auto-discover available models? Which providers support this?
4. Should templates be bundled in the app, fetched remotely, or both?
5. How do we handle auth types that are not a simple API key? (OAuth, no auth for local models)

---

### Specialist 5: QA & Testing Lead — Maria Santos Rocha

**Background:** 13 years in usability testing and QA. Led testing at Nubank (first-time banking users in Brazil), built QA practice at Duolingo (weekly usability sessions, ages 18-75), consulted for Apple on VoiceOver accessibility testing. Currently Head of QA at Nubank.

**Deliverable:** Usability test plan with 15 scenarios, participant screening criteria, session scripts, success metrics:
- 8 participants (mix technical/non-technical, ages 30-65)
- 15 task scenarios: first launch, recording, transcription, provider setup, analysis, export
- Watch points: time to first value, confusion points, abandonment points, vocabulary problems
- Benchmark: test current blank-form flow with 2 participants, redesigned flow with 6 participants

**Key questions:**
1. What are the 5 critical tasks that define success? If a participant cannot complete these, the redesign has failed.
2. How do we recruit non-technical participants? What screening questions filter out engineers?
3. What do we measure quantitatively? Time-on-task? Error rate? Abandonment rate?
4. How do we test local-network provider flow without requiring LM Studio/Ollama running?
5. What is the post-test analysis protocol? Must-fix vs. nice-to-have classification?

---

## 3. The 10-Point Adjustment Plan

Prioritized, with effort estimates (S = 1-2 days, M = 3-5 days, L = 1-2 weeks):

| # | Change | Effort |
|---|--------|--------|
| 1 | **Ship pre-configured provider templates.** Bundle JSON templates for OpenAI, Anthropic, Gemini, LM Studio, Ollama. User picks service, pastes API key. Done. Eliminates 3 of 5 fields for 95% of users. | M |
| 2 | **Redesign first-launch flow so recording works without a provider.** Home screen with "Start Recording." Apple Speech works locally. Transcript immediately. No gate. | M |
| 3 | **Build the "one-tap connect" provider flow.** Step 1: Choose service from picker with logos. Step 2: Paste API key. Step 3: Auto-test. Done. Advanced toggle for current form. | L |
| 4 | **Add model auto-discovery.** After connecting, call models endpoint. Show picker. Default to best model. User never types a model name. | M |
| 5 | **Rewrite every user-facing string.** Human names for provider types. Plain-language form labels. Actionable errors. Warm empty states. | M |
| 6 | **Remove the Import Audio button (or make it work).** Currently non-functional. Either implement or hide with explanation. Trust breach in first 5 seconds. | S |
| 7 | **Add local network auto-detection.** Scan ports 1234 (LM Studio), 11434 (Ollama). Auto-offer found endpoints. No URL typing. | M |
| 8 | **Add "Use Free Transcription" badge on Home screen.** Shows Apple Speech is active: "Transcription: On-device (free, private)." Changes mental model from "app doesn't work" to "app is working, upgrade available." | S |
| 9 | **Show guided provider prompt after first recording.** After user views first transcript, warm prompt: "Want AI summaries of your meetings? Connect an AI service." One-tap options. | S |
| 10 | **Rename the product.** Two words max, no invented syllables, second word anchors the category. | S |

---

## 4. The Single Most Important Change

**Ship pre-configured provider templates and make provider setup one-tap.**

The current form: 5 fields, zero defaults, zero guidance. Non-technical user closes app.

The redesigned flow has exactly 2 steps for 95% of users:

1. **Choose your AI service.** A scrollable picker showing recognizable names and logos: "ChatGPT by OpenAI," "Claude by Anthropic," "Google Gemini," "A model on my computer (LM Studio)," "A model on my computer (Ollama)."

2. **Paste your API key.** That is the only thing the user types. Link: "Get an API key at platform.openai.com." After paste, auto-test connection. Auto-discover models. Pick best one. User sees "Connected to ChatGPT by OpenAI. Using GPT-4o." Taps "Done."

30 seconds. Requires knowing one thing (which service) and having one thing (API key). No URL. No model name. No provider type.

For power users: the current form remains behind an "Advanced" toggle.

---

## 5. What the Provider Screen Should Look Like

### Screen 1: Provider List (new default)

- Title: "AI Services." Subtitle: "Connect an AI service to generate meeting summaries and action items."
- A list of pre-configured provider CARDS (not a blank empty state):
  - "ChatGPT by OpenAI" — Cloud AI. Requires an API key.
  - "Claude by Anthropic" — Cloud AI. Requires an API key.
  - "Google Gemini" — Cloud AI. Requires an API key.
- Section: "On Your Computer":
  - "LM Studio" — Runs on your Mac. No API key needed. Free.
  - "Ollama" — Runs on your Mac. No API key needed. Free.
- Bottom disclosure group: "Advanced" → "Custom Provider" (the current blank form, for power users)

### Screen 2: Provider Connection (after tapping a card)

**Cloud providers:**
- Logo + name + "Enter your API key to connect."
- Single field: SecureField "API Key." Placeholder: "Paste your API key here."
- Link: "Get an API key at platform.openai.com"
- "Connect" button → auto-test
- Success: checkmark + "Connected to ChatGPT by OpenAI" + model list with best one pre-selected
- Failure: "Check that your API key is correct and you have an internet connection." + "Try Again"
- Bottom text link: "Advanced settings" → reveals current full form

**Local providers:**
- Logo + name + "Connect to a model running on your computer."
- Auto-scan: "Looking for LM Studio on your network..."
- Found: "Found LM Studio on MacBook-Pro.local." → "Connect" (one tap, no fields)
- Not found: "Make sure LM Studio is running and both devices are on the same Wi-Fi." + manual URL entry
- On connect: auto-discover models, show picker, select default

### Screen 3: First Recording Complete prompt (new)

Appears after user records first meeting and views transcript:
- Sparkles icon
- "Want AI-powered summaries?"
- "Connect an AI service to automatically generate meeting summaries, action items, and key decisions."
- "Connect an AI Service" (opens Screen 1) or "Not Now"
- Small text: "Your recordings and transcripts stay on your iPhone."

### What disappears:

1. Blank empty state → replaced by provider picker cards
2. ProviderType picker → replaced by card-based service picker
3. Base URL field (default path) → pre-filled from templates
4. Model name text field → auto-discovered model picker
5. Capabilities toggles → pre-filled from templates
6. Notes field → only in Advanced
7. Raw "Test Connection" technical text → automatic test with human results

---

## 6. Closing Note

At Duolingo, we had a rule: if a new user could not complete a lesson within 60 seconds of opening the app, the onboarding had failed. Wawa Note currently fails this test catastrophically.

The fix is not a copy change. It is a fundamental redesign of how the app introduces itself and asks for configuration. The app must deliver value first (recording + transcription, free, local, immediate). It must ask for configuration second (provider connection, one-tap, pre-filled). It must never make the user feel stupid for not knowing what a "Base URL" is.

-- Helena Vogel
