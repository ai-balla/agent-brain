#!/usr/bin/env bash
# Agent Brain — uninstall: stop the stack and (opt-in) delete data.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

echo "Stopping stack..."
docker compose down || true

if [ -f .env ]; then
  read -rp "Also delete ./data (vault, gitea, backups, mirrors) and .env? [y/N] " ANS
  case "$ANS" in
    y|Y)
      rm -rf data .env
      echo "Removed ./data and .env."
      ;;
    *)
      echo "Kept ./data and .env."
      ;;
  esac
fi

echo "Done. Remove this directory with:  rm -rf $(pwd)"