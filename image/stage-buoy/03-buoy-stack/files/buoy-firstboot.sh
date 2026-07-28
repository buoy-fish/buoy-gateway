#!/bin/bash
# First-boot provisioning: consumes /boot/firmware/buoy/site.json written by
# flash.sh (Phase 2). Idempotent; without site.json the device boots idle.
set -euo pipefail

MARKER=/var/lib/buoy/firstboot-done
SITE=/boot/firmware/buoy/site.json
CONFIG_DIR=/opt/buoy/config

if [ -e "${MARKER}" ]; then
	exit 0
fi

if [ ! -f "${SITE}" ]; then
	echo "buoy-firstboot: no ${SITE}; provisioning deferred"
	exit 0
fi

DEVICE_NAME=$(jq -er '.device_name' "${SITE}")
TS_AUTH_KEY=$(jq -er '.tailscale_auth_key' "${SITE}")
MQTT_PASSWORD=$(jq -er '.mqtt_password' "${SITE}")

hostnamectl set-hostname "${DEVICE_NAME}"

# Org practice: tailscale ssh on, MagicDNS off on machines.
tailscale up \
	--auth-key="${TS_AUTH_KEY}" \
	--hostname="${DEVICE_NAME}" \
	--ssh \
	--accept-dns=false

# Render broker credentials (jq-based substitution: password-safe for any chars).
jq -rn --rawfile tmpl "${CONFIG_DIR}/chirpstack-mqtt-forwarder.toml.tmpl" \
	--arg pw "${MQTT_PASSWORD}" \
	'$tmpl | gsub("__MQTT_PASSWORD__"; $pw)' \
	> "${CONFIG_DIR}/chirpstack-mqtt-forwarder.toml"
chmod 600 "${CONFIG_DIR}/chirpstack-mqtt-forwarder.toml"

docker compose -f /opt/buoy/docker-compose.yml up -d

# TODO Phase 2: phone-home POST (device name, image version, tailscale IP) to
# the heartbeat endpoint with retry-until-ack; then shred site.json secrets.

touch "${MARKER}"
echo "buoy-firstboot: provisioned as ${DEVICE_NAME}"
