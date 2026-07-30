# Phase 0 Findings — Canary Gateway Discovery

**Date:** 2026-07-28 · **Companion to:** `buoy-gateway-canary-plan.md` · **Produced by:** 5 parallel read-only discovery agents (balena fleet, canary device, HPR mux, primary app, tailnet/secrets/registry)

## TL;DR — what changed vs the plan's assumptions

1. **The plan's picture of today's uplink topology was wrong in both directions.** Balena gateways do NOT talk to `hpr.buoy.fish` at all: each device runs an **on-device** cs-mux fanning to local `gateway-rs:1680` (Helium) + **direct** `lns.buoy.fish:1701` (ChirpStack). And the hpr box's multiplexer has **no gateway-facing GWMP listener** — its only input is MQTT (`127.0.0.1:1883` via mosquitto). D4 ("GWMP → hpr.buoy.fish ONLY") therefore requires **hpr-side work**: add a `[[gwmp.input]]` bind (the pinned mux binary supports it — just unconfigured), pick a port **≠ 1680** (UDP :1680 on the box is helium-multi-gateway bound on 0.0.0.0 — a canary pointed there would bypass the mux and reach Helium only), and open that port in the AWS security group.
2. **Downlink risk for the canary specifically.** The hpr mux's `lns.buoy.fish:1701` backend is `uplink_only = true` — PULL_RESP from ChirpStack is dropped at the mux. Today's fleet compensates with the *direct* device→lns leg, which exists precisely because Costa Rica is AS923_1 on Helium's region map while sites run US915 (gateway-rs/HPR can't TX there; joins/downlinks ride the direct path). Cutting the canary over to hpr-only as-configured would **break joins/downlinks** for a CR-region gateway. Decision needed (flagged D4 contradiction): make the lns backend downlink-capable (per-EUI or globally) on the hpr mux, or accept Helium-HPR-only downlinks where the region map allows.
3. **D6 blocker-risk: no buoy server is on the tailnet.** Verified by read-only SSH probe: the app.buoy.fish backend box (EC2 `ip-172-31-25-28`) has no tailscaled (binary absent, unit inactive, no `tailscale0`). `buoy-services/docs/ROADMAP.md:11-13` still lists "Tailscale on everything" as open. The tailnet today = the 32 balena gateways (`tag:buoy-gateway`) + admin devices. D6's log-pull design implies the **first server tailnet join** — JT decision on which box joins (app box vs pulling via another member).
4. **Phase 6 parity metric needs a different source.** A GWMP-in canary is **invisible to the lorawan-analyzer**: the mux only republishes UDP-gateway uplinks to `[[mqtt.output]]` backends, and live config has none (an mqtt.output was the 2026-04-20 deadlock trigger — re-adding one needs deliberate sign-off). Working alternatives: mux Prometheus `:9090` `gateway_udp_received_count{gateway_id}` (per-EUI, GWMP-in only) and/or ChirpStack-side gateway stats at lns (covers fleet + canary uniformly).
5. **Helium identity is at stake on any volume-destroying operation** (fleet move, reflash): `gateway_key.bin` for hotspot **wonderful-tartan-sheep** (`144zZiM1NbqE14eUBoyUg5ZpA7SnjxUTgRfLjaqK3rPRkPeu1H3`) lives only in the device's `helium-gateway-data` volume (+ ECC608 on i2c-1). Escrowed to `~/buoy/backups/gateway-3110fe6-pre-fleet-move-2026-07-28/` before the canary's fleet move. Fleet-wide: decide identity archival policy before any future migration.
6. **The gateway EUI is persisted in a volume, not re-derived.** Compose says `GATEWAY_EUI_SOURCE=chip` but the running forwarder logs `EUI Source: file` (seeded rak-config volume, `cp -vn` no-clobber). EUI `0016C001FF15E548` must be pinned explicitly in the new image or ChirpStack/HPR/multi-gateway re-registration is needed. (helium-multi-gateway auto-creates per-EUI keys — the canary keeps its Helium-side identity iff the EUI is unchanged.)
7. **Prior art exists for ~80% of Phases 1–2**: local-only branch `buoy/gateway-image` in `~/buoy/helium-gateway-balena` (tip `af5ee73`, unpushed — single-laptop copy!) + untracked `buoy-gateway-image/provisioning/` — a Compose migration incl. `first-boot.sh` that installs **host** tailscaled and provisions from a `site.json` on the boot partition. Review/reconcile before writing Phase 1 from scratch; push the branch (issue #3 housekeeping item).

## Decision-by-decision status

| Decision | Status | Notes |
|---|---|---|
| D1 RPi OS Lite + Compose | **Confirmed viable** | Bench BOM pinned (below). Host config must replicate `dtparam=spi=on,i2c_arm=on`. Prior-art branch already chose the same shape. |
| D2 pi-gen CI image | Unchallenged | Nothing found contradicting; prior-art used provisioning-files-on-boot-partition, compatible with pi-gen firstrun. |
| D3 Host tailscaled | **Confirmed, with deltas** | Today's container: `tailscale/tailscale:stable`, host netns, `TS_USERSPACE=false`, `TS_AUTH_ONCE=true`, `--ssh`, state in `tailscale-state` volume, node `3110fe6.tailfc38d6.ts.net`, tag `tag:buoy-gateway`. It is also a **management backdoor** (tailscale ssh + docker-cli + balena engine socket) — host design must deliberately replicate or drop that. Prior-art `first-boot.sh` runs `tailscale up` **without** `--advertise-tags` — must add `--advertise-tags=tag:buoy-gateway` or a tagged key join may fail/land untagged. |
| D4 GWMP → hpr only | **Contradicted as-written** | See TL;DR #1/#2: hpr mux needs a GWMP input added + SG port; downlink story for US915-in-AS923 sites must be resolved (today it's the direct-lns leg, which D4 removes). Mux downlink mechanics verified in pinned source (`d2c3a77`): per-(backend,EUI) sockets, PULL_RESP from uplink_only backends dropped, gateway return-address forgotten 60 s after last PULL_DATA (keep pull interval ≤ default 10 s). |
| D5 Registry channels | **Open Q2 answered with a default** | Org standard = **no registry at all**: build-on-the-box + pull public upstreams (balena builders for the fleet; rsync+compose-build for hpr/monitoring; self-hosted runner for buoy-lns). Zero push workflows, zero registry creds in bao. Lowest-friction registry if channels are wanted: **ghcr.io under buoy-fish** (in-workflow `GITHUB_TOKEN`, no new secrets). Zero-new-infra alternative: on-device compose build (prior-art branch's shape). Pin `rakwireless/udp-packet-forwarder` (currently `:latest`). |
| D6 Push heartbeats / pull logs | **Blocked on tailnet gap + auth-model decision** | See TL;DR #3. Also: ADR-0010's Service-Auth pattern pins ONE service token per Access app — fits one server-side caller, not N gateways pushing. Nearest in-house precedents for many-device push: `POST /api/internal/gateway-receptions` (shared-secret header, Bypass-style) and ChirpStack→`/api/payloads` (Bearer). Choose: per-gateway creds vs fleet-shared token vs Bypass+app-auth. `gateway-api.buoy.fish` is unclaimed (NXDOMAIN, zero repo hits). |
| D7 Takeover OTA | Unchallenged | Isolated test fleet `jameson1/canary-fleet-for-buoy-test-gateway` (id 2390539) exists, 0 devices. Note primary fleet **tracks latest release** — any balena push rolls all 32 devices immediately; keep canary work off that fleet's builder entirely. |

## Canary device archival snapshot (pre-move)

**`3110fe6157a5fc4e5f3f6933a681c292` "COSTA RICA INDOOR 3"** (balena ID 13599952)

- Pi 4 Model B Rev 1.1, 4 GB (rev `c03111`, serial `a463c795`); SanDisk 64 GB SD ("SD64G", mfg 2020-12); no USB peripherals; eth `DC:A6:32:3B:2B:2A`.
- HAT: **RAK2287 (SX1302, SPI, no GPS in use)** on spidev0.0/gpiochip0, reset GPIOs **25,17**, custom 2000 ms power-cycle reset script (`udp-packet-forwarder/reset_lgw_custom.sh` — port verbatim; it fixed a RAK2287 boot loop). No HAT EEPROM. Unknowable remotely: PSU rating, SD endurance class, GPS-variant of the RAK2287, carrier board, antenna — **JT eyeball at bench**.
- balenaOS 7.4.0+rev1, supervisor 17.8.2, release `afceb55…` (= repo main `488b1c8` — add-tailscale is **merged and deployed fleet-wide** since 2026-07-26; the separate branch no longer exists).
- Services: udp-packet-forwarder (privileged; env: `MODEL=RAK2287 BAND=us_902_928 SERVER_HOST=cs-mux SERVER_PORT=1700 RESET_GPIO=25,17 GATEWAY_EUI_SOURCE=chip …`), cs-mux (→ `gateway-rs:1680` + `lns.buoy.fish:1701`, both downlink-capable), gateway-rs (US915 override, ECC608 on i2c-1, key volume), rak-config-seed, tailscale (v1.98.9, IP 100.109.249.66).
- Gateway EUI **`0016C001FF15E548`** (from file in rak-config volume). Helium hotspot **wonderful-tartan-sheep**.
- Fleet env: single var `TS_AUTHKEY` (reusable pre-auth, `tag:buoy-gateway`, plaintext in balena, present in every container's env on all 32 devices — rotate once host-tailscaled lands). Device config vars: stock Pi4 + `dtparam=i2c_arm=on,spi=on`.
- Note: device rebooted ~2026-07-28T01:08Z unprompted (before discovery started) — probably site power; glance before using as baseline.

## Answers to the plan's Open Questions

1. **Bench hardware:** Pi 4B r1.1 4GB + RAK2287 (SX1302) — pinned above; PSU/SD-class/GPS-variant need eyeballs. Field-slot question still JT's.
2. **Registry:** org standard is registry-free build-where-you-run; ghcr.io is the informed default if D5 channel tags want a registry. (JT confirm.)
3. **Primary app:** `buoy-fish/app.buoy.fish` — Elixir/Phoenix (`cargo_elixir`) + React 18 SPA, Platform-Admin gateway views exist (AdminGatewaysTab / GatewayRowDrawer / telemetry via `monitoring-api.buoy.fish/analyzer`, ADR-0010 pattern, CF service-token headers server-side). Backend host: EC2 `ip-172-31-25-28` (`ssh ubuntu@app.buoy.fish`), deploys via GH Actions → SSH on push to main. **NOT on the tailnet** (verified) — D6 dependency, JT decision. Also: laptop checkout of app.buoy.fish sits on `feat/359-data-panel-blocks` with uncommitted changes — implement from `origin/main`, don't touch that worktree state.
4. **Tailnet:** tag convention `tag:buoy-gateway`; console-managed (no ACL-as-code); key = reusable pre-auth, ≤90-day life, minted by hand in the admin console ~07-18 (**expiry ~mid-October** — canary flashing after that needs a re-mint), at-rest copies: balena fleet var + 1P Machine-vault item "gateway tailscale key" (bao stash checklist item NOT done). **No Tailscale API-minting wired anywhere** → Phase 2's per-flash key minting is a NEW mint = **Tier 2 escalation** (or JT hand-mints per key). Issue #3's SSH-ACL item unverifiable from here — JT confirm in admin console.
5. **`gateway-api.buoy.fish`:** name is free (NXDOMAIN + zero repo hits). But settle the many-callers auth model (D6 row above) before minting anything.

## Corrections to standing notes (memory/CLAUDE.md)

- CLAUDE.md's "hpr docker-compose comment still says console.buoy.fish" is itself stale — fixed in hpr PR #3 (`0264397`); compose now correctly says `lns.buoy.fish:1701`.
- Memory describing `add-tailscale` as an unmerged branch is stale — merged to main `488b1c8`, deployed fleet-wide 2026-07-26.
- The ":1680 cutover" refers to the **internal** hop on the hpr box (helium-multi-gateway's GWMP listener), not a gateway-facing port.

## Tier-2 items to batch for one JT escalation session (none executed)

- Tailscale API minting wiring (OAuth client or API key → bao) for `flash.sh` pre-auth keys — or JT hand-mints per flash.
- `secret/helium-gateway-balena/*` (or `secret/buoy-gateway/*`) bao path creation incl. stashing the TS key copy (issue #3 item).
- Phase 4: CF service token mint + `gateway-api.buoy.fish` Access app + bao policy (pending the auth-model decision).
- Proper escrow home for `gateway_key.bin` (wallet-adjacent; currently local backup only).

## Immediate JT decisions needed before Phase 1

1. **D4 downlink resolution** (TL;DR #2): how does the hpr mux serve ChirpStack downlinks to the canary — flip lns backend off `uplink_only`, per-EUI routing, or accept the constraint?
2. **GWMP input port** on hpr (≠1680) + AWS SG change — hpr-side change, small but touches shared prod infra.
3. **Tailnet server join** for D6 (which box, when).
4. **Heartbeat auth model** for gateway-api (per-gateway vs fleet token vs Bypass+app-auth).
5. Registry: ghcr.io vs registry-free build-on-device.
6. Confirm the Phase-6 parity metric (mux :9090 per-EUI counters and/or ChirpStack stats) given the analyzer gap.

---

# Addendum — 2026-07-28 live verification (5-agent workflow, prod boxes + bench)

## A1. hpr mux, verified on the box — and a production downlink black hole

Live config confirmed byte-identical to the repo template: **mqtt.input only** (no `[[gwmp.input]]`), **no `[[mqtt.output]]`**, `lns.buoy.fish:1701` **`uplink_only = true` and enforced at runtime**. But the mux sends PULL_DATA keepalives to *all* GWMP outputs with no uplink_only filter (pinned `d2c3a77`, `forwarder.rs:635` + relay path `:314-322`), so ChirpStack's console bridge believes the direct route is downlink-capable and uses it:

- Since 06-30: **1,933 PULL_RESPs from ChirpStack dropped at the mux (~43% of all downlink attempts arriving at hpr)**; the 2,583 delivered downlinks ALL rode the Helium/multi-gateway leg.
- Console-side 48h sample: the four MQTT-via-hpr gateway IDs received **114 downlinks with zero acks** (`f1383e4b` 42/0, `f138417e` 33/0, `f1399e45` 23/0, `f13845af` 16/0), each drop correlated sub-millisecond with an hpr "Dropping downlink … uplink-only" warning. Every direct-GWMP (balena) and Helium-ID gateway acks 100%.
- **Join-accepts are among the dropped frames**: devices `f09c75bb`/`f09c765a` re-join every 1–2 h, succeeding only when ChirpStack's dedup roulette routes the accept via Helium or a direct gateway.
- This also **rewrites part of the TX-Ack investigation**: the silent zero-ack downlink modes on 1383E4B/417E/45AF/399E45 are the mux drop, not gateway hardware (TOO_EARLY NACK floods remain a separate, real time-base issue).
- **Fleet-wide fix candidate (independent of the canary): patch the mux to suppress PULL_DATA on uplink_only outputs** so ChirpStack never selects the dead route.

Downlink routing today = dedup roulette across three source classes seen at :1701: hpr mux relay (black hole), Helium HPR infra (works, random session IDs), direct-GWMP balena gateways from field ISP IPs (work, real `0016c001ff*` EUIs — this "direct class" IS the balena fleet, incl. the canary pre-move at 17/16 acks).

## A2. Decision direction: canary publishes MQTT (amends D4) — pending JT final confirm

JT proposal (sidebar), endorsed by this evidence: instead of adding `gwmp.input` to the prod mux, the canary runs the same shape as the proven MQTT population — **one upstream: MQTT over TCP to `hpr.buoy.fish:1883`**. Zero prod changes, analyzer visibility for free (analyzer reads the broker; gateways publish directly — confirmed live), proven downlink path (mux → `command/down` topic). The `gwmp.input`+`mqtt.output` alternative is dead: an `mqtt.output` on the same broker as the `mqtt.input` creates uplink AND downlink echo loops, duplicates uplinks into HPR/LNS unboundedly, and misregisters GWMP gateways as MQTT-in (breaking their downlink path). (Also: the 2026-04-20 "mqtt.output deadlock" was actually an RwLock re-entrancy bug, fixed at the pinned ref — the mqtt.output was circumstantially blamed.)

Candidate stacks: **(a)** RAK udp-packet-forwarder → local `chirpstack-gateway-bridge` (semtech_udp on 127.0.0.1) → MQTT; **(b) target:** `chirpstack-concentratord-sx1302` (`model="rak_2287"`, v4.7.1, arm64 tarball, containerize ourselves) + `chirpstack-mqtt-forwarder` (concentratord has NO native MQTT — ZeroMQ API only; gateway ID always read from SX1302 silicon, matching the hardware-EUI goal). Canary config: topic prefix `us915_1`, protobuf payloads, broker user `gateway` (shared password; per-gateway creds/TLS = later hardening).

## A3. Canary bench: chip EUI confirmed

One-off probe on the (idle, canary-fleet) device: **chip EUI = `0016C001FF15E548` — identical to the persisted file EUI**; concentrator fully started with the **stock** reset path (GPIO 25 then 17 via libgpiod). The custom 2000 ms power-cycle reset script was NOT needed (its power-cycle branch is dead code under `POWER_EN_GPIO=0`); keep it in the escrow as fallback only. Cleanup verified (probe container removed, staged script deleted; pulled image kept).

## A4. app.buoy.fish tailnet prep: done, awaiting a key from JT

`tailscale 1.98.9` installed from the official apt repo and enabled on the app box — **NOT authed** (that needs a pre-auth key only JT can mint; `tag:buoy-gateway` is the only existing tag, so an untagged server node or a new `tag:buoy-server` + admin-console tagOwners entry is JT's call). Join command when ready:
`sudo tailscale up --auth-key=<KEY> --hostname=app-buoy-fish --accept-dns=false --accept-routes=false`
Verified unaffected: `buoy_fish` + nginx active, site returns 200; main routing table and resolv.conf untouched. Corrections/flags: the box is **Ubuntu 24.04 (noble)**, not 22.04 as older notes said; a kernel reboot (6.17.0-1017 → 1019) is pending from unattended-upgrades — JT to schedule.

## A5. Prod hygiene finds (non-blocking)

- `mosquitto-exporter` on hpr is in a permanent auth-failure loop (~5s retries, no creds configured) — floods the broker log (gateway connect history rotates away in hours) and its $SYS metrics are presumably absent.
- Mux container log retention is ~11 h at current volume; forensics must use the `:9090` Prometheus counters (already scraped by monitoring).
- Fifth EUI `0016c001f139a5eb` has retained `state/conn` but no traffic — dormant or dead? (JT.)
- Stale retained `state/conn` under `us915_0/` and uppercase `US915_1/` for `f13845af` — phantom gateways to wildcard subscribers.
- `helium-multi-gateway` binds UDP `0.0.0.0:1680`; exposure depends entirely on SG `hpr-bridge-sg` (unreadable from the box) — worth an `aws ec2 describe-security-groups` check from a credentialed session.
- ChirpStack's `gateway` table is empty (disk91 fork runs unregistered gateways) — gateway liveness lives in bridge `state/conn` topics, not the DB.

## JT rulings — 2026-07-28 (all four inputs closed)

1. **D4 amendment CONFIRMED**: canary publishes MQTT to `hpr.buoy.fish:1883`; target stack concentratord + chirpstack-mqtt-forwarder, RAK-forwarder + gateway-bridge as fallback. Bench spike running same day (concentratord containers on the canary itself).
2. **app.buoy.fish is ON the tailnet**: `app-buoy-fish` = `100.73.73.98`, untagged (JT will tag later if a tag becomes necessary); key stored at `op://n7zqudnwyk4wj6asredzjjdlqu/tailscale keys/buoy-server-key`; app-box→gateway reachability verified (ping to a live gateway OK; note pings ride Starlink RTTs, 100–300 ms). Pending on that box (unrelated): kernel reboot from unattended-upgrades; OS is Ubuntu 24.04 (noble), correct older 22.04 notes.
3. **Mux PULL_DATA-suppression patch DEFERRED.** JT hypothesis to test before any change: the LNS may not inform Helium HPR when a Join-Accept is delivered LNS→gateway directly, so routing JAs through HPR might be load-bearing for Helium-side state — i.e. the "black hole" may be partially deliberate. Revisit + design a test later; leave prod as-is.
4. Dormant EUI `f139a5eb` = gateway got unplugged; ignore. (Remaining minor items — hpr SG audit, mosquitto-exporter auth loop, stale retained topics — stay on the backlog, no urgency.)

Housekeeping done same day: `buoy/gateway-image` branch pushed to `jtbuffmire/helium-gateway-balena` (single-laptop-copy risk closed; branch is Phase 1–2 prior art, KNOWN to have crashed the Pi last time — foundation + debugging, not trusted code).

## Bench spike result — 2026-07-28: concentratord stack VALIDATED (canary live as MQTT gateway)

- **Stack:** `chirpstack-concentratord-sx1302` **4.7.1** + `chirpstack-mqtt-forwarder` **4.6.0** (arm64 tarballs from artifacts.chirpstack.io; glibc-dynamic, run on `debian:bookworm-slim`). Two containers built on-device, ZMQ ipc over shared named volume `canary-ipc`, both `--restart unless-stopped` — **left running**; configs at `/mnt/data/canary/config/` (broker password chmod 600, never echoed anywhere).
- **Reset: the `model="rak_2287"` preset (gpiochip0 pin 17) started the concentrator on the first attempt.** No pin-25 override, no custom reset script — supersedes the earlier stock-probe expectation for the concentratord path. Image build should use the preset with no overrides.
- **Identity:** gateway ID read from SX1302 silicon = `0016c001ff15e548` (as predicted). Channel plan replicated from the escrowed `global_conf.json` (US915 sub-band 2) — startup log confirms bit-identical channels.
- **Verified on the hpr broker** (95 s watch): retained `state/conn` online, `event/stats` on a clean 30 s cadence, ~19 `event/up` from **4 live devices in bench radio range**, and **two `command/down` → `event/ack` round-trips** — the mux re-pointed downlinks to the canary within seconds and the gateway ACKed them. The **analyzer auto-upserted** the gateway (first_seen 05:02:26Z; `name: null` — assign an alias when naming canaries).
- Notes: forwarder logs one cosmetic `MQTT error: Timeout` on first connect (recovers in ~3 s — don't alarm on singles); `time_fallback_enabled=true` (system time, no GNSS) — pick a fleet convention; helium-multi-gateway will have auto-minted a Helium key for this EUI (glance at the next `helium` check); radio-1 center freq differs cosmetically (905.3 vs 905.0) with identical resulting channels.
- **Consequence: soak/parity data starts accumulating now** — the canary is a full member of the proven MQTT population (analyzer-visible, downlink-capable via the Helium leg) before the new OS image even exists. Phase 1's image build now has an exact, hardware-validated compose payload to bake in.
