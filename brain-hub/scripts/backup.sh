#!/usr/bin/env bash
# Agent Brain — backup: vault git bundle + Gitea data archive, then prune.
set -euo pipefail

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
KEEP="${BACKUP_RETENTION_DAYS:-14}"
ts() { date -u +%FT%TZ; }

mkdir -p /backups

# 1) Restorable one-file bundle of the whole vault history.
if [ -d /vault/.git ]; then
  git -C /vault bundle create "/backups/vault-$STAMP.bundle" --all
  echo "$(ts) [ok] vault bundle"
fi

# 2) Gitea data (config+sqlite under gitea/, repos under git/). Mounted
#    read-only. The ssh/ dir is deliberately NOT tarred: it must stay
#    root-owned (SSH refuses to start otherwise) and the host keys simply
#    regenerate — they are not needed to restore the vault.
if [ -d /gitea-data ]; then
  tar -czf "/backups/gitea-$STAMP.tar.gz" -C /gitea-data gitea git 2>/dev/null
  echo "$(ts) [ok] gitea data"
else
  echo "$(ts) [skip] /gitea-data not mounted"
fi

# 3) Audit trail (outside the vault, agent-inaccessible) — back it up too.
if [ -d /audit ] && [ -n "$(ls -A /audit 2>/dev/null)" ]; then
  tar -czf "/backups/audit-$STAMP.tar.gz" -C /audit . 2>/dev/null
  echo "$(ts) [ok] audit trail"
fi

# 4) Prune old backups.
find /backups \( -name 'vault-*.bundle' -o -name 'gitea-*.tar.gz' -o -name 'audit-*.tar.gz' \) -mtime +"$KEEP" -delete

echo "$(ts) [ok] backups pruned > ${KEEP}d. Current:"
ls -lh /backups