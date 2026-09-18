#!/usr/bin/env bash
# Agent Brain — auto-sync: commit local vault changes and push to Gitea.
# No-ops when nothing changed. Safe to run repeatedly.
set -euo pipefail

VAULT="${VAULT_PATH:-/vault}"
ts() { date -u +%FT%TZ; }

cd "$VAULT"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "$(ts) vault is not a git repo ($VAULT); ignoring"
  exit 0
fi

git add -A 2>/dev/null || true
if git diff --cached --quiet; then
  echo "$(ts) nothing to commit"
  exit 0
fi

git -c user.name="${GIT_USER_NAME:-ai-agent}" \
    -c user.email="${GIT_USER_EMAIL:-ai-agent@localhost}" \
    commit -m "agent-brain auto-sync $(ts)" >/dev/null
echo "$(ts) committed"

# Push only when we know where to push and have a token.
if [ -n "${GITEA_TOKEN:-}" ] && [ -n "${GITEA_INTERNAL_URL:-}" ]; then
  HOST="${GITEA_INTERNAL_URL#*://}"
  DST="http://${GITEA_OWNER:-ai-agent}:${GITEA_TOKEN}@${HOST%/}/${GITEA_OWNER:-ai-agent}/memory-vault.git"
  if git push "$DST" HEAD:main >/dev/null 2>&1; then
    echo "$(ts) pushed to Gitea"
  else
    echo "$(ts) push deferred (Gitea/network unavailable; will retry)"
  fi
else
  echo "$(ts) no GITEA_TOKEN/URL configured; committed locally only"
fi