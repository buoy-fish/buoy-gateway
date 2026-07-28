FROM debian:bookworm-slim

ARG VERSION=4.6.0
ARG SHA256=8be1c4fd70a4fdd921d87a01daf1c4ac5d4b8fef8dc7db37334d922b6d9675cd

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && curl -fsSL -o /tmp/mqtt-forwarder.tar.gz \
        "https://artifacts.chirpstack.io/downloads/chirpstack-mqtt-forwarder/chirpstack-mqtt-forwarder_${VERSION}_linux_arm64.tar.gz" \
    && echo "${SHA256}  /tmp/mqtt-forwarder.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/mqtt-forwarder.tar.gz -C /usr/local/bin chirpstack-mqtt-forwarder \
    && rm /tmp/mqtt-forwarder.tar.gz \
    && apt-get purge -y curl \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["/usr/local/bin/chirpstack-mqtt-forwarder"]
CMD ["-c", "/etc/chirpstack-mqtt-forwarder/chirpstack-mqtt-forwarder.toml"]
