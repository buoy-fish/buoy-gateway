#!/bin/bash
# Phase 2: flash.sh <device-name> — write the generic image to an SD card and
# inject per-device identity (site.json: device_name, tailscale_auth_key,
# mqtt_password, heartbeat token) into the boot partition. Secrets touch only
# the card being flashed, never the generic artifact.
set -euo pipefail
echo "flash.sh: not implemented yet (Phase 2)" >&2
exit 1
