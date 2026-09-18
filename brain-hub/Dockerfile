FROM alpine:3.20

# bash (scheduler), git (vault/mirror ops), curl+jq (Gitea/GitHub APIs),
# openssh-client (mirror fetch over ssh if ever used), coreutils (base64 -w0).
RUN apk add --no-cache bash git curl openssh-client jq coreutils

COPY scripts /scripts
# 755 (not just +x): the sidecar may run as a non-root host uid (PUID), so the
# scripts must be world-readable/executable regardless of the build umask.
RUN chmod 755 /scripts/*.sh

# Persisted across restarts so logs survive container recreation.
VOLUME /backups

CMD ["bash", "/scripts/scheduler.sh"]