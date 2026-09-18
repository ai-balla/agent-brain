"""Agent Brain — MCP Filesystem Bridge.

Exposes read/write/list tools over streamable-http on 127.0.0.1:<port> (the
compose file maps it to the host loopback) for remote AI agents. The vault is
mounted at VAULT_ROOT and all tools are path-restricted to it.

Auth model (defense in depth):
  * Cloudflare Access normally sits in front (mcp.yourdomain.com -> CF Access
    -> the bridge). The bridge re-validates the CF service-token headers.
  * If CF_ACCESS_CLIENT_ID / CF_ACCESS_CLIENT_SECRET are set, every tool call
    must present the matching CF-Access-Client-Id / CF-Access-Client-Secret.
  * If they are empty AND MCP_ALLOW_NO_AUTH=true, the bridge runs without auth
    (intended for purely localhost vaults) and prints a loud warning.

Config via environment:
  VAULT_ROOT          absolute vault path inside the container (default /vault)
  CF_ACCESS_CLIENT_ID / CF_ACCESS_CLIENT_SECRET   Cloudflare service token
  MCP_ALLOW_NO_AUTH   true | false
  ALLOWED_HOSTS       comma-separated list of Host headers permitted to hit
                      the server (used by transport security)
"""

from __future__ import annotations

import argparse
import fnmatch
import os
from contextlib import suppress
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
ALLOWED_HOSTS = [
    h.strip()
    for h in os.environ.get("ALLOWED_HOSTS", "").split(",")
    if h.strip()
]

if not CF_ID or not CF_SECRET:
    if ALLOW_NO_AUTH:
        print("WARNING: no Cloudflare credentials set and MCP_ALLOW_NO_AUTH=true.")
        print("WARNING: the bridge will accept ANY caller. Do not expose it publicly.")
    else:
        raise SystemExit(
            "ERROR: CF_ACCESS_CLIENT_ID and CF_ACCESS_CLIENT_SECRET must be set, "
            "or set MCP_ALLOW_NO_AUTH=true for a localhost-only vault."
        )

# Explicit no-auth is the only situation where we deliberately drop enforcement.
NO_AUTH = ALLOW_NO_AUTH and not (CF_ID or CF_SECRET)

server = FastMCP(
    "agent-brain-vault",
    instructions=(
        "File access to the Agent Brain vault. The root is "
        f"{VAULT_ROOT}. read_file and write_file use UTF-8 text."
    ),
)


def _authorized(ctx: MCPContext) -> bool:
    if NO_AUTH:
        return True
    headers = ctx.headers or {}
    return bool(
        CF_SECRET
        and headers.get("CF-Access-Client-Secret") == CF_SECRET
        and headers.get("CF-Access-Client-Id") == CF_ID
    )


def _resolve(ctx: MCPContext, raw_path: str, writable: bool = False) -> Path:
    if not _authorized(ctx):
        raise PermissionError("Unauthorized: valid CF Access service-token headers required.")
    p = Path(raw_path).expanduser()
    if not p.is_absolute():
        p = VAULT_ROOT / p
    p = p.resolve()
    if p != VAULT_ROOT and VAULT_ROOT not in p.parents:
        raise PermissionError(f"Path escapes the vault root {VAULT_ROOT}.")
    if writable:
        p.parent.mkdir(parents=True, exist_ok=True)
    return p


@server.tool()
def read_file(ctx: MCPContext, path: str) -> str:
    """Read a UTF-8 text file inside the vault."""
    p = _resolve(ctx, path)
    if not p.is_file():
        raise FileNotFoundError(path)
    return p.read_text(encoding="utf-8")


@server.tool()
def write_file(ctx: MCPContext, path: str, content: str) -> str:
    """Create or overwrite a UTF-8 text file inside the vault."""
    p = _resolve(ctx, path, writable=True)
    p.write_text(content, encoding="utf-8")
    return f"Wrote {len(content)} chars -> {p}"


@server.tool()
def list_directory(ctx: MCPContext, path: str = ".") -> list[dict[str, Any]]:
    """List one level inside the vault, returning names and kinds."""
    p = _resolve(ctx, path)
    if not p.is_dir():
        raise NotADirectoryError(path)
    return sorted(
        [
            {"name": e.name, "type": "dir" if e.is_dir() else "file"}
            for e in p.iterdir()
            if not (e.is_dir() and e.name == ".git")
        ],
        key=lambda d: (d["type"], d["name"]),
    )


@server.tool()
def create_directory(ctx: MCPContext, path: str) -> str:
    """Create a directory (and parents) inside the vault."""
    p = _resolve(ctx, path, writable=True)
    p.mkdir(parents=True, exist_ok=True)
    return f"Ensured directory {p}"


@server.tool()
def search_files(ctx: MCPContext, pattern: str, path: str = ".") -> list[str]:
    """Glob the vault using a pattern (e.g. 'memory-logs/*.md')."""
    p = _resolve(ctx, path)
    if not p.is_dir():
        raise NotADirectoryError(path)
    hits: list[str] = []
    for root, dirs, files in os.walk(p):
        dirs[:] = [d for d in dirs if not d.startswith(".git")]
        for name in files:
            full = Path(root) / name
            rel = str(full.relative_to(VAULT_ROOT))
            if fnmatch.fnmatch(full.name, pattern) or fnmatch.fnmatch(rel, pattern):
                hits.append(rel)
    return sorted(hits)


@server.tool()
def vault_info(ctx: MCPContext) -> dict[str, Any]:
    """Return the vault root, absolute path, and a short inventory."""
    if not _authorized(ctx):
        raise PermissionError("Unauthorized: valid CF Access service-token headers required.")
    counts = {"projects": 0, "skills": 0, "memory-logs": 0}
    for key in counts:
        counts[key] = sum(1 for _ in (VAULT_ROOT / key).glob("*.md")) if (VAULT_ROOT / key).is_dir() else 0
    return {"root": str(VAULT_ROOT), "locked_to_vault": True, "markdown_notes": counts}


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