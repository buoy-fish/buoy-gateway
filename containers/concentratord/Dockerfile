FROM debian:bookworm-slim

ARG VERSION=4.7.1
ARG SHA256=328faf7e6fe6fcc9f5a50f8368fd520807ac2939214c607593318e017e857345

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && curl -fsSL -o /tmp/concentratord.tar.gz \
        "https://artifacts.chirpstack.io/downloads/chirpstack-concentratord/chirpstack-concentratord-sx1302_${VERSION}_linux_arm64.tar.gz" \
    && echo "${SHA256}  /tmp/concentratord.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/concentratord.tar.gz -C /usr/local/bin chirpstack-concentratord-sx1302 \
    && rm /tmp/concentratord.tar.gz \
    && apt-get purge -y curl \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["/usr/local/bin/chirpstack-concentratord-sx1302"]
CMD ["-c", "/etc/concentratord/concentratord.toml"]
