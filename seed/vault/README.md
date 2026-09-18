# Agent Brain — Memory Vault

Welcome. This is a plain-Markdown, Obsidian-compatible vault that acts as the
shared memory for your AI agents and your own notes.

Layout:

| Path | Meaning |
|---|---|
| `memory-logs/` | RAW chat logs, imported notes, execution records (layered: one subfolder per agent) |
| `projects/` | CLEAN, human-verified project notes and specs |
| `skills/` | Reusable, verified workflows |
| `AGENTS.md` | The rules every agent reads first — read it too |

How to use it:

1. Open this folder as a vault in Obsidian (or just edit `.md` files).
2. Log a session: `memory-logs/<agent>/YYYY-MM-DD-<topic>.md`.
3. Promote verified knowledge: `projects/<name>/README.md` or `skills/`.
4. **No manual work required** — the `brain-hub` service commits + pushes this
   vault to Gitea every 15 minutes and backs it up automatically.

Rule zero: no secrets in here.