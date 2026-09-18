# Security model & hardening

Agent Brain ships with defense-in-depth defaults. This file documents the
model, the knobs, and the operational checklist. It is written from the
questions everyone asks when onboarding agents: **"Will I open myself to data
leaks?"** — the honest answer is *only as much as you authorize*.

## The exposure surface, in one picture

```
Your agents (Claude/Gemini/Cursor/OpenCode/...)
          │  MCP over HTTPS
          ▼
Cloudflare Access  ── service-token headers ──►  mcp-bridge (container)
          │ path-locked to /vault                  │
          ▼                                       ▼
   Vault (git)                               ./data/audit (append-only)
```

- The bridge can only ever reach the vault root (`/vault`) — every tool is
  path-restricted; anything that escapes is denied with a permission error.
- What an individual agent can SEE is controlled by scoping (below).
- What an agent DID is recorded in an append-only audit log the agent cannot
  read or write through the bridge.
- The bridge, Gitea, brain-hub, cloudflared all run as containers. The agent
  runtime you install on a PC is **separate**: it has that OS user's access.
  Isolate *that* by running third-party tools containers (section 3).

## 1. Scoped least privilege (per-agent workspaces)

Configure `AGENT_SCOPES` in `.env` — one Cloudflare service token **per
agent**, each mapped to its own workspace inside the vault:

```bash
AGENT_SCOPES='{"<clientId-opencode>":{"roots":["agents/opencode"],"readonly":false,"name":"opencode"},
               "<clientId-reader>":{"roots":["projects/foo"],"readonly":true,"name":"foo-reader"}}'
```

- `roots` are subpaths of the vault; the agent cannot reach outside them.
- `readonly: true` blocks writes for that agent.
- `ENFORCE_SCOPES=true` denies any client id not listed (strict/zero-trust;
  default `false` keeps backward compatibility where an unlisted token sees
  the vault).
- Each agent can call `workspace_info` to confirm exactly what it can touch.

**Recommendation:** create one CF service token per agent in Cloudflare
Zero Trust → Access → Service Auth, put each token only in that agent's MCP
config (`client/mcp-snippets.md`), and enable `ENFORCE_SCOPES=true`.

## 2. Human-in-the-loop & audit trail

- Every authorized tool call appends to `./data/audit/access.jsonl`
  (append-only; backed up by brain-hub). Fields: timestamp, client id,
  event, path.
- `WRITE_APPROVAL=true` changes `write_file`: instead of writing in place,
  the content is staged at `vault/_pending/<agent>/…` and the agent is told
  approval is pending. A human approves by moving the file to its final
  location (in Obsidian, or via git). Agents can still read the staged file
  to iterate before approval.
- There are deliberately **no delete/overwrite-other tools** and no shell/egress
  tools on the bridge.

## 3. Isolated containers for third-party / local tools

Everything in this repo runs containerized. For **third-party MCP servers**
or integration scripts, don't run them with your PC's full user permissions —
wrap them:

```yaml
# sandbox/third-party-mcp.example.yml
# Shared example: run an untrusted MCP tool with a read-only, minimal view.
services:
  auxiliary-mcp:
    image: node:22-slim            # or whatever the tool needs
    command: ["npx", "-y", "<the-tool>"]
    read_only: true
    tmpfs: ["/tmp"]
    user: "1000:1000"
    network_mode: "none"           # no egress unless you configure a proxy/method
    volumes:
      - ./data/obsidian-vault/agents/its-scratch:/work/data:ro   # only its own dir, read-only
```

Rules of thumb:
- Only mount the exact subtree the tool needs (its own agent workspace), read-only.
- `network_mode: none` (or limit to the same compose network) unless the tool
  genuinely must phone home.
- Never inject your PC files, SSH keys, or the `.env` into such containers.
- Prefer running the agent itself in a container/VM on shared machines.

## 4. Audit source code & dependencies

- The MCP bridge pins exact versions (`mcp==2.2.0`, `httpx2==2.13.0`) so a
  rebuild is reproducible. Review `mcp-server/requirements.txt` before upgrade.
- The Gitea image is pinned by `GITEA_VERSION` in `.env` (default `1.27`).
- Before running `setup.sh`, skim these files: `setup.sh`, `.env.example`,
  `docker-compose.yml`, `mcp-server/server.py`, `brain-hub/scripts/*.sh` —
  the whole surface is small and readable.
- The bridge never writes credentials to disk; the only secret inputs are the
  env vars your `.env` already holds. Nothing logs their values.

## Secrets & blast-radius summary

| Item | Where | If it leaks |
|---|---|---|
| CF service token (per agent) | agent's MCP config + CF dashboard | only that agent's workspace |
| CF service token (shared, legacy) | clients (or CF) | full vault (migrate to per-agent) |
| Gitea API token | `.env` (600) | vault & mirrors |
| Gitea admin password | `.env` (600) | full Gitea control |
| GitHub PAT (`GH_TOKEN`, optional) | `.env` (600) | GitHub account scope |

The `.env` never enters git (`.gitignore`), and the seed vault ships with zero
of your real content.

## Quick hardening checklist

- [ ] One CF service token per agent + `AGENT_SCOPES` mapping → `ENFORCE_SCOPES=true`
- [ ] `WRITE_APPROVAL=true` for anything you want human-reviewed
- [ ] Third-party MCP tools run in `read_only` containers on their own subtree
- [ ] `docker compose logs mcp-bridge` shows no unexpected callers; review `./data/audit/access.jsonl`
- [ ] Keep `GITEA_VERSION` pinned; install deps only from pinned files
- [ ] Do not expose the MCP port publicly while `MCP_ALLOW_NO_AUTH=true`