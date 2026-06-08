# warroom2/Dockerfile
FROM python:3.11-slim

# docker CLI client only (daemon is mounted from host). curl needed for healthcheck.
# NOTE: Debian bookworm ships the CLI as the `docker.io` package (no separate
# `-cli` package on Debian, unlike Ubuntu). We get the daemon binary as a side
# effect but never start it — the host's daemon socket is bind-mounted.
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends docker.io curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN pip install --no-cache-dir \
    'fastapi>=0.115,<1' \
    'uvicorn[standard]>=0.32,<1' \
    'aiofiles>=24' \
    'httpx>=0.27'

COPY warroom2/ ./warroom2/
COPY static/ ./static/

# Non-root user; UID 1001 matches host ravi user so docker socket permissions work
RUN groupadd -g 1001 docker-host && \
    useradd -m -u 1001 -g 1001 -s /bin/bash warroom2 && \
    mkdir -p /var/lib/warroom2 && \
    chown warroom2:docker-host /var/lib/warroom2

USER warroom2
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS http://localhost:8080/healthz || exit 1

ENTRYPOINT ["python", "-m", "warroom2"]
