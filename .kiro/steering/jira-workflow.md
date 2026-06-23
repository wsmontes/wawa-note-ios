---
inclusion: always
---

# JIRA Integration

This project is tracked in Atlassian JIRA (project key: **KAN**, site: wawasoftbc.atlassian.net).

## CLI Tool

Use `scripts/jira-cli.py` for all JIRA operations. Reads credentials from `.env` (see `.env.example`).

```bash
python scripts/jira-cli.py show KAN-XX --comments --links   # Read issue + AC
python scripts/jira-cli.py move KAN-XX "In Progress"        # Start work
python scripts/jira-cli.py comment KAN-XX "progress note"   # Update
python scripts/jira-cli.py move KAN-XX Done                 # Complete
python scripts/jira-cli.py create "Summary" -t Bug -p KAN   # New issue
python scripts/jira-cli.py search --labels "sprint:1"       # Find work
python scripts/jira-cli.py link KAN-XX KAN-YY               # Connect issues
```

## Mandatory workflow

1. **Every code change must reference a JIRA issue.** Branch: `KAN-XX/description`. Commit: `KAN-XX: what`.
2. **Before starting**, read the issue for acceptance criteria and linked docs.
3. **After completing**, transition to Done and comment with what was delivered.
4. **New scope = new issue.** Never silently expand scope — create a JIRA issue.
5. **Source files have `// Related JIRA:` comments.** Keep them accurate.

## Priority order

1. `sprint:1` issues (current sprint)
2. `P0` / Highest priority (critical bugs)
3. `P1` / High priority (broken flows)
4. Issues that unblock others (check Blocks links)

## Code review workflow

When the user reviews an already-completed issue:
1. Issue moves from Done → **In Review**
2. User comments with findings (or asks AI to investigate)
3. If approved: move back to **Done** with "Review passed" comment
4. If changes needed: move to **In Progress**, fix, then back through the flow

Use the same issue — don't create separate review tickets.
