#!/bin/bash -e
# Host tailscaled (D3) — installed + enabled, NOT authed. First boot joins the
# tailnet with a flash-time pre-auth key from site.json.
curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg \
	-o /usr/share/keyrings/tailscale-archive-keyring.gpg
curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list \
	-o /etc/apt/sources.list.d/tailscale.list
apt-get update
apt-get install -y --no-install-recommends tailscale
systemctl enable tailscaled

echo "tailscale=$(dpkg-query -W -f='${Version}' tailscale)" >> /etc/buoy/build-manifest
