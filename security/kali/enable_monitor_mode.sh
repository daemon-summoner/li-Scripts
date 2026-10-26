#!/usr/bin/env bash
# enable_monitor_mode.sh - put wlan0 into monitor mode and raise tx power (research/demo, authorized use only).
# Adapter defaults to wlan0; override with the WIFI_DEV env var.
#   enable_monitor_mode.sh
# --- end usage ---
set -uo pipefail
[[ "${1:-}" == -h || "${1:-}" == --help ]] && {
	sed -n '3,/^# --- end usage ---$/{/^# --- end usage ---$/!p}' "$0" | sed 's/^# \{0,1\}//'
	exit 0
}
dev="${WIFI_DEV:-wlan0}"
sudo airmon-ng check kill
sudo airmon-ng start "$dev"
sudo iw reg set BO
sudo iwconfig "${dev}mon" txpower 33
