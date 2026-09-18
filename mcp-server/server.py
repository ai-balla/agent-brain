"""Agent Brain — MCP Filesystem Bridge.

Exposes read/write/list tools over streamable-http on 127.0.0.1:<port> (the
compose file maps it to the host loopback) for remote AI agents. The vault is
mounted at VAULT_ROOT and every tool is path-restricted to it.

SECURITY MODEL (defense in depth, per scope)
============================================
* Cloudflare Access normally sits in front (mcp.<domain>/mcp -> CF Access ->
  the bridge). The bridge re-validates the CF service-token headers.
* Per-agent least privilege: if AGENT_SCOPES is set, each CF_ACCESS_CLIENT_ID
  is mapped to one or more workspace subpaths (relative to the vault) and an
  optional read-only flag. Agents can only reach their own workspace.
* ENFORCE_SCOPES=true denies any client that is not listed in AGENT_SCOPES
  (recommended for production). When false, unlisted clients fall back to the
  full vault (backward compatibility).
* Every authorized tool call is appended to an audit log OUTSIDE the vault
  (AUDIT_LOG_PATH), which agents cannot read or write through this bridge.
* WRITE_APPROVAL=true stages write_file calls under vault/_pending/<agent>/…
  instead of writing in place — a human approves by moving the file to its
  final location (in Obsidian or git). read_file can still preview the staged
  file, so agents can iterate before approval.
* If CF_ACCESS_CLIENT_ID / CF_ACCESS_CLIENT_SECRET are unset AND
  MCP_ALLOW_NO_AUTH=true, the bridge runs unauthenticated for localhost-only
  vaults (prints a loud warning; no scoping applies in that local mode).
* If CF credentials are unset and MCP_ALLOW_NO_AUTH is false, startup fails.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import json
import os
from pathlib import Path
from typing import Any

try:
    # MCP 1.x name
    from mcp.server.fastmcp import FastMCP  # type: ignore[import-not-found]
except ModuleNotFoundError:
    # MCP 2.x+ renamed FastMCP -> MCPServer
    from mcp.server.mcpserver import MCPServer as FastMCP

from mcp.server.mcpserver.context import Context as MCPContext

VAULT_ROOT = Path(os.environ.get("VAULT_ROOT", "/vault")).resolve()
CF_ID = os.environ.get("CF_ACCESS_CLIENT_ID", "")
CF_SECRET = os.environ.get("CF_ACCESS_CLIENT_SECRET", "")
ALLOW_NO_AUTH = os.environ.get("MCP_ALLOW_NO_AUTH", "false").lower() == "true"
ENFORCE_SCOPES = os.environ.get("ENFORCE_SCOPES", "false").lower() == "true"
WRITE_APPROVAL = os.environ.get("WRITE_APPROVAL", "false").lower() == "true"
AUDIT_LOG = (
    Path(os.environ["AUDIT_LOG_PATH"]).expanduser()
    if os.environ.get("AUDIT_LOG_PATH")
    else None
)
ALLOWED_HOSTS = [
    h.strip() for h in os.environ.get("ALLOWED_HOSTS", "").split(",") if h.strip()
]

_SCOPES_RAW = os.environ.get("AGENT_SCOPES", "").strip()
AGENT_SCOPES: dict[str, dict[str, Any]] = {}
if _SCOPES_RAW:
    try:
        parsed = json.loads(_SCOPES_RAW)
        if not isinstance(parsed, dict):
            raise ValueError("must be a JSON object")
        for cid, cfg in parsed.items():
            roots = cfg.get("roots", []) if isinstance(cfg, dict) else []
            AGENT_SCOPES[cid] = {
                "roots": [str(r).strip("/") for r in roots],
                "readonly": bool(cfg.get("readonly", False)) if isinstance(cfg, dict) else False,
                "slug": (cfg.get("name") or f"agent-{cid[:8]}").strip() if isinstance(cfg, dict) else f"agent-{cid[:8]}",
            }
    except (json.JSONDecodeError, ValueError) as exc:
        raise SystemExit(f"ERROR: AGENT_SCOPES is not valid JSON: {exc}") from exc

if not CF_ID or not CF_SECRET:
    if ALLOW_NO_AUTH:
        print("WARNING: no Cloudflare credentials set and MCP_ALLOW_NO_AUTH=true.")
        print("WARNING: the bridge will accept ANY caller. Do not expose it publicly.")
        print("WARNING: scoping and audit are DISABLED in this local mode.")
    else:
        raise SystemExit(
            "ERROR: CF_ACCESS_CLIENT_ID and CF_ACCESS_CLIENT_SECRET must be set, "
            "or set MCP_ALLOW_NO_AUTH=true for a localhost-only vault."
        )

# Explicit no-auth is the only situation where auth enforcement is dropped.
LOCAL_ONLY = ALLOW_NO_AUTH and not (CF_ID or CF_SECRET)

if ENFORCE_SCOPES and not AGENT_SCOPES:
    print("WARNING: ENFORCE_SCOPES=true but AGENT_SCOPES is empty -> every client is denied.")

server = FastMCP(
    "agent-brain-vault",
    instructions=(
        "File access to the Agent Brain vault. The root is "
        f"{VAULT_ROOT}. read_file and write_file use UTF-8 text. "
        "Use workspace_info to see which workspace you are allowed to touch."
    ),
)


def _audit(**fields: Any) -> None:
    if not AUDIT_LOG:
        return
    try:
        AUDIT_LOG.parent.mkdir(parents=True, exist_ok=True)
        row = {"ts": dt.datetime.now(dt.timezone.utc).isoformat(), **fields}
        with open(AUDIT_LOG, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")
    except OSError:
        pass  # audit must never break a tool call


def _header(headers: Any, name: str) -> str | None:
    """Case-insensitive header lookup (Starlette lowercases incoming names)."""
    out = None
    for key, value in (headers or {}).items():
        if str(key).lower() == name.lower():
            out = value
            break
    if out is None and hasattr(headers, "get"):
        out = headers.get(name)
    return out


def _identity(ctx: MCPContext) -> str | None:
    """Return the authenticated client id, or None if not authorized."""
    if LOCAL_ONLY:
        return "local"
    headers = ctx.headers or {}
    if (
        CF_SECRET
        and _header(headers, "CF-Access-Client-Secret") == CF_SECRET
        and _header(headers, "CF-Access-Client-Id") == CF_ID
    ):
        return CF_ID
    return None


def _scope(identity: str) -> dict[str, Any] | None:
    """Return the agent's scope dict, or None for vault-wide access."""
    if identity == "local":
        return None
    scope = AGENT_SCOPES.get(identity)
    if scope is None and ENFORCE_SCOPES:
        raise PermissionError("Unauthorized: this client has no assigned workspace (ENFORCE_SCOPES=true).")
    return scope


def _base(scope: dict[str, Any] | None, writable: bool) -> Path:
    if scope is None:
        return VAULT_ROOT
    if scope.get("readonly") and writable:
        raise PermissionError("Unauthorized: this workspace is read-only.")
    root = scope["roots"][0]
    base = (VAULT_ROOT / root).resolve()
    if base != VAULT_ROOT and VAULT_ROOT not in base.parents:
        raise PermissionError(f"Workspace root escapes vault: {root}")
    return base


def _resolve(ctx: MCPContext, raw_path: str, writable: bool = False) -> tuple[Path, dict[str, Any] | None]:
    identity = _identity(ctx)
    if identity is None:
        raise PermissionError("Unauthorized: valid CF Access service-token headers required.")
    scope = _scope(identity)
    base = _base(scope, writable)
    p = Path(raw_path).expanduser()
    if not p.is_absolute():
        p = base / p
    p = p.resolve()
    if p != VAULT_ROOT and VAULT_ROOT not in p.parents:
        raise PermissionError(f"Path escapes the vault root {VAULT_ROOT}.")
    if scope is not None and p != base and base not in p.parents:
        raise PermissionError(f"Path escapes your workspace {base}.")
    if writable:
        p.parent.mkdir(parents=True, exist_ok=True)
    return p, scope


def _staged(ctx: MCPContext, final: Path) -> Path:
    """Compute the human-approval staging path for a write."""
    identity = _identity(ctx)
    slug = AGENT_SCOPES.get(identity or "", {}).get("slug", f"agent-{(identity or 'local')[:8]}")
    rel = final.relative_to(VAULT_ROOT)
    staged = VAULT_ROOT / "_pending" / slug / rel
    return staged


@server.tool()
def workspace_info(ctx: MCPContext) -> dict[str, Any]:
    """Return which workspace + permissions this caller has."""
    identity = _identity(ctx)
    if identity is None:
        raise PermissionError("Unauthorized: valid CF Access service-token headers required.")
    try:
        scope = _scope(identity)
    except PermissionError as exc:
        raise PermissionError(str(exc)) from exc
    return {
        "identity": identity,
        "workspace": None if scope is None else scope["roots"],
        "readonly": bool(scope and scope.get("readonly")),
        "write_approval": WRITE_APPROVAL,
        "vault_root": str(VAULT_ROOT),
    }


@server.tool()
def read_file(ctx: MCPContext, path: str) -> str:
    """Read a UTF-8 text file inside the vault (or your workspace)."""
    p, _scope_ = _resolve(ctx, path)
    if not p.is_file():
        raise FileNotFoundError(path)
    _audit(event="read", client=_identity(ctx), path=str(p.relative_to(VAULT_ROOT)), ok=True)
    return p.read_text(encoding="utf-8")


@server.tool()
def write_file(ctx: MCPContext, path: str, content: str) -> str:
    """Create or overwrite a UTF-8 text file (staged for approval if enabled)."""
    identity = _identity(ctx)
    if identity is None:
        raise PermissionError("Unauthorized: valid CF Access service-token headers required.")
    p, scope = _resolve(ctx, path, writable=not WRITE_APPROVAL)
    if WRITE_APPROVAL:
        staged = _staged(ctx, p)
        staged_abs = _make_absolute_in_vault(staged)
        staged_abs.parent.mkdir(parents=True, exist_ok=True)
        staged_abs.write_text(content, encoding="utf-8")
        _audit(event="write_staged", client=identity, path=str(p.relative_to(VAULT_ROOT)), ok=True)
        return f"Staged for human approval -> {staged_abs} (final location {p}). read_file(path) can preview it."
    p.write_text(content, encoding="utf-8")
    _audit(event="write", client=identity, path=str(p.relative_to(VAULT_ROOT)), ok=True)
    return f"Wrote {len(content)} chars -> {p}"


def _make_absolute_in_vault(path: Path) -> Path:
    resolved = path.resolve()
    if resolved != VAULT_ROOT and VAULT_ROOT not in resolved.parents:
        raise PermissionError(f"Path escapes the vault root {VAULT_ROOT}.")
    return resolved


@server.tool()
def list_directory(ctx: MCPContext, path: str = ".") -> list[dict[str, Any]]:
    """List one level inside the vault (or your workspace), names and kinds."""
    p, _scope_ = _resolve(ctx, path)
    if not p.is_dir():
        raise NotADirectoryError(path)
    _audit(event="list", client=_identity(ctx), path=str(p.relative_to(VAULT_ROOT)), ok=True)
    return sorted(
        [
            {"name": e.name, "type": "dir" if e.is_dir() else "file"}
            for e in p.iterdir()
            if not (e.is_dir() and e.name in {".git", "_pending"})
        ],
        key=lambda d: (d["type"], d["name"]),
    )


@server.tool()
def create_directory(ctx: MCPContext, path: str) -> str:
    """Create a directory (and parents) inside the vault / workspace."""
    identity = _identity(ctx)
    if identity is None:
        raise PermissionError("Unauthorized: valid CF Access service-token headers required.")
    p, _scope_ = _resolve(ctx, path, writable=True)
    p.mkdir(parents=True, exist_ok=True)
    _audit(event="mkdir", client=identity, path=str(p.relative_to(VAULT_ROOT)), ok=True)
    return f"Ensured directory {p}"


@server.tool()
def search_files(ctx: MCPContext, pattern: str, path: str = ".") -> list[str]:
    """Glob the vault using a pattern (e.g. 'memory-logs/*.md')."""
    p, scope = _resolve(ctx, path)
    if not p.is_dir():
        raise NotADirectoryError(path)
    base = _base(scope, writable=False)
    hits: list[str] = []
    for root, dirs, files in os.walk(p):
        dirs[:] = [d for d in dirs if not d.startswith(".git") and d != "_pending"]
        for name in files:
            full_path = Path(root) / name
            rel = str(full_path.relative_to(base))
            if fnmatch.fnmatch(full_path.name, pattern) or fnmatch.fnmatch(rel, pattern):
                hits.append(rel)
    _audit(event="search", client=_identity(ctx), path=str(p.relative_to(VAULT_ROOT)), ok=True)
    return sorted(hits)


@server.tool()
def vault_info(ctx: MCPContext) -> dict[str, Any]:
    """Return inventory counts for the current scope (never the whole vault for scoped agents)."""
    identity = _identity(ctx)
    if identity is None:
        raise PermissionError("Unauthorized: valid CF Access service-token headers required.")
    scope = _scope(identity)
    base = _base(scope, writable=False)
    counts: dict[str, int] = {}
    for key in ("memory-logs", "projects", "skills"):
        target = base / key
        counts[key] = sum(1 for _ in target.glob("*.md")) if target.is_dir() else 0
    _audit(event="info", client=identity, path=str(base.relative_to(VAULT_ROOT)), ok=True)
    return {
        "identity": identity,
        "workspace": None if scope is None else scope["roots"],
        "readonly": bool(scope and scope.get("readonly")),
        "inventory": counts,
        "locked_to_scope": scope is not None,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8083)
    parser.add_argument("--path", default="/mcp")
    args = parser.parse_args()

    hosts = list(ALLOWED_HOSTS)
    for extra in ("127.0.0.1", "127.0.0.1:*", "localhost", "localhost:*"):
        if extra not in hosts:
            hosts.append(extra)

    from mcp.server.transport_security import TransportSecuritySettings

    server.run(
        transport="streamable-http",
        host=args.host,
        port=args.port,
        streamable_http_path=args.path,
        stateless_http=True,
        transport_security=TransportSecuritySettings(
            enabled=True,
            allowed_hosts=hosts,
        ),
    )


if __name__ == "__main__":
    main()