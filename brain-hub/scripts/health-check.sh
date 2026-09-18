#!/usr/bin/env bash
# Agent Brain — health check: gitea reachability, vault state, backups size.
set -uo pipefail

ts() { date -u +%FT%TZ; }
GITEA="${GITEA_INTERNAL_URL:-http://gitea:3000}"

echo "== health-check $(ts) =="
echo "  gitea:     $(curl -fsS -o /dev/null -w '%{http_code}' "$GITEA/api/healthz" 2>/dev/null || echo unreachable)"
if [ -d /vault/.git ]; then
  echo "  vault:     $(cd /vault && git rev-parse --short HEAD 2>/dev/null)"
  DIRTY=$(cd /vault && git status --porcelain | wc -l)
  [ "$DIRTY" -gt 0 ] && echo "  dirty:     $DIRTY uncommitted change(s)"
else
  echo "  vault:     not a git repo"
fi
echo "  backups:   $(du -sh /backups 2>/dev/null | cut -f1) ($(find /backups -type f 2>/dev/null | wc -l) files)"