#!/usr/bin/env bash
# zero-free-space.sh - fill free disk space with zeros then delete the file, so
# a sparse/compressed disk image (KVM, backups) shrinks to actual usage.
# Target directory defaults to the current one; pass a path to choose another.
#   zero-free-space.sh [DIR]
# --- end usage ---
set -Eeuo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/../lib/common.sh"

[[ "${1:-}" == -h || "${1:-}" == --help ]] && usage 0
dir="${1:-.}"
[[ -d "$dir" ]] || die "not a directory: $dir"
zero="$dir/.zero_fill_$$"
step "Zeroing free space under $dir (this can take a while)"
# dd exits non-zero when the disk fills -- that is the expected stop condition.
dd if=/dev/zero of="$zero" bs=1M 2>/dev/null || true
sync
rm -f "$zero"
good "Done. Free space zeroed."
