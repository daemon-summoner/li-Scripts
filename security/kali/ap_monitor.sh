#!/usr/bin/env bash
# ap_monitor.sh - capture traffic for one BSSID to MonitorDump (research/demo, authorized use only).
# Interface defaults to wlan0mon; override with the WIFI_MON env var.
#   ap_monitor.sh BSSID
# --- end usage ---
set -uo pipefail
[[ "${1:-}" == -h || "${1:-}" == --help ]] && {
	sed -n '3,/^# --- end usage ---$/{/^# --- end usage ---$/!p}' "$0" | sed 's/^# \{0,1\}//'
	exit 0
}
if [ $# -ne 1 ]; then
	echo "Error: pass the target BSSID (router MAC) as the only argument" >&2
	exit 1
fi
sudo airodump-ng --bssid "$1" --band a --write MonitorDump "${WIFI_MON:-wlan0mon}"
