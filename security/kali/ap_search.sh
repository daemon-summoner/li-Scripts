#!/usr/bin/env bash
# ap_search.sh - scan for 5 GHz access points (research/demo, authorized use only).
# Interface defaults to wlan0mon; override with the WIFI_MON env var.
#   ap_search.sh
# --- end usage ---
set -uo pipefail
[[ "${1:-}" == -h || "${1:-}" == --help ]] && {
	sed -n '3,/^# --- end usage ---$/{/^# --- end usage ---$/!p}' "$0" | sed 's/^# \{0,1\}//'
	exit 0
}
sudo airodump-ng --band a "${WIFI_MON:-wlan0mon}"
