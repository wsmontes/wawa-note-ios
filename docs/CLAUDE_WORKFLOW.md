# Claude Code Workflow

## 1. First session workflow

Use this prompt:

```text
Read CLAUDE.md and the documents in docs/. Do not code yet.
Inspect the current Xcode project structure.
Summarize what exists, what is missing, and propose the first 3 implementation steps for MVP 1.
```

## 2. Implementation workflow

For each task:

1. Read `docs/TASKS.md`.
2. Pick the next unchecked task in the current phase.
3. Inspect existing code.
4. Propose the minimal implementation.
5. Implement.
6. Build/test.
7. Update `docs/TASKS.md`.
8. Update `docs/DECISIONS.md` if architectural decisions changed.

## 3. Avoid huge changes

Do not ask Claude Code to implement the whole app in one run.

Good:

```text
Implement Phase 1 from docs/TASKS.md only.
```

Bad:

```text
Build the entire meeting AI app.
```

## 4. Planning prompt

```text
Use plan mode. Based on docs/TASKS.md, propose a minimal implementation plan for the next unchecked task. Do not edit files yet.
```

## 5. Build/debug prompt

```text
Run the iOS build. Fix only the compile errors caused by the current change. Do not refactor unrelated files.
```

## 6. Documentation update prompt

```text
Update docs/TASKS.md and docs/DECISIONS.md based on what was completed. Keep it concise.
```

## 7. Review prompt

```text
Review the current implementation against CLAUDE.md, docs/ARCHITECTURE.md, and docs/CODING_STANDARDS.md. Identify architectural violations and propose fixes. Do not change code yet.
```

## 8. End-of-session prompt

```text
Summarize what changed, what remains broken, what should be done next, and update docs/TASKS.md if needed.
```
