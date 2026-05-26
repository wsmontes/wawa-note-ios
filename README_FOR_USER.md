# Claude Code Document Pack — AI Meeting Companion iOS

This package contains the documents Claude Code should use to build the first version of the iPhone app.

## How to use

Copy these files into the root of your iOS project:

```text
CLAUDE.md
docs/
.claude/
```

Then open Claude Code from the project root.

## Recommended first prompt to Claude Code

```text
Read CLAUDE.md, docs/PROJECT_SPEC.md, docs/APPLE_TECH_INVENTORY.md, docs/ARCHITECTURE.md, docs/IMPLEMENTATION_PLAN.md, and docs/TASKS.md.

Do not code yet. Inspect the current project structure and propose the first implementation plan for MVP 1. Then wait for approval.
```

## Recommended second prompt

```text
Implement Phase 0 and Phase 1 from docs/TASKS.md only. Keep the implementation minimal and update docs/TASKS.md and docs/DECISIONS.md when done.
```

## Important

`CLAUDE.md` is intentionally short. The detailed knowledge lives in `docs/`.

The project source of truth is:

- `docs/PROJECT_SPEC.md`
- `docs/APPLE_TECH_INVENTORY.md`
- `docs/ARCHITECTURE.md`
- `docs/IMPLEMENTATION_PLAN.md`
- `docs/TASKS.md`
