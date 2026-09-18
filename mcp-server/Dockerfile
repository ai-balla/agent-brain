FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    VAULT_ROOT=/vault

WORKDIR /app
COPY requirements.txt /app/requirements.txt

# curl is used by the compose healthcheck.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir -r /app/requirements.txt

COPY server.py /app/server.py

# Explicit read bits: the bridge may run as an unprivileged host uid (PUID),
# so the code must be world-readable regardless of the build host's umask.
RUN chmod 644 /app/server.py

EXPOSE 8083

# Binds inside the container; the compose file maps it to host loopback only.
CMD ["python", "server.py", "--host", "0.0.0.0", "--port", "8083", "--path", "/mcp"]