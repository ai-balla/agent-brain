# Agent Rules (AGENTS.md)

This vault is the **single source of truth** for every agent that connects to
this hub (opencode, Claude Code, Gemini, Kimi, IDE extensions) and for the
human owner (Obsidian). Read this file first, always.

## THREE LAYER STRUCTURE

Raw chats are cleanly separated from curated knowledge:

```
vault/
├── memory-logs/        # LAYER 1 — RAW CHATS & AUDIT TRAIL
│   ├── opencode/       #     one subfolder per agent/platform
│   ├── chatgpt/
│   ├── claude/
│   ├── gemini/
│   ├── kimi/
│   └── keep/           #     imported notes (raw)
├── projects/           # CLEAN PROJECT NOTES & SPECS (verified)
│   └── <project>/      #     one folder per project, own README + specs
└── skills/             # REUSABLE AGENT WORKFLOWS (verified)
```

- `memory-logs/` = raw conversation exports, execution logs, imported notes,
  decisions as they happened. **Historical reference only.**
- `projects/` = definitive, human-verified documentation, architecture, goals.
- `skills/` = repeatable, maintainable agent workflows.

## YAML FRONTMATTER (LAYER 2 — THE SCHEMA)

Every note carries YAML so humans (Dataview) and agents (MCP/grep) can filter.

Raw chat/audit file:
```yaml
---
type: raw-chat
platform: opencode | claude | gemini | kimi | chatgpt
date: YYYY-MM-DD
participants: [user, <agent>]
status: archive          # raw logs stay archive; move knowledge out when verified
tags: [type/log, source/<platform>]
---
```

Imported note:
```yaml
---
type: note
platform: keep
date: YYYY-MM-DD
participants: [user]
status: active | archived
tags: [type/note, source/keep, keep/<label>]
---
```

Verified project/spec file:
```yaml
---
type: project-spec
status: active
created: YYYY-MM-DD
last_updated: YYYY-MM-DD
verified_by: human
tags: [type/spec, project/<project-name>]
---
```

Skills file:
```yaml
---
type: skill
status: active
created: YYYY-MM-DD
last_updated: YYYY-MM-DD
verified_by: human
tags: [type/skill, skill/<skill-name>]
---
```

## NESTED TAG TAXONOMY (LAYER 3)

Hierarchical tags group content in Obsidian's tag tree without moving files:

| Domain | Tags |
|---|---|
| Chats | `#chat/opencode`, `#chat/claude`, `#chat/gemini`, `#chat/kimi`, `#chat/raw` |
| Knowledge | `#knowledge/verified`, `#knowledge/draft` |
| Specs | `#spec/architecture`, `#spec/api` |
| Workflows | `#guides/mcp`, `#guides/sync` |
| Projects | `#project/<name>` |

(Use these in addition to the frontmatter `tags:` block, not instead of it.)

## GROUND RULES

1. Obsidian-compatible plain Markdown only. Every vault file is `.md`.
2. Never store secrets in the vault. Secrets belong in the product `.env`
   (permissions 600) — the vault is a git repo and must stay clean.
3. If in doubt, prefer a short dated `memory-log` over editorializing.
4. Default branch is `main`. The vault repo is `memory-vault` in Gitea.
5. Commits and pushes are handled by the brain-hub auto-sync service (every
   15 minutes) — you do not need to run git manually after a write, but doing
   so is safe: `git add -A && git commit -m "..." && git push`.

## CONNECTION (MCP)

- Tools `read_file`, `write_file`, `list_directory`, `create_directory`,
  `search_files`, `vault_info` are exposed over streamable-http (JSON-RPC) at
  `https://<your-mcp-host>/mcp`.
- Clients authenticate with `CF-Access-Client-Id` / `CF-Access-Client-Secret`
  headers (Cloudflare service token). See `client/mcp-snippets.md` in the
  product repo.
- The bridge enforces: vault paths only.

## READING ORDER FOR AGENTS

1. ALWAYS search `projects/` and `skills/` first for authoritative rules,
   specs, and conventions — that is the verified layer.
2. TREAT `memory-logs/` as historical fact (what happened, when, why) — never
   as the final rule. If memory-logs contradict `projects/`, `projects/` wins.
3. WHEN writing specs, architecture, or project rules, put them in
   `projects/<name>/` with `type: project-spec` + `verified_by: human`.
4. When logging a session/event, put it in `memory-logs/<agent>/` as
   `YYYY-MM-DD-<topic>.md` with `type: raw-chat`.
5. After ANY write, allow the auto-sync to commit and push (or run the git
   commands in rule 5 above yourself).