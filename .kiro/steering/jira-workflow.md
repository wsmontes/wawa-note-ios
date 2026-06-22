---
inclusion: always
---

# JIRA Integration

This project is tracked in Atlassian JIRA (project key: **KAN**, site: wawasoftbc.atlassian.net).

## Mandatory workflow

1. **Every code change must reference a JIRA issue.** Branch names: `KAN-XX/description`. Commit messages: `KAN-XX: what changed`.
2. **Before starting work**, check the issue for acceptance criteria, related issues, and Confluence doc links.
3. **After completing work**, transition the issue to Done and comment with what was delivered.
4. **New scope = new issue.** Never silently expand scope. If you discover additional work, create a JIRA issue for it.
5. **Every Swift file has `// Related JIRA:` comments.** Keep them accurate. Add keys when files gain new responsibilities.

## JIRA client

A Python client exists at the workspace level: `C:\workspace\_archive\wawasoft_jira_client.py`

```python
from wawasoft_jira_client import JiraClient
c = JiraClient()
c.jira("show KAN-73 --comments --links")
c.jira("move KAN-73 \"In Progress\"")
c.jira("comment KAN-73 'Fixed: AudioChunker now outputs PCM WAV'")
c.jira("move KAN-73 Done")
c.jira("create KAN 'New issue title' --type Bug --priority High")
```

## Priority order

When choosing what to work on, prefer issues labeled:
1. `sprint:1` (current sprint)
2. `P0` or priority=Highest (critical bugs)
3. `P1` (high-impact improvements)
4. Issues that unblock other issues (check "Blocks" links)

## Confluence

Architecture docs are linked from JIRA issues via remote links. When making architecture decisions, update the relevant Confluence page AND `docs/DECISIONS.md`.
