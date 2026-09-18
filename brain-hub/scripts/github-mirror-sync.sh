#!/usr/bin/env bash
# Agent Brain — GitHub -> Gitea mirror sync.
#
# For every public/private repo of the account in GH_TOKEN:
#   1. ensures a Gitea repo exists (created empty via API),
#   2. keeps a local bare mirror in /mirrors (clone / fetch --all),
#   3. pushes the full ref tree into Gitea (push --mirror over HTTP + token).
#
# DELETION SAFETY: this script NEVER deletes anything.
#   - A repo deleted on GitHub keeps its local mirror and its Gitea repo; the
#     script only stops updating it and prints a "preserved" line.
#   - Branches/tags removed on GitHub are NOT pruned (no --prune), so the
#     mirror push re-creates them in Gitea and they survive.
#
# Skipped entirely when GH_TOKEN is empty (mirroring is opt-in).
set -euo pipefail

ts() { date -u +%FT%TZ; }

if [ -z "${GH_TOKEN:-}" ]; then
  echo "$(ts) GH_TOKEN empty — mirror sync skipped"
  exit 0
fi

GITEA="${GITEA_INTERNAL_URL:-http://gitea:3000}"
GITEA_HOST="${GITEA_INTERNAL_URL#*://}"
OWNER="${GITEA_OWNER:-ai-agent}"
GITEA_AUTH="${OWNER}:${GITEA_TOKEN}"
ROOT_BASE="/mirrors"
mkdir -p "$ROOT_BASE"

GH_API="https://api.github.com"
GH_OWNER="$(curl -fsS -H "Authorization: token $GH_TOKEN" "$GH_API/user" | jq -r .login)"
# GitHub basic-auth header, computed per run — never written to disk.
GH_BASIC="$(printf '%s:%s' "$GH_OWNER" "$GH_TOKEN" | base64 -w0)"

echo "== GitHub -> Gitea mirror sync ($(ts)) =="
echo "   owner: $GH_OWNER | mirrors: $ROOT_BASE"

created=0; updated=0; skipped=0; failed=0

curl -fsS -H "Authorization: token $GH_TOKEN" \
     -H "Accept: application/vnd.github+json" \
     "$GH_API/user/repos?per_page=100&sort=full_name" \
  | jq -r '.[] | [.private, .full_name, .clone_url] | @tsv' \
  > /tmp/gh-repos.tsv

while IFS=$'\t' read -r PRIVATE FULL CLONEURL; do
  NAME=${FULL#*/}
  PRIV=$([ "$PRIVATE" = "true" ] && echo true || echo false)

  # 1) Ensure Gitea repo exists (409 = already there).
  CODE=$(curl -s -o /dev/null -w '%{http_code}' \
         -H "Authorization: token $GITEA_TOKEN" \
         -H "Content-Type: application/json" \
         -X POST "$GITEA/api/v1/user/repos" \
         -d "{\"name\": \"$NAME\", \"private\": $PRIV, \"auto_init\": false}")
  case "$CODE" in
    201|200) echo "  [gitea:new] $FULL"; created=$((created+1)) ;;
    409)     echo "  [gitea:has] $FULL"; skipped=$((skipped+1)) ;;
    *)       echo "  [gitea:FAIL $CODE] $FULL"; failed=$((failed+1)); continue ;;
  esac

  MIRROR_DIR="$ROOT_BASE/$NAME.git"
  SRC="$CLONEURL"  # tokenless canonical URL — no creds embedded
  DST="http://${GITEA_AUTH}@${GITEA_HOST%/}/${OWNER}/$NAME.git"

  # 2) Local bare mirror.
  if [ ! -d "$MIRROR_DIR" ]; then
    if git -c http.extraHeader="Authorization: Basic $GH_BASIC" clone --quiet --mirror "$SRC" "$MIRROR_DIR"; then
      git -C "$MIRROR_DIR" remote set-url origin "$SRC"
      echo "  [clone] $FULL"
    else
      echo "  [clone FAIL] $FULL"; failed=$((failed+1)); continue
    fi
  else
    if git -C "$MIRROR_DIR" -c http.extraHeader="Authorization: Basic $GH_BASIC" fetch --all --quiet; then
      echo "  [fetch] $FULL"
    else
      echo "  [fetch FAIL] $FULL"; failed=$((failed+1)); continue
    fi
  fi

  # 3) Push into Gitea.
  if git -C "$MIRROR_DIR" push --quiet --mirror "$DST"; then
    updated=$((updated+1))
  else
    echo "  [push FAIL] $FULL"; failed=$((failed+1))
  fi
done < /tmp/gh-repos.tsv

# Preservation report: mirrors not on GitHub anymore are kept on purpose.
for d in "$ROOT_BASE"/*.git; do
  [ -d "$d" ] || continue
  name=$(basename "$d" .git)
  if ! grep -qP "\t${GH_OWNER}/${name}\t" /tmp/gh-repos.tsv 2>/dev/null; then
    echo "  [preserved] $name (no longer on GitHub — kept locally)"
  fi
done

echo "== finished: $updated mirrored ($created gitea-created, $skipped skipped, $failed failed) =="
[ "$failed" -gt 0 ] && exit 1 || exit 0