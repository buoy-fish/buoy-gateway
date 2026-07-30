# Canary cutover runbook — balenaOS → buoy-gateway image (shape 2)

Replaces balenaOS on the canary gateway ("Costa Rica Indoor 3", Pi 4B +
RAK2287, EUI `0016c001ff15e548`, balena UUID `3110fe61…`) with the self-built
image, in place, on the same SD card. This is the litmus for migrating the
rest of the fleet with the same process.

Safety envelope: the device is in-hand (bench), its Helium identity is
escrowed AND ruled expendable, its LoRaWAN identity is chip-derived (survives
any reflash automatically), and the balenaCloud re-flash path back to the
canary fleet is intact. Worst case is a 20-minute reflash backwards.

## 0. Prerequisites (before touching the card)

- [ ] Image artifact downloaded and `SHA256SUMS` verified locally.
      Source: latest green `image` workflow run (or an `img-v*` release).
- [ ] Both ghcr packages public (anonymous `docker pull` returns 200) —
      firstboot pulls `:canary` unauthenticated.
- [ ] **Tailscale pre-auth key** (JT mints, admin console → Keys):
      tag `tag:buoy-gateway`, *not* reusable, *not* ephemeral, expiry ≥ a few
      days. A tagged key applies its tags on join; firstboot passes no
      `--advertise-tags`.
- [ ] **hpr broker password** for user `gateway` (extracted from the hpr live
      config at staging time; never echoed or committed).
- [ ] `site.json` staged locally (template below), `chmod 600`.
- [ ] Canary's current balena install is expected to be DOWN already
      (device unplugged). If it is running, note the spike containers'
      state for parity, then power off cleanly.

`site.json` (goes to `buoy/site.json` on the boot partition):

```json
{
  "device_name": "costa-rica-indoor-3",
  "tailscale_auth_key": "tskey-auth-…",
  "mqtt_password": "…"
}
```

## 1. Flash (macOS, hands-on)

```sh
diskutil list                          # identify the SD card, e.g. /dev/disk4
diskutil unmountDisk /dev/diskN
xzcat image_*-buoy-gateway.img.xz | sudo dd of=/dev/rdiskN bs=4m status=progress
diskutil mountDisk /dev/diskN          # remounts; bootfs appears
mkdir -p /Volumes/bootfs/buoy
cp <staged>/site.json /Volumes/bootfs/buoy/site.json
diskutil eject /dev/diskN
```

Insert card, power on. First boot: filesystem expansion + reboot, then
`buoy-firstboot` runs (retries network steps for up to ~10 min each).

## 2. Verification gates (in order; stop at first failure)

| Gate | Check | How |
|---|---|---|
| G1 boot | Device up on LAN | `ssh buoy@<lan-ip>` (password `buoy-bench-only`), or HDMI |
| G2 phone-home | Tailnet join | Device appears in admin console as `costa-rica-indoor-3` (tag:buoy-gateway); `tailscale ping costa-rica-indoor-3`; `ssh buoy@<ts-ip>` (tailscale SSH) |
| G3 stack | Both containers running | `docker ps` shows concentratord + mqtt-forwarder, restarting=false |
| G4 uplink | EUI publishing to hpr | On hpr box: subscribe `us915_1/gateway/0016c001ff15e548/event/stats` — one message ≤ 35 s |
| G5 downlink | Round-trip works | Watch `…/command/down` → `…/event/ack` for the EUI (ChirpStack traffic to a bench device), as in the 07-28 spike |
| G6 parity | Analyzer continuity | Analyzer shows the SAME gateway row (EUI-keyed) with fresh last-seen; uplink cadence comparable to the spike soak |

G1 fallback exists precisely because this is bench work: if G2 fails, the
bench password + LAN SSH (or keyboard/HDMI) recovers the device for
diagnosis — journal: `journalctl -u buoy-firstboot`.

## 3. Rollback (any gate fails and can't be diagnosed quickly)

1. balenaCloud → fleet `canary-fleet-for-buoy-test-gateway` → *Add device* →
   download balenaOS image (development variant, same config as before).
2. Flash it over the card (same `dd` procedure). Device re-provisions into
   the canary fleet on boot (it re-registers; the old dashboard entry for
   `3110fe61…` may be superseded by a new UUID — that is fine, the fleet is
   canary-only).
3. LoRaWAN identity needs nothing: EUI comes from SX1302 silicon.
4. Helium identity (`gateway_key.bin`) is escrowed at
   `~/buoy/backups/gateway-3110fe6-pre-fleet-move-2026-07-28/` but ruled
   expendable — only restore if a reason emerges.
5. Remove the tailnet node for `costa-rica-indoor-3` in the admin console if
   the join happened before the failure (avoid a stale node stealing the
   hostname on the next attempt).

## 4. Known gaps accepted for the canary (Phase 2 backlog)

- `site.json` persists on the boot partition after provisioning (auth key is
  single-use and expires, but the MQTT password remains readable on the
  card) — Phase 2 adds phone-home + shred.
- Bench password auth (`buoy` / `buoy-bench-only`) — Phase 2 moves to pubkey.
- `flash.sh` is a stub; flashing is manual per §1.
- No heartbeat to app.buoy.fish yet — remote liveness is tailnet reachability
  + broker stats until the Phase 4 gateway-agent.

## 5. After the gates pass

- Tag the validated commit `img-v0.1.0` (CI attaches the image to a GitHub
  release — the 14-day artifact retention stops mattering).
- Leave the canary soaking; compare against the spike-era baseline
  (uplink cadence, TX-ack behavior, analyzer stats).
- Then: enumerate balena-dependent app features (heartbeat path, OTA view,
  log pull) and design their non-balena equivalents.
