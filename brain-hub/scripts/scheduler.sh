# Agent Brain — brain-hub scheduler sidecar.
# Runs the maintenance jobs in a loop, sleeping between rounds. Logs land in
# /backups/logs (persistent, host-visible). Safe to run repeatedly.
set -uo pipefail

SYNC_INTERVAL="${SYNC_INTERVAL:-900}"        # 15 min
BACKUP_INTERVAL="${BACKUP_INTERVAL:-43200}"  # 12 h
MIRROR_INTERVAL="${MIRROR_INTERVAL:-14400}"  # 4 h

LOG_DIR="${LOG_DIR:-/backups/logs}"
mkdir -p "$LOG_DIR"

# Stagger so jobs don't all fire at once and gitea is warm first.
now=$SECONDS
next_sync=$((now + SYNC_INTERVAL))
next_backup=$((now + 120))
next_mirror=$((now + 60))

echo "brain-hub scheduler started ($(date -u +%FT%TZ))"

while true; do
  now=$SECONDS

  if [ "$now" -ge "$next_sync" ]; then
    /scripts/auto-sync.sh >>"$LOG_DIR/sync.log" 2>&1 || true
    next_sync=$((now + SYNC_INTERVAL))
  fi

  if [ "$now" -ge "$next_backup" ]; then
    /scripts/backup.sh >>"$LOG_DIR/backup.log" 2>&1 || true
    next_backup=$((now + BACKUP_INTERVAL))
  fi

  if [ "$now" -ge "$next_mirror" ]; then
    /scripts/github-mirror-sync.sh >>"$LOG_DIR/mirror.log" 2>&1 || true
    next_mirror=$((now + MIRROR_INTERVAL))
  fi

  sleep 30
done