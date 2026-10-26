#!/usr/bin/env bash
# ufw-allow.sh - allow a port from the Tailscale/CGNAT range (100.64.0.0/10).
# The range is overridable with LI_UFW_FROM.
#   ufw-allow.sh PORT             ufw allow from <range> to any port PORT
# --- end usage ---
set -Eeuo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/../lib/common.sh"

[[ "${1:-}" == -h || "${1:-}" == --help ]] && usage 0
[[ $# -ge 1 ]] || usage 1
[[ "$1" =~ ^[0-9]+$ ]] || die "port must be a number (got '$1')"
need ufw
from="${LI_UFW_FROM:-100.64.0.0/10}"
step "ufw allow from $from to any port $1"
sudo ufw allow from "$from" to any port "$1"
good "Rule added for port $1"
