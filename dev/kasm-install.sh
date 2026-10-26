#!/usr/bin/env bash
# kasm-install.sh - download and install Kasm Workspaces.
# Version is pinned but overridable with KASM_RELEASE / KASM_URL.
#   kasm-install.sh
# --- end usage ---
set -Eeuo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/../lib/common.sh"

[[ "${1:-}" == -h || "${1:-}" == --help ]] && usage 0
need curl
need tar
release="${KASM_RELEASE:-kasm_release_1.14.0.3a7abb}"
url="${KASM_URL:-https://kasm-static-content.s3.amazonaws.com/${release}.tar.gz}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
step "Downloading $release"
curl -fsSL -o "$work/kasm.tar.gz" "$url"
step "Extracting"
tar -xf "$work/kasm.tar.gz" -C "$work"
step "Running the Kasm installer (needs sudo)"
sudo bash "$work/kasm_release/install.sh"
good "Kasm installed."
