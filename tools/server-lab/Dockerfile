ARG BASE=debian:bookworm-slim
FROM ${BASE}
RUN apt-get update && apt-get install -y --no-install-recommends ocserv openssl \
    && rm -rf /var/lib/apt/lists/*
COPY start.sh /start.sh
ENTRYPOINT ["/bin/sh", "/start.sh"]
