#!/bin/bash -e
install -d "${ROOTFS_DIR}/opt/buoy/config"
install -d "${ROOTFS_DIR}/etc/systemd/journald.conf.d"
install -d "${ROOTFS_DIR}/var/lib/buoy"

install -m 644 files/docker-compose.yml       "${ROOTFS_DIR}/opt/buoy/docker-compose.yml"
install -m 644 files/concentratord.toml       "${ROOTFS_DIR}/opt/buoy/config/concentratord.toml"
install -m 600 files/chirpstack-mqtt-forwarder.toml.tmpl \
	"${ROOTFS_DIR}/opt/buoy/config/chirpstack-mqtt-forwarder.toml.tmpl"
install -m 644 files/00-buoy-journald.conf    "${ROOTFS_DIR}/etc/systemd/journald.conf.d/00-buoy.conf"
install -m 644 files/buoy-firstboot.service   "${ROOTFS_DIR}/etc/systemd/system/buoy-firstboot.service"
install -m 755 files/buoy-firstboot.sh        "${ROOTFS_DIR}/usr/local/bin/buoy-firstboot.sh"

# SPI + I2C for the SX1302 concentrator HAT (mirrors the balena device config).
CONFIG_TXT="${ROOTFS_DIR}/boot/firmware/config.txt"
if ! grep -q '^# buoy-gateway' "${CONFIG_TXT}"; then
	cat files/config-txt-append.txt >> "${CONFIG_TXT}"
fi

on_chroot << EOF
systemctl enable buoy-firstboot.service
EOF
