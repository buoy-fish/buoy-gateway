#!/bin/bash -e
# Docker Engine + compose plugin from the official Docker apt repo.
# Version pin TODO (README): record what was installed into the build manifest.
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
	> /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y --no-install-recommends \
	docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable docker

install -d -m 0755 /etc/buoy
{
	echo "docker-ce=$(dpkg-query -W -f='${Version}' docker-ce)"
	echo "docker-compose-plugin=$(dpkg-query -W -f='${Version}' docker-compose-plugin)"
} >> /etc/buoy/build-manifest
