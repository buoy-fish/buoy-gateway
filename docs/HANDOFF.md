# Handoff — canary cutover paused 2026-07-30

Project: migrate the gateway fleet off balenaOS onto this self-built Pi OS
image without losing app features. Current milestone: **shape-2 canary
cutover** — flash the new image in place over the canary's balena card as the
litmus for migrating everyone else the same way.

Doc map: `PLAN.md` (original phased plan, D1–D7), `PHASE0-FINDINGS.md`
(discovery + live-verification results), `CUTOVER.md` (the runbook to
execute on resume).

## State at pause

| Item | Status |
|---|---|
| Phase 0 discovery | DONE (see PHASE0-FINDINGS.md) |
| Canary device `3110fe61…` | Moved to fleet `canary-fleet-for-buoy-test-gateway`; identity escrowed at `~/buoy/backups/gateway-3110fe6-pre-fleet-move-2026-07-28/`; **unplugged/dark since ~07-28** |
| Bench spike | concentratord 4.7.1 + mqtt-forwarder 4.6.0 validated ON the canary hardware (uplinks, 30 s stats, downlink round-trips via hpr:1883); spike containers still installed on its balenaOS — plugging the device in WITHOUT flashing resumes the MQTT soak (more baseline data, harmless) |
| Phase 1 CI | GREEN: lint, containers (`ghcr.io/buoy-fish/gateway-{concentratord,mqtt-forwarder}:canary`, public), pi-gen image (~33 min/build) |
| Firstboot hardening | Commit `a6bf105`: retry loops (~10 min each) around `tailscale up` + compose pull — required for phone-home confidence |
| Image artifact | Rebuild with the hardening = run 30584850688 (2026-07-30). **Artifacts expire after 14 days** — if stale on resume, just re-dispatch the `image` workflow (~33 min, no code changes needed) |
| site.json | STAGED at `~/buoy/backups/canary-cutover/site.json` (mode 600): device_name + hpr broker password already injected; `tailscale_auth_key` is a `REPLACE_WITH_TAGGED_TSKEY` placeholder |
| img-v0.1.0 tag | Deliberately NOT cut — first tag only after the bench gates pass (CUTOVER.md §5) |

## Resume checklist (in order)

1. Fresh artifact: download from the latest green `image` run and verify
   `SHA256SUMS`; re-dispatch the workflow if >14 days old.
2. JT mints a Tailscale pre-auth key: **tag `tag:buoy-gateway`, non-reusable,
   non-ephemeral**. Tagged keys self-apply their tags; firstboot needs no
   `--advertise-tags`. Paste into the staged site.json.
3. Sanity: both ghcr packages still anonymously pullable (firstboot pulls
   `:canary` unauthenticated).
4. Execute `CUTOVER.md` §1 (flash) → §2 (gates G1–G6) → §5 (tag v0.1.0) —
   or §3 (rollback) if a gate fails.
5. Then: enumerate balena-dependent app features (heartbeat, OTA view, log
   pull) and design non-balena equivalents (Phase 4 gateway-agent; app box is
   on the tailnet at 100.73.73.98 ready for log pulls).

## Where the secrets are (never echo any of these)

- hpr broker password (`gateway` user): already inside the staged site.json;
  source of truth = `/home/ubuntu/hpr-bridge/config/lorawan-multiplexer-converter.toml`
  on hpr.buoy.fish (the mux authenticates as the same user the fleet uses).
- Helium identity escrow (`gateway_key.bin`, ruled expendable): the backups
  dir above. Proper escrow home = pending Tier-2 batch item.
- Tailscale server key (app box join used it):
  `op://n7zqudnwyk4wj6asredzjjdlqu/tailscale keys/buoy-server-key` (Machine
  vault, by UUID).

## Deferred / backlog (not blocking cutover)

- Mux PULL_DATA-suppression patch — blocked on testing JT's hypothesis that
  routing Join-Accepts through Helium HPR is load-bearing for Helium state.
- Tier-2 batch for one JT session: bao path for the TS fleet key, tailscale
  API minting, gateway-api.buoy.fish token/Access app, gateway_key.bin
  escrow home.
- Phase 2: pubkey SSH (drop bench password), phone-home + site.json shred,
  real `flash.sh`.
- Prod hygiene on hpr: mosquitto-exporter permanent auth-fail loop (floods
  broker log to ~hours retention), `:1680` bound on 0.0.0.0 (SG audit).
- App box: pending kernel reboot from unattended-upgrades.
- Old `buoy/gateway-image` branch in helium-gateway-balena: local-only,
  unpushed, historically crashed the Pi — superseded by this repo; delete or
  archive.

## Gotchas that cost time once already

- `balena device ssh <uuid>` parses a command argument as a service name —
  pipe commands via stdin (`printf 'cmd\nexit\n' | balena device ssh …`);
  engine binary on-device is `balena-engine`.
- pi-gen in CI: host needs the `qemu-user-static` apt package
  (docker/setup-qemu-action is NOT enough); `deploy/` comes out root-owned —
  chown before checksumming; `touch stage2/SKIP_IMAGES` to export only our
  stage.
- concentratord `model="rak_2287"` preset (pin 17) drives the RAK2287 reset
  correctly — no custom reset script, no pin-25 override.
- Gateway EUI comes from SX1302 silicon (`0016c001ff15e548`) — identity
  survives any reflash with zero restore work.
- `:stable` container tag only via manual promote dispatch (type "promote");
  main pushes only refresh `:canary`.
