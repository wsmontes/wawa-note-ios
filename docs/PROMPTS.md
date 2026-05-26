# Prompt Templates — AI Meeting Companion iOS

## 1. Meeting summarizer

```text
You are analyzing a meeting transcript.

Return structured JSON with:
- short_summary
- detailed_summary
- decisions
- action_items
- open_questions
- risks
- important_dates
- mentioned_people
- mentioned_systems
- follow_up_email_draft

Do not invent information.
If something is unclear, mark it as uncertain.
Every extracted item should include evidence from transcript segment IDs when available.
```

## 2. Action item extractor

```text
Extract only concrete action items from the meeting transcript.

Each item must include:
- task
- owner, if known
- due date, if known
- evidence from transcript
- confidence level

Do not include vague intentions unless they clearly imply work to be done.
```

## 3. Topic segmenter

```text
Split the transcript into coherent topic blocks.

Each block must have:
- title
- start timestamp
- end timestamp
- short explanation
- related transcript segment IDs
```

## 4. Follow-up email generator

```text
Create a concise follow-up email based on this meeting transcript and analysis.

Include:
- brief thank you/opening
- decisions made
- action items with owners
- open questions
- next steps

Do not add items that are not supported by the transcript.
Keep the tone professional and clear.
```

## 5. JSON response shape for MVP

Ask the provider to return this shape:

```json
{
  "short_summary": "",
  "detailed_summary": "",
  "decisions": [
    {
      "title": "",
      "details": "",
      "source_segment_ids": [],
      "confidence": 0.0
    }
  ],
  "action_items": [
    {
      "task": "",
      "owner": null,
      "due_date": null,
      "source_segment_ids": [],
      "confidence": 0.0
    }
  ],
  "open_questions": [
    {
      "question": "",
      "source_segment_ids": [],
      "confidence": 0.0
    }
  ],
  "risks": [
    {
      "risk": "",
      "details": "",
      "source_segment_ids": [],
      "confidence": 0.0
    }
  ],
  "important_dates": [
    {
      "date": "",
      "meaning": "",
      "source_segment_ids": []
    }
  ],
  "mentioned_people": [],
  "mentioned_systems": [],
  "follow_up_email_draft": ""
}
```

## 6. Prompt assembly notes

When generating meeting analysis:

- Include meeting title if known.
- Include date if known.
- Include glossary if configured.
- Include transcript segments with IDs.
- Prefer chunking long transcripts.
- Ask for JSON only if the provider/model can follow it.
- Preserve raw response when parsing fails.
