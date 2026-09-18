#!/usr/bin/env bash
# Agent Brain — one-shot installer.
#
#   curl -fsSL https://<raw-host>/agent-brain/agent-brain/setup.sh | bash
#   (or the safer: curl -o setup.sh ... && bash setup.sh)
#
# Does, safely and idempotently:
#   1. creates .env from defaults (only prompts if .env does not exist),
#   2. builds & starts the stack (gitea + mcp-bridge + brain-hub),
#   3. seeds the memory vault (3-layer structure + AGENTS.md) as a git repo,
#   4. creates the Gitea `memory-vault` repo + an API token and pushes the vault,
#   5. prints a hand-off sheet: endpoints, tokens to keep safe, client snippets.
#
# Requirements: docker + docker compose plugin. Run as your normal user
# (the one that owns ./data). Never run with sudo unless you know the caveats.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

DEFAULT_UID="$(id -u 2>/dev/null || echo 1000)"
DEFAULT_GID="$(id -g 2>/dev/null || echo 1000)"

log()  { printf '\n\033[1;32m== %s ==\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker is required but not installed."
docker compose version >/dev/null 2>&1 || die "docker compose plugin is required."

# ---------------------------------------------------------------------------
# 1) .env
# ---------------------------------------------------------------------------
if [ ! -f .env ]; then
  warn "No .env found — creating one. (You can abort and pre-write .env anytime.)"

  read -rp "Public hostname (hub domain) [localhost]: " DOMAIN_NAME; DOMAIN_NAME="${DOMAIN_NAME:-localhost}"
  read -rp "Owner email (you): " OWNER_EMAIL
  read -rp "Git user name [ai-agent]: " GIT_USER_NAME; GIT_USER_NAME="${GIT_USER_NAME:-ai-agent}"
  GIT_USER_EMAIL="${OWNER_EMAIL:-ai-agent@localhost}"

  if command -v openssl >/dev/null 2>&1; then
    GITEA_ADMIN_PASSWORD="$(openssl rand -hex 16)"
  else
    GITEA_ADMIN_PASSWORD="$(date +%s%N | sha256sum | cut -c1-32 || echo changeme)"
  fi

  GITEA_PORT=3004; GITEA_SSH_PORT=2222; MCP_PORT=8083
  read -rp "Gitea HTTP port [$GITEA_PORT]: " P; [ -n "$P" ] && GITEA_PORT=$P
  read -rp "MCP port [$MCP_PORT]: " P; [ -n "$P" ] && MCP_PORT=$P

  cat > .env <<EOF
DOMAIN_NAME=${DOMAIN_NAME}
OWNER_EMAIL=${OWNER_EMAIL}
GIT_USER_NAME=${GIT_USER_NAME}
GIT_USER_EMAIL=${GIT_USER_EMAIL}
ALLOWED_HOSTS=${DOMAIN_NAME},127.0.0.1
PUID=${DEFAULT_UID}
PGID=${DEFAULT_GID}
GITEA_VERSION=1.27
GITEA_PORT=${GITEA_PORT}
GITEA_SSH_PORT=${GITEA_SSH_PORT}
MCP_PORT=${MCP_PORT}
GITEA_ADMIN_USERNAME=ai-agent
GITEA_ADMIN_PASSWORD=${GITEA_ADMIN_PASSWORD}
CF_ACCESS_CLIENT_ID=
CF_ACCESS_CLIENT_SECRET=
MCP_ALLOW_NO_AUTH=true
GH_TOKEN=
TUNNEL_TOKEN=
BACKUP_RETENTION_DAYS=14
EOF
  warn "EDIT ME: .env generated. If you plan to expose over Cloudflare, add"
  warn "CF_ACCESS_CLIENT_ID / CF_ACCESS_CLIENT_SECRET / TUNNEL_TOKEN now, then"
  warn "re-run this script. For now continuing with localhost-only mode."
  chmod 600 .env
else
  log "Using existing .env"
fi

set -a; [ -f .env ] && . ./.env; set +a
: "${DOMAIN_NAME:?DOMAIN_NAME missing in .env}"
GITEA_ADMIN_USERNAME="${GITEA_ADMIN_USERNAME:-ai-agent}"
GITEA_ADMIN_PASSWORD="${GITEA_ADMIN_PASSWORD:-}"
: "${GITEA_PORT:=3004}"; : "${GITEA_SSH_PORT:=2222}"; : "${MCP_PORT:=8083}"
: "${PUID:=$DEFAULT_UID}"; : "${PGID:=$DEFAULT_GID}"
GITEA_INTERNAL="http://127.0.0.1:${GITEA_PORT}"
GITEA_OWNER="$GITEA_ADMIN_USERNAME"
GITEA_TOKEN="${GITEA_TOKEN:-}"

mkdir -p data/gitea data/obsidian-vault data/backups data/mirrors
if [ "$(id -u)" = "0" ]; then
  chown -R "$PUID:$PGID" data
else
  # Non-root run: chown may help if PUID/PGID differ from the runner.
  chown -R "$PUID:$PGID" data 2>/dev/null || warn "could not chown data/ to $PUID:$PGID (ensure your user owns ./data)"
fi

# ---------------------------------------------------------------------------
# 2) Seed the vault (only when empty)
# ---------------------------------------------------------------------------
VAULT="data/obsidian-vault"
if [ ! -d "$VAULT/.git" ]; then
  log "Seeding memory vault (3-layer structure + AGENTS.md)"
  cp -a seed/vault/. "$VAULT/"
  cd "$VAULT"
  git init -q -b main
  git -c user.name="$GIT_USER_NAME" -c user.email="${GIT_USER_EMAIL:-${OWNER_EMAIL}}" \
      add -A && git -c user.name="$GIT_USER_NAME" -c user.email="${GIT_USER_EMAIL:-${OWNER_EMAIL}}" \
      commit -q -m "Agent Brain — seed vault $(date -u +%FT%TZ)"
  cd "$HERE"
else
  log "Vault already seeded — skipping"
fi

# ---------------------------------------------------------------------------
# 3) Up
# ---------------------------------------------------------------------------
log "Starting stack"
docker compose up -d --build

log "Waiting for Gitea to become healthy"
for i in $(seq 1 60); do
  if curl -fsS -o /dev/null "$GITEA_INTERNAL/api/healthz" 2>/dev/null; then break; fi
  [ "$i" = "60" ] && die "Gitea did not become healthy. Check: docker compose logs gitea"
  sleep 2
done
echo "Gitea healthy."

# ---------------------------------------------------------------------------
# 4) Ensure admin login + token + memory-vault repo + push
# ---------------------------------------------------------------------------
if [ -z "$GITEA_TOKEN" ]; then
  [ -z "$GITEA_ADMIN_PASSWORD" ] && \
    die "GITEA_ADMIN_PASSWORD is empty in .env and GITEA_TOKEN is not set. Add the real admin password to .env or paste a GITEA_TOKEN, then re-run."

  log "Ensure Gitea admin: ${GITEA_ADMIN_USERNAME}"
  docker compose exec -T --user "$PUID" gitea gitea admin user create \
      --admin --username "$GITEA_ADMIN_USERNAME" \
      --password "$GITEA_ADMIN_PASSWORD" \
      --email "${GITEA_ADMIN_EMAIL:-${OWNER_EMAIL}}" \
      --must-change-password=false >/dev/null 2>&1 || true

  BASIC="-u ${GITEA_ADMIN_USERNAME}:${GITEA_ADMIN_PASSWORD}"
  C=$(curl -s -o /dev/null -w '%{http_code}' $BASIC "$GITEA_INTERNAL/api/v1/user")
  [ "$C" != "200" ] && die "Gitea admin login failed (HTTP $C). Did you change GITEA_ADMIN_PASSWORD in .env after first boot? Put the CURRENT admin password in .env and re-run."

  log "Create Gitea repo: memory-vault"
  curl -s -X POST $BASIC -H "Content-Type: application/json" \
       "$GITEA_INTERNAL/api/v1/user/repos" \
       -d '{"name":"memory-vault","auto_init":false}' | grep -q '"full_name"' \
    || { curl -s $BASIC "$GITEA_INTERNAL/api/v1/repos/${GITEA_OWNER}/memory-vault" | grep -q '"full_name"' || die "failed to ensure memory-vault repo"; }

  log "Create Gitea API token"
  GITEA_TOKEN="$(curl -s -X POST $BASIC -H "Content-Type: application/json" \
       "$GITEA_INTERNAL/api/v1/users/${GITEA_OWNER}/tokens" \
       -d '{"name":"agent-brain-vault","scopes":["write:repository"]}' \
       | grep -oP '"sha1":\s*"\K[^"]+')"
  [ -z "$GITEA_TOKEN" ] && die "failed to create Gitea token"
  echo "GITEA_TOKEN=${GITEA_TOKEN}" >> .env
  chmod 600 .env
fi

cd "$VAULT"
if ! git remote get-url origin >/dev/null 2>&1; then
  git remote add origin "http://${GITEA_OWNER}:${GITEA_TOKEN}@127.0.0.1:${GITEA_PORT}/${GITEA_OWNER}/memory-vault.git"
fi
log "Push vault -> Gitea"
git push -u origin HEAD:main 2>/dev/null || git push -q origin HEAD:main || warn "vault push deferred — brain-hub will retry"

cd "$HERE"

# ---------------------------------------------------------------------------
# 5) Hand-off sheet
# ---------------------------------------------------------------------------
MCP_PUBLIC_URL="${MCP_PUBLIC_URL:-https://${DOMAIN_NAME}/mcp}"
log "DONE — Agent Brain is running on ${DOMAIN_NAME}"

cat <<SHEET

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  SAVE THESE — you will not see them again
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Gitea admin : ${GITEA_ADMIN_USERNAME}
  Gitea URL   : http://127.0.0.1:${GITEA_PORT}  (local)
  MCP endpoint: ${MCP_PUBLIC_URL}
  Gitea token : ${GITEA_TOKEN}
  (admin password is in .env — mode 600)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  NEXT STEPS
  1. Secure remote access (recommended):
       a. Cloudflare Zero Trust -> Access -> Service Auth -> create a Service Token
          (copy CF_ACCESS_CLIENT_ID / CF_ACCESS_CLIENT_SECRET into .env)
       b. Create a Named Tunnel (quick tunnels are not allowed with Access),
          put its token in .env as TUNNEL_TOKEN, then:
             docker compose --profile tunnel up -d
       c. Create an Access application, protect ${MCP_PUBLIC_URL},
          provider=Service Auth, policy grants the Service Token
       d. Re-run:  bash setup.sh   (regenerates the client snippet below)
  2. Local-only mode is active now (MCP_ALLOW_NO_AUTH=true). Do NOT expose the
     MCP port publicly — only run the tunnel once CF credentials are set.
  3. Mount data/obsidian-vault in Obsidian as a vault.
  4. Clone on your phone/PC: git clone via the tunnel host ${DOMAIN_NAME}.
  5. Optional GitHub mirror: put a repo-scope PAT in GH_TOKEN=.env.

  CLIENT SNIPPET (paste into your agent MCP config):
    url:     ${MCP_PUBLIC_URL}
    headers: { "CF-Access-Client-Id": "<id>", "CF-Access-Client-Secret": "<secret>" }
  See client/mcp-snippets.md for per-app examples.

  SERVICES
    docker compose ps                # all four services
    docker exec brain-hub bash /scripts/health-check.sh
    docker compose logs -f brain-hub # automation logs
SHEET
exit 0