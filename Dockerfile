FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl jq procps netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# --- wgcf (WARP device registration) ---
ARG WGCF_VERSION=2.2.27
RUN ARCH="$(dpkg --print-architecture)" \
    && curl -fsSL -o /usr/local/bin/wgcf \
        "https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_linux_${ARCH}" \
    && chmod +x /usr/local/bin/wgcf

# --- wireproxy (userspace WireGuard -> SOCKS5) ---
ARG WIREPROXY_VERSION=1.0.9
RUN ARCH="$(dpkg --print-architecture)" \
    && curl -fsSL -o /tmp/wireproxy.tar.gz \
        "https://github.com/pufferffish/wireproxy/releases/download/v${WIREPROXY_VERSION}/wireproxy_linux_${ARCH}.tar.gz" \
    && tar -xzf /tmp/wireproxy.tar.gz -C /usr/local/bin wireproxy \
    && chmod +x /usr/local/bin/wireproxy \
    && rm /tmp/wireproxy.tar.gz

WORKDIR /app
COPY scripts/ /app/scripts/
RUN chmod +x /app/scripts/*.sh

ENV SOCKS_PORT=25344 \
    STATE_DIR=/data \
    HEALTH_URL=https://api.ipify.org \
    CHECK_INTERVAL=60 \
    COOLDOWN_SECONDS=1800 \
    QUOTA_ENABLED=1 \
    QUOTA_CHECK_INTERVAL=300 \
    QUOTA_MODEL=deepseek-v4.1-flash-free \
    QUOTA_URL=https://opencode.ai/inference/openai/v1/chat/completions \
    ROTATE_ON_429=0 \
    MIN_ROTATE_GAP=120 \
    REGISTER_RETRY_DELAY=30 \
    REGISTER_429_DELAY=300 \
    MAX_REGISTER_ATTEMPTS=5

VOLUME ["/data"]
EXPOSE 25344

ENTRYPOINT ["/app/scripts/entrypoint.sh"]
