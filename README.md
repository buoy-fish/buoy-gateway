# buoy-gateway

CI-built Raspberry Pi OS image + container stack for buoy.fish LoRaWAN gateways
(canary program — see the canary plan + Phase 0 findings docs; primary balena
fleet is NOT touched by anything in this repo).

## Architecture (settled decisions)

- **Base image:** Raspberry Pi OS Lite 64-bit (bookworm), built with pi-gen
  pinned to release tag `2026-06-18-raspios-bookworm-arm64`
  (`d7a31c6aa09f4b867902c51da2b45807c0a1709e`). Generic artifact contains **no
  secrets** — per-device identity is injected at flash time (Phase 2,
  `scripts/flash.sh`).
- **Radio stack (hardware-validated 2026-07-28 on the canary, Pi 4B + RAK2287):**
  `chirpstack-concentratord-sx1302` 4.7.1 (`model="rak_2287"` preset, no reset
  overrides — verified working; gateway ID read from SX1302 silicon) +
  `chirpstack-mqtt-forwarder` 4.6.0 (concentratord backend over ZeroMQ ipc).
- **One upstream:** MQTT over TCP to `hpr.buoy.fish:1883`, topic prefix
  `us915_1`, protobuf. No GWMP leaves the device. (Amended D4 — the hpr
  multiplexer fans out to Helium HPR + ChirpStack LNS.)
- **Tailscale on the host** (`tailscaled` systemd service, not a container);
  joined at first boot with a flash-time pre-auth key.
- **Update channels (D5):** compose images from ghcr with `canary` / `stable`
  tags. Canary devices pin `:canary`. Cross-contamination with the primary
  fleet is structurally impossible: the balena fleet consumes balenaCloud
  releases exclusively; nothing in this repo can produce one.
  `:stable` is only ever produced by the explicit `promote-stable` manual
  workflow — no automatic path from a push to `:stable`.

## Repo layout

- `containers/` — Dockerfiles for the two runtime images
  (`ghcr.io/buoy-fish/gateway-concentratord`, `ghcr.io/buoy-fish/gateway-mqtt-forwarder`),
  pinned by version + tarball sha256.
- `image/` — pi-gen `config` + custom `stage-buoy` (Docker Engine + compose
  plugin, tailscaled, the compose stack, `buoy-firstboot.service`, journald
  size caps, SPI/I2C enable).
- `scripts/flash.sh` — Phase 2 stub (per-device provisioning).
- `.github/workflows/` — `build-containers.yml` (push → `:canary`),
  `build-image.yml` (dispatch/tag → `.img.xz` release artifact), lint.

## Building

- Containers: pushed by CI on changes under `containers/` (linux/arm64).
- Image: run the **build-image** workflow (dispatch), or push an `img-v*` tag.
  Roughly 60–120 min (qemu). Artifact: `buoy-gateway-<date>.img.xz`.

## First boot

`buoy-firstboot.service` looks for `/boot/firmware/buoy/site.json` (written by
`flash.sh`): sets hostname, joins the tailnet, renders the mqtt-forwarder
config (broker credentials), `docker compose up -d`. Without `site.json` the
device boots idle and provisioning is deferred (safe generic image).

## Known TODOs (tracked, deliberate)

- Phase 2: real `flash.sh` (tailscale key mint, heartbeat token), phone-home,
  shred of `site.json` secrets after render, SSH pubkey-only (bench password
  build until then).
- Narrow concentratord container from `privileged` to explicit devices.
- Docker Engine version pin (currently repo-channel latest at build time;
  recorded in `/etc/buoy/build-manifest`).
- gateway-agent service (Phase 4, TDD) — placeholder in compose comments.
