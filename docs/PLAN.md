# Plan: Canary Gateway — balena → self-built stock image, HPR-only uplink path

**Owner:** JT (jameson@buoy.fish) · **Drafted:** 2026-07-27
**Executors:** Claude agents (phases are agent-assignable; each phase ends in something demonstrable)

## Context (self-contained — read this first)

buoy.fish operates a fleet of LoRaWAN gateways (Raspberry Pi + SX1302/SX1303 concentrator HATs) currently running balenaOS, managed via balenaCloud. Gateways today run gateway-rs (Helium) and a GWMP (Semtech UDP) packet forwarder. The target architecture removes gateway-rs from the gateway and points the packet forwarder at **exactly one** upstream: `hpr.buoy.fish`, whose multiplexer fans out to Helium HPR and to ChirpStack at `lns.buoy.fish:1701`. (`lns.buoy.fish` and `hpr.buoy.fish` are grey/DNS-only M2M hostnames — NEVER Cloudflare-proxied; GWMP is UDP and blackholes behind the CF proxy. See CLAUDE.md buoy.fish infra section and ADR-0006.)

This project builds and proves a **canary gateway** on a new, non-balena image in **complete isolation from the primary fleet**. Nothing in this plan may touch the primary balena fleet, its releases, or its device config. The exit criterion is a bench-proven + field-soaked canary and a bench-proven OTA migration path off balenaOS — NOT a fleet migration (that's a separate, later effort).

## Non-goals

- Migrating the primary fleet (only the *mechanism* is proven here, on bench/test devices).
- The vessel-display product (NMEA 2000 / SignalK / plotters) — separate plan. Only its key-sync groundwork appears here, as the stretch phase.
- openBalena (evaluated and rejected: single-user, no dashboard, no delta updates, you inherit the mothership, VPN redundant with Tailscale).
- OS-level A/B updates (mender-convert) — deliberate later hardening, not v1. V1 rollback story = reflash + phone-home.

## Architecture decisions (settled — do not relitigate without flagging JT)

- **D1 — Base image: Raspberry Pi OS Lite 64-bit (pinned release) + Docker Compose.** Not ChirpStack Gateway OS (OpenWrt-based; no natural Docker story, and the visibility requirements below are container-centric; we also want to reuse the existing balena app containers nearly as-is). Not Yocto/Buildroot (prior from-scratch attempt failed to boot; mandate is maximum off-the-shelf).
- **D2 — Image pipeline: `pi-gen`** (the official Raspberry Pi OS build tool) with a custom stage, built in CI (GitHub Actions), artifact = versioned `.img.xz`. The generic image contains **no secrets**; all per-device identity/secrets are injected at flash time (Phase 2). Alternative `sdm` acceptable if pi-gen fights us; escalate before switching.
- **D3 — Tailscale on the host** (native `tailscaled` systemd service, not a container), so remote access survives Docker failures. Devices join with pre-auth keys, tagged (proposed: `tag:gw-canary`), durable (not ephemeral) nodes. Tailscale SSH enabled per existing org practice.
- **D4 — Uplink path: GWMP → `hpr.buoy.fish` ONLY.** No direct gateway→LNS path (avoids ChirpStack dedup noise, halves backhaul, gives the analyzer at HPR 100% visibility). Follow-on (tracked, not this project): firewall LNS UDP 1701 to accept only the HPR host.
- **D5 — App-layer updates: compose images from a registry with channel tags** (`canary`, `stable`). Canary devices pin the `canary` channel; the update mechanism (systemd timer running compose pull+up, or Watchtower — implementer's choice, prefer the simpler systemd timer for debuggability) must make it **structurally impossible** for a canary push to reach `stable` consumers.
- **D6 — Visibility: heartbeats are PUSHED; logs are PULLED.** Agent pushes a heartbeat every 60s to a dedicated machine hostname per ADR-0010 (Service-Auth-only Access app pinned to a service token, 401-no-redirect — precedents: memos-api, accounting-api, monitoring-api). Live logs are pulled on demand by the app backend **over the tailnet** from the gateway agent's HTTP endpoint (requires the backend host to be on the tailnet — verify in Phase 0).
- **D7 — balena→new-image OTA: takeover-style remote reflash.** Privileged container (delivered as a balena release **to an isolated test fleet only**) stages the new image on the data partition, checksums it, pivots to a tmpfs root, `dd`s the whole disk, reboots. Mechanics proven by balena's own `takeover` tool (which goes the opposite direction). One-shot, no rollback — hence bench-proven before any field use.

## Secrets & permissions rails

- All machine/deploy secrets live in OpenBao (`bao.buoy.fish`) via the `bao-ops` skill. Reading/writing EXISTING service secrets and deploy wiring reads = Tier 1 (`claude-ops`).
- **Anything that mints a credential or wires a new service (new bao policy + auth role for the gateway heartbeat API, new Tailscale API access for pre-auth key minting, new CF Access service token) = Tier 2 — STOP and request escalation from JT** (`bao.sh --escalate <code>`); a Tier-1 403 will name the tier needed. Never fetch TOTP codes yourself.
- Repo deploy wiring follows the proven pattern: KV at `secret/<repo>/deploy`, policy `<repo>-deploy`, GitHub OIDC jwt role bound to `repository=buoy-fish/<repo>`, `hashicorp/vault-action@v3`.
- Cloudflare DNS/Access changes via the `cf-provision` skill (`go-claude-go`, Tier 1). Any 1Password read from the Human vault must be announced first (shouldn't be needed here).
- 1Password references by UUID only, never vault name.

## Development practice

TDD (per global CLAUDE.md) applies to all service/agent code: the gateway agent, the heartbeat API, the log-streaming endpoint, the key-sync service, the UI data layer. It does NOT meaningfully apply to image building, flashing scripts, or the takeover migrator — for those, the "test" is the phase's demonstrable outcome on real hardware, plus shellcheck/dry-run modes where cheap. State this rather than silently skipping.

---

## Phase 0 — Discovery (read-only; parallel agents)

Goal: replace this plan's assumptions with facts. No writes anywhere.

1. **Balena fleet inventory:** enumerate the current fleet's services/containers, images, device variables, privileged flags, and the packet-forwarder flavor + config in use (sx1302_hal UDP forwarder vs concentratord). Confirm the Tailscale container exists fleet-wide and how it authenticates. Output: manifest doc mapping each balena service → keep / drop (gateway-rs: drop) / port-to-compose.
2. **HPR mux verification:** in the `hpr.buoy.fish` repo, confirm the multiplexer's backend config (Helium path + `lns.buoy.fish:1701`), how PULL_DATA sessions / downlink (PULL_RESP) routing per gateway EUI works, and whether backends can be marked uplink-only. Note: the repo's docker-compose comment saying the mux forwards to `console.buoy.fish` is STALE; live config uses `lns.buoy.fish:1701`.
3. **Primary app recon:** identify the app repo/stack where the gateway fleet UI will live, its backend deployment host, and whether that host is on the tailnet (needed for D6 log pulls). Identify how monitoring-api ingests heartbeats today (pattern to mirror or extend).
4. **Tailnet recon:** current ACL structure, tag conventions, whether pre-auth keys are minted via API today (and where that API key would live in bao).
5. **Bench hardware:** confirm with JT which Pi model(s) + HAT(s) are on the bench and pin the exact canary BOM (Pi model, HAT, PSU, SD card class). The image pins to this BOM.

**Deliverable:** a short findings doc updating/confirming D1–D7 and filling the Open Questions below. Anything contradicting a decision → flag JT before Phase 1.

## Phase 1 — Base image (`buoy-gateway` repo)

Goal: a CI-built, versioned, generic image that boots on the bench BOM.

1. New repo `buoy-fish/buoy-gateway`: pi-gen pipeline with a custom stage installing: pinned Docker Engine + compose plugin, `tailscaled` (enabled, not authed), the compose stack (packet forwarder ported from balena config → GWMP server = `hpr.buoy.fish`; gateway-agent stub), a `buoy-firstboot.service`, and log2ram or journald size caps (SD wear).
2. Per-HAT reset-GPIO handling (the classic SX1302-on-Pi trap) parameterized by a config file, not baked in.
3. CI: GitHub Actions builds `.img.xz` on tag, publishes as a release artifact. Deploy secrets (registry pull creds if needed) via the bao OIDC pattern.
4. Container images pushed to the chosen registry (Phase 0 decides which) with `canary` channel tags.

**Deliverable:** bench Pi boots the CI-built image, concentrator initializes, uplinks visible at the HPR mux. (Manually authed Tailscale is fine at this phase.)

## Phase 2 — Flash & provision process, phone-home

Goal: flashing a card for a specific device is one command; first boot announces itself.

1. `flash.sh <device-name>`: takes a generic image + per-device identity; mints a Tailscale pre-auth key (API key from bao — if this requires new bao wiring, that's Tier 2, stop for JT); writes device config (name, gateway EUI, tailscale key, heartbeat service token) into the boot partition via RPi OS's firstrun mechanism. Secrets touch only the specific card being flashed, never the generic artifact.
2. `buoy-firstboot.service`: joins tailnet, starts compose stack, then POSTs a provision/phone-home event (device name, image version, tailscale IP, hardware info) to the heartbeat endpoint; retries until acked. Device then appears in the app as "provisioned".
3. Runbook: flashing, bench-verify checklist, and recovery (reflash) procedure.

**Deliverable:** flash a card, boot it, device appears on tailnet and phones home with zero manual steps after power-on.

## Phase 3 — Canary isolation & update channel

Goal: prove updates to canary NEVER touch the primary fleet.

1. Implement the D5 channel mechanism (systemd timer: compose pull `:canary` + up, with health-gate: only restart if new image pulled and current stack healthy).
2. Demonstrate: push a trivial canary-channel update → canary device updates; primary balena fleet provably unaffected (it consumes a different mechanism entirely — document why cross-contamination is structurally impossible, don't just assert it).
3. Version reporting: agent heartbeat includes image + per-container versions so the app shows what's deployed where.

**Deliverable:** recorded update run: old version → push → canary self-updates → heartbeat shows new version.

## Phase 4 — Realtime visibility in the primary app

Goal: one pane of glass for canary gateway health. (TDD throughout.)

1. **gateway-agent** (small service on the Pi, read-only Docker socket): 60s heartbeat push — last-boot, uptime, container states/restarts, disk, SoC temp, tailscale status, versions, packet-forwarder liveness (last uplink forwarded timestamp if cheaply available). Plus a tailnet-only HTTP endpoint: `GET /logs?container=&follow=` streaming docker logs, `GET /status` on-demand snapshot.
2. **Heartbeat ingest:** new endpoint following ADR-0010 (dedicated machine hostname, e.g. `gateway-api.buoy.fish`, CF Access Service-Auth-only app pinned to a new service token — the token mint + Access app + bao policy are **Tier 2 / cf-provision work; batch these for one JT escalation session**). Store heartbeats; derive last-connected and stale/offline state.
3. **UI in the primary app:** fleet page — per-gateway card: online/stale badge, last connected, heartbeat age, container health, versions, tailscale IP; drill-in view with live log tail (backend proxies the agent's tailnet endpoint over WebSocket/SSE — browsers never touch machine hostnames; per ADR-0010, human views never build on machine base URLs).
4. **Alerting:** stale-heartbeat (> N minutes) alarm via the existing monitoring path.

**Deliverable:** canary visible in the app with live data; pulling the Pi's power flips it to offline and fires the alert; plugging back in recovers it.

## Phase 5 — OTA balena → new image (bench proof)

Goal: unattended remote transition of a balenaOS device to the new image. DANGER ZONE — isolated balena TEST fleet only; the migrator must hard-refuse to run outside an allowlisted fleet/device set.

1. Create a **new, isolated balena test fleet**; provision 1–2 bench devices with the same OS version/app shape as production.
2. Build the migrator (privileged container, takeover technique): download image to data partition → checksum verify → preflight (power/undervoltage flags, free space, image-BOM match) → pivot to tmpfs → `dd` full disk → reboot. Abort-safe at every step before the `dd` point of no return.
3. Success = bench device transitions unattended and phones home on the new image within X minutes. Run ≥3 times (including once with a deliberately corrupted download to prove the checksum abort path).
4. Document: failure modes, brick recovery, and the future primary-fleet rollout playbook (waves, phone-home confirmation gate, expected brick %) — **playbook only; execution is explicitly out of scope and requires JT's go.**

**Deliverable:** repeatable bench transition + written migration playbook.

## Phase 6 — Field canary & soak

Goal: real-world confidence.

1. Deploy one canary gateway to the field (or realistic bench-in-window if a field slot isn't available — JT's call).
2. Soak criteria (tune in Phase 0): ≥14 days; uplink parity vs a comparable balena gateway measured at the HPR analyzer; zero unexplained heartbeat gaps; ≥1 successful canary-channel update in situ; downlink path verified end-to-end (join or confirmed downlink through mux → gateway).
3. Exit review with JT: green-light criteria for the (separate, future) fleet-migration project.

**Deliverable:** soak report with the parity data.

## Phase 7 — STRETCH: offline key sync groundwork

Only after Phases 1–4 are green. Scope = chunks 1–2 of the vessel-hub plan (passive decryption with opportunistic key sync); the display/NMEA/plotter work is explicitly NOT here.

1. **Bench spike:** tee GWMP on the bench gateway; local service matches DevAddr, verifies MIC, decrypts one buoy's uplinks with hand-copied session keys, prints lat/lon. Accept a wide FCnt window locally (passive/read-only, low stakes).
2. **Key-sync service:** fleet-scoped cloud endpoint exposing device sessions (DevAddr, AppSKey, NwkSKey, FCnt) from ChirpStack + gateway-side cache that syncs when connectivity exists and serves the decoder offline. This is new-credential wiring → **Tier 2, batch with Phase 4's escalation if timing allows.** TDD applies.

**Deliverable:** bench gateway, offline (WAN unplugged), still decoding and printing live buoy positions from synced keys.

---

## Open questions for JT (answer before/during Phase 0)

1. Bench hardware: exact Pi model(s) + HAT(s) available now, and can one field slot host the canary for the soak?
2. Container registry preference (ghcr.io vs self-hosted) for the `canary`/`stable` channels?
3. Which repo/app is "the primary app" for the fleet UI, and is its backend host already on the tailnet?
4. Tailnet tag naming + is there an existing Tailscale API key in bao, or is that a new mint (Tier 2)?
5. Naming: `gateway-api.buoy.fish` OK for the heartbeat machine hostname (per ADR-0010 convention)?

## Success criteria (whole exercise)

- Canary gateway: flashed via the documented one-command process, phones home on first boot, joins tailnet, forwards GWMP **only** to `hpr.buoy.fish`, uplinks confirmed at LNS via the mux, downlinks work.
- App shows heartbeat, last connected, container health, versions, and live logs for the canary; offline alerting works.
- Canary-channel updates provably cannot touch the primary fleet.
- A balenaOS bench device was OTA-transitioned to the new image unattended, ≥3/3 attempts, with the abort path proven.
- Primary fleet: zero changes, zero risk exposure, throughout.
