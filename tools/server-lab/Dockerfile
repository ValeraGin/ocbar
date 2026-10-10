ARG BASE=debian:bookworm-slim
FROM ${BASE}
RUN apt-get update && apt-get install -y --no-install-recommends ocserv openssl openconnect python3 iproute2 dnsmasq \
    && rm -rf /var/lib/apt/lists/*
# Public VPN gateways need the normal trust store as well as fixture-specific CAs.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY start.sh /start.sh
ENTRYPOINT ["/bin/sh", "/start.sh"]
