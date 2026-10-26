#!/usr/bin/env bash
# ssh-keygen.sh - generate a hardened ed25519 SSH key.
#   ssh-keygen.sh [SUFFIX]        writes ~/.ssh/id_ed25519[SUFFIX]
#   ssh-keygen.sh work            writes ~/.ssh/id_ed25519work
# --- end usage ---
set -Eeuo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/../lib/common.sh"

[[ "${1:-}" == -h || "${1:-}" == --help ]] && usage 0
need ssh-keygen
suffix="${1:-}"
out="$HOME/.ssh/id_ed25519${suffix}"
step "Generating $out"
ssh-keygen -o -a 100 -t ed25519 -f "$out"
good "Key written to $out"
