#!/usr/bin/env bash
# swap-resize.sh - resize the Linux swapfile at /swapfile.
# SIZE is anything fallocate understands, e.g. 8G or 2048M. Path overridable
# with LI_SWAPFILE.
#   swap-resize.sh SIZE          e.g. swap-resize.sh 16G
# --- end usage ---
set -Eeuo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
LIB_DIR="$(cd "$HERE/../lib" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/platform.sh
source "$LIB_DIR/platform.sh"

[[ "${1:-}" == -h || "${1:-}" == --help ]] && usage 0
[[ $# -ge 1 ]] || usage 1
[[ "$1" =~ ^[0-9]+[KMGTkmgt]?$ ]] || die "SIZE must be like 16G or 2048M (got '$1')"
require_os linux
require_root "swap-resize"

swapfile="${LI_SWAPFILE:-/swapfile}"
step "Resizing $swapfile to $1"
swapoff "$swapfile" 2>/dev/null || true
rm -f "$swapfile"
fallocate -l "$1" "$swapfile"
chmod 600 "$swapfile"
mkswap "$swapfile"
swapon "$swapfile"
good "Swap is now $1 at $swapfile"
