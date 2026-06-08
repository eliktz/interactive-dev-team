# warroom2/Dockerfile
FROM python:3.11-slim

# curl needed for healthcheck.
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Docker CLI: install the static binary from Docker, NOT the Debian `docker.io`
# package. On Debian bookworm slim images, `docker.io` ships only the daemon
# binaries (dockerd / docker-proxy / docker-init) and omits the `docker` client
# binary — leaving every `docker exec` call from inside this container failing
# with ENOENT. The static stable bundle gives us the real client.
ARG DOCKER_CLI_VERSION=29.5.3
RUN curl -fsSL "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_CLI_VERSION}.tgz" -o /tmp/docker.tgz && \
    tar -xzC /usr/local/bin --strip-components=1 -f /tmp/docker.tgz docker/docker && \
    rm /tmp/docker.tgz && \
    /usr/local/bin/docker --version

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
