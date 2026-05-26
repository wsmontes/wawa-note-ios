# wawa-note — Brand & App Design Guide

Design document aligned with the generated logo/app-icon image set and the current product direction.

Project: **wawa-note**  
Product type: **AI meeting companion / universal AI client for iPhone**  
Target platform: **iOS / iPhone 14 Plus first**  
Design direction: **native, calm, technical, trustworthy, audio-aware, AI-enabled**

---

## 1. Design Intent

The visual identity of **wawa-note** should communicate four ideas immediately:

1. **Voice / audio capture**  
   The app records meetings, listens, transcribes, and turns spoken information into useful artifacts.

2. **AI assistance**  
   The app is not just a recorder. It understands, summarizes, extracts tasks, and lets the user ask questions about conversations.

3. **Native iPhone quality**  
   The app should feel like it belongs on iOS: clean, rounded, restrained, accessible, and polished.

4. **Personal but professional**  
   The name “wawa-note” has a friendly tone, but the app is for real work. The design should be approachable without becoming childish.

The brand should feel closer to:

```text
Apple Notes + Voice Memos + ChatGPT + meeting analyst
```

and not like:

```text
A generic chatbot app with neon AI decoration
```

---

## 2. Logo Concept

## 2.1 Primary Mark

The primary symbol is a rounded **waveform-style W**.

It represents:

- **W** for `wawa`.
- **Waveform** for speech, meetings, transcription, and audio capture.
- **Flow** for continuous conversation and AI processing.
- **Rounded continuity** for a friendly, app-native feel.

The small dot at the upper-right acts as:

- a soft AI presence,
- a visual endpoint,
- a signal/notification cue,
- a compact brand accent.

The mark should remain simple enough to work as:

- iOS app icon,
- toolbar icon,
- splash-screen logo,
- onboarding graphic,
- document/export watermark,
- compact brand mark.

---

## 2.2 Wordmark

The wordmark is:

```text
wawa-note
```

Recommended treatment:

- `wawa` in dark ink or white.
- `-note` in purple/accent gradient direction.
- lowercase only.
- rounded geometric sans-serif feel.
- no extra capitalization.

Preferred casing:

```text
wawa-note
```

Avoid:

```text
Wawa Note
WawaNote
WAWA-NOTE
WaWaNote
```

Reason: the lowercase form feels more native, compact, and product-like.

---

## 3. Brand Personality

The visual identity should be:

- calm,
- precise,
- modern,
- minimal,
- audio-aware,
- quietly intelligent,
- reliable,
- local-first,
- privacy-aware.

It should not be:

- loud,
- toy-like,
- over-branded,
- corporate generic,
- overly futuristic,
- overloaded with AI sparkle effects.

The right emotional tone is:

```text
A smart meeting notebook that quietly works for you.
```

---

## 4. Color System

## 4.1 Primary Gradient

The main brand expression is a blue-to-purple gradient.

Recommended colors:

```text
Cyan      #0CB5FF
Blue      #196EF0
Purple    #7352FF
Accent    #854EFF
```

Usage:

- primary logo mark,
- splash screen symbol,
- selected brand moments,
- app icon symbol,
- onboarding hero,
- empty-state illustration accents.

Avoid using the gradient everywhere. It should signal the brand, not dominate the interface.

---

## 4.2 Neutral Colors

Recommended neutrals:

```text
Deep Navy       #050A18
Dark Navy       #070D1F
Ink             #141C2A
Secondary Text  #5E6473
Muted Text      #969AA5
Surface Light   #F8F9FC
White           #FFFFFF
```

Usage:

- Deep Navy: splash/background hero.
- Ink: primary text on light background.
- Secondary Text: captions and metadata.
- Surface Light: app-icon background and clean marketing sections.
- White: inverted mark and dark-mode UI elements.

---

## 4.3 Functional Colors

Functional UI should rely on iOS semantic colors wherever possible.

Recommended mapping:

| Function | Direction |
|---|---|
| Recording | System red |
| Saved/success | System green |
| Warning | System orange/yellow |
| Error | System red |
| Local/on-device | Blue or green badge |
| Remote/API | Purple or blue badge |
| Neutral state | Secondary gray |

Important rule:

> Brand colors should not replace functional state colors when the user needs clarity.

For example, recording should still look like recording, not like a purple AI state.

---

## 5. App Icon System

## 5.1 Primary App Icon

Use:

```text
AppIcon.appiconset
```

Primary visual:

- white/light background,
- rounded iOS icon shape handled by the system,
- gradient waveform-W mark centered,
- enough whitespace for legibility.

This is the recommended default because it is:

- clean,
- readable at small sizes,
- consistent with iOS home screen style,
- less visually heavy than the dark icon,
- professional enough for work use.

---

## 5.2 Dark App Icon

Use:

```text
AppIcon-Dark.appiconset
```

Best for:

- future alternate app icon,
- internal testing,
- premium/pro mode,
- dark marketing screens.

Do not use both icon sets at the same time unless alternate app icon support is implemented.

---

## 5.3 Color Variations

Generated variations:

```text
AppIcon-Default-1024.png
AppIcon-Dark-1024.png
AppIcon-Blue-1024.png
AppIcon-Purple-1024.png
AppIcon-Green-1024.png
AppIcon-Amber-1024.png
AppIcon-Mono-Light-1024.png
AppIcon-Mono-Dark-1024.png
```

Recommended use:

| Asset | Use |
|---|---|
| Default | Main app icon |
| Dark | Alternative icon / splash / marketing |
| Blue | Internal build / dev flavor |
| Purple | AI-focused marketing variant |
| Green | Local/privacy-focused variant |
| Amber | Experimental / warning not recommended as default |
| Mono Light | Documents, diagrams, low-color contexts |
| Mono Dark | Dark UI, watermark, monochrome branding |

---

## 6. Symbol Usage

## 6.1 Symbol Assets

Generated symbol-only files:

```text
Symbol-Gradient.svg
Symbol-Dark.svg
Symbol-Gradient-Transparent-1024.png
Symbol-White-Transparent-1024.png
Symbol-Dark-Transparent-1024.png
Symbol-Gradient-Transparent-512.png
Symbol-Gradient-Transparent-256.png
Symbol-Gradient-Transparent-128.png
```

---

## 6.2 When to Use Symbol Only

Use the symbol without wordmark when space is limited:

- app icon,
- navigation header mark,
- splash center mark,
- compact onboarding card,
- empty-state illustration,
- favicon/web later,
- small document watermark.

Avoid using the symbol as a generic button icon for recording or chat. For UI actions, prefer SF Symbols so the app remains native and accessible.

Examples:

- Start Recording: use SF Symbol `mic.circle.fill` or `record.circle`.
- Export: use SF Symbol `square.and.arrow.up`.
- Settings: use SF Symbol `gearshape`.
- Brand header: use wawa-note symbol.

---

## 7. Wordmark Usage

## 7.1 Wordmark Assets

Generated files:

```text
Wordmark-Horizontal.svg
Wordmark-Horizontal-Light-Transparent.png
Wordmark-Horizontal-Dark-Transparent.png
```

---

## 7.2 Recommended Use Cases

Use the wordmark in:

- splash/welcome screen,
- About screen,
- exported PDF/Markdown cover later,
- marketing screenshots,
- documentation headers,
- app website later.

Do not use the full wordmark in every app screen. Inside the app, the navigation title can simply be:

```text
wawa-note
```

or, in functional contexts:

```text
Meetings
Chat
Settings
```

The app should prioritize task clarity over constant branding.

---

## 8. Splash / Welcome Screen

## 8.1 Splash Asset

Generated file:

```text
Splash-iPhone14Plus-Dark.png
```

This is designed for a dark, premium launch/welcome moment.

Recommended copy:

```text
Understand your meetings.
Accelerate your decisions.
```

Alternative copy:

```text
Record. Transcribe. Summarize. Ask.
```

Avoid overly promotional text like:

```text
The ultimate AI-powered productivity revolution.
```

The brand tone should stay practical and calm.

---

## 8.2 In-App Welcome Layout

Recommended first-run structure:

```text
[Symbol / wordmark]

Capture meetings, turn them into summaries,
and ask questions about what was said.

[Start a test recording]
[Set up AI provider]
```

This aligns with the app's intended minimal onboarding approach.

---

## 9. In-App Visual Application

## 9.1 Home Screen

The logo should appear subtly.

Recommended:

- small symbol or wordmark at top,
- primary action card for `Start Meeting`,
- setup/status cards below,
- recent meetings list.

Do not make the Home screen a brand poster. It should be functional.

---

## 9.2 Recording Screen

The brand should almost disappear during active recording.

Why:

- the user is in a real meeting,
- recording status matters more than branding,
- the interface must be calm and reliable.

Use:

- iOS red recording state,
- timer,
- audio meter,
- `Mark Important`,
- pause/stop controls.

Do not use the gradient logo as the recording indicator.

---

## 9.3 Meeting Detail Screen

Use brand colors sparingly:

- accent for summary-ready state,
- subtle gradient symbol in empty states,
- purple/blue badge for AI-generated insight,
- neutral cards for content.

Meeting detail should focus on:

- Summary,
- Transcript,
- Tasks,
- Ask,
- Info.

---

## 9.4 Chat Screen

The chat screen should not look like a separate AI brand.

Recommended:

- use native chat layout,
- show provider/model status,
- use brand gradient only for assistant avatar or subtle accent,
- keep bubbles readable.

The brand should support trust, not distract from content.

---

## 10. Typography

Use Apple system typography in the app.

Recommended in SwiftUI:

```swift
.largeTitle
.title2
.headline
.body
.subheadline
.caption
```

For the logo/wordmark assets, use the generated image/SVG assets rather than trying to recreate the wordmark with system text in every place.

UI copy should be:

- short,
- direct,
- human,
- not technical unless necessary.

Examples:

Good:

```text
Audio saved. Transcription failed. You can retry.
```

Bad:

```text
The audio artifact was persisted but downstream processing terminated unexpectedly.
```

---

## 11. Iconography

Use SF Symbols for functional UI.

Recommended mapping:

| Concept | SF Symbol Direction |
|---|---|
| Start recording | `mic.circle.fill` / `record.circle` |
| Active recording | `record.circle.fill` |
| Pause | `pause.circle.fill` |
| Stop | `stop.circle.fill` |
| Meeting | `calendar` / `person.2` |
| Transcript | `text.alignleft` |
| Summary | `doc.text` |
| Tasks | `checklist` |
| Decisions | `checkmark.seal` |
| Risks | `exclamationmark.triangle` |
| Questions | `questionmark.circle` |
| Provider | `network` / `server.rack` |
| Local | `iphone` |
| Remote | `cloud` |
| Local network | `wifi.router` |
| Privacy | `lock.shield` |
| Export | `square.and.arrow.up` |
| Settings | `gearshape` |

Use the wawa symbol for brand, not for every function.

---

## 12. Component Styling Direction

## 12.1 Buttons

Primary buttons may use the app accent blue/purple, but should still feel native.

Recommended:

- full-width primary button on main action screens,
- minimum height around 50pt,
- rounded corners,
- SF Symbol + label where helpful.

Examples:

```text
Start Meeting
Generate Summary
Save Provider
```

---

## 12.2 Badges

Badges should be compact and readable.

Examples:

```text
Local
Remote analysis
Audio on device
Summary ready
Recording
```

Use color carefully:

- Recording: red.
- Local: blue/green.
- Remote/API: purple/blue.
- Error: red.
- Neutral: gray.

---

## 12.3 Cards

Cards should use iOS-style surfaces, not heavy marketing blocks.

Recommended:

```swift
Color(.secondarySystemGroupedBackground)
RoundedRectangle(cornerRadius: 16, style: .continuous)
```

Use cards for:

- meeting summary,
- action items,
- provider status,
- processing pipeline,
- recent meeting preview.

---

## 13. Accessibility Rules

The brand assets must not reduce usability.

Rules:

- Do not rely on gradient color alone to communicate state.
- Use text labels with important icons.
- Ensure app icon remains legible at small sizes.
- Keep functional controls separate from decorative brand assets.
- Support light and dark mode.
- Use semantic colors in the UI.
- Maintain high contrast for text.

---

## 14. Asset Implementation Guide

## 14.1 Xcode App Icon

Use:

```text
AppIcon.appiconset
```

Copy to:

```text
wawa-note/Resources/Assets.xcassets/
```

If replacing an existing app icon set, keep the name:

```text
AppIcon
```

so Xcode continues to find it.

---

## 14.2 In-App Assets

Recommended asset catalog names:

```text
WawaSymbolGradient
WawaSymbolWhite
WawaSymbolDark
WawaWordmarkLight
WawaWordmarkDark
WawaSplashDark
```

Potential file mapping:

| Asset catalog name | Source file |
|---|---|
| WawaSymbolGradient | `Symbol-Gradient-Transparent-1024.png` |
| WawaSymbolWhite | `Symbol-White-Transparent-1024.png` |
| WawaSymbolDark | `Symbol-Dark-Transparent-1024.png` |
| WawaWordmarkLight | `Wordmark-Horizontal-Light-Transparent.png` |
| WawaWordmarkDark | `Wordmark-Horizontal-Dark-Transparent.png` |
| WawaSplashDark | `Splash-iPhone14Plus-Dark.png` |

---

## 14.3 SVG Usage

SVG files should be treated as source/vector references:

```text
Symbol-Gradient.svg
Symbol-Dark.svg
Wordmark-Horizontal.svg
```

Use them for:

- future refinement,
- website,
- documentation,
- marketing,
- exporting sharper variants.

For Xcode/iOS raster usage, PNGs are simpler and safer.

---

## 15. Do / Don't

## 15.1 Do

- Use the default app icon for the first build.
- Use the symbol sparingly inside the app.
- Use the wordmark in onboarding/About/marketing.
- Keep functional UI native.
- Preserve calm, clean spacing.
- Use brand gradient as an accent.
- Keep recording UI functional and unmistakable.

## 15.2 Don't

- Do not use the logo as every button icon.
- Do not make the whole app dark-gradient by default.
- Do not overuse purple/blue glow effects.
- Do not make AI look magical or flashy.
- Do not hide recording/privacy states behind branding.
- Do not use the amber icon as the primary icon unless the product direction changes.
- Do not expose raw technical/provider names in normal UI when a simpler name works.

---

## 16. Recommended Default Decisions

| Design Decision | Recommendation |
|---|---|
| Primary app icon | `AppIcon.appiconset` default/light icon |
| Splash style | Dark splash with centered symbol/wordmark |
| Main brand colors | Cyan → Blue → Purple gradient |
| Main UI style | Native iOS, light/dark adaptive |
| Wordmark casing | `wawa-note` lowercase |
| Symbol use | Brand-only, not functional icon replacement |
| UI icon set | SF Symbols |
| Button style | Native rounded primary/secondary/destructive hierarchy |
| Recording state | System red, not brand gradient |
| Empty states | Subtle symbol + useful text/action |

---

## 17. Claude Code / Developer Instructions

When applying this design in the app:

1. Copy `AppIcon.appiconset` into `Assets.xcassets`.
2. Add symbol and wordmark PNGs to the asset catalog using clear names.
3. Use the default app icon first.
4. Do not implement alternate icons until explicitly requested.
5. Use SF Symbols for UI actions.
6. Keep the Home screen functional, not brand-heavy.
7. Use the brand gradient only for identity moments and subtle accents.
8. Keep recording UI dominated by recording state, timer, and controls.
9. Preserve accessibility: labels, contrast, Dynamic Type.
10. Update this design guide if asset names or visual rules change.

Suggested prompt for Claude Code:

```text
Read docs/BRAND_DESIGN_GUIDE.md and docs/UX_UI_MANUAL.md.

Apply the wawa-note brand assets without changing product behavior.

Tasks:
1. Install AppIcon.appiconset into Assets.xcassets.
2. Add symbol and wordmark assets to Assets.xcassets.
3. Use the symbol subtly on Home/About only.
4. Do not replace SF Symbols for functional controls.
5. Keep recording UI native and clear.
6. Update docs if asset names differ.
```

---

## 18. Final Direction

The visual identity should make **wawa-note** feel like:

```text
A native iPhone meeting intelligence tool that quietly captures, organizes, and explains conversations.
```

The logo system supports that through:

- a waveform-like W,
- calm blue/purple intelli