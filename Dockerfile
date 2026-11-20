FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl jq supervisor socat procps \
    && rm -rf /var/lib/apt/lists/*

# --- wgcf (WARP device registration) ---
ARG WGCF_VERSION=2.2.27
RUN curl -fsSL -o /usr/local/bin/wgcf \
        "https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_linux_amd64" \
    && chmod +x /usr/local/bin/wgcf

# --- wireproxy (userspace WireGuard -> SOCKS5) ---
ARG WIREPROXY_VERSION=1.0.9
RUN curl -fsSL -o /tmp/wireproxy.tar.gz \
        "https://github.com/pufferffish/wireproxy/releases/download/v${WIREPROXY_VERSION}/wireproxy_linux_amd64.tar.gz" \
    && tar -xzf /tmp/wireproxy.tar.gz -C /usr/local/bin wireproxy \
    && chmod +x /usr/local/bin/wireproxy \
    && rm /tmp/wireproxy.tar.gz

WORKDIR /app
COPY scripts/ /app/scripts/
RUN chmod +x /app/scripts/*.sh

ENV POOL_SIZE=3 \
    BASE_PORT=25344 \
    CHECK_INTERVAL=300 \
    COOLDOWN_SECONDS=1800 \
    REGISTER_DELAY=60 \
    STATE_DIR=/data \
    HEALTH_URL=https://api.ipify.org \
    TARGET_URL=https://opencode.ai

VOLUME ["/data"]
EXPOSE 25344 25345 25346 25347 25348 25349 25350 25351 25352 25353

ENTRYPOINT ["/app/scripts/entrypoint.sh"]
