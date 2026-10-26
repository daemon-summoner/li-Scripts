#!/usr/bin/env bash
# wsl-to-desktop.sh - copy a file or folder to the Windows desktop from WSL.
# Handles both the OneDrive-redirected and the plain Desktop path.
#   wsl-to-desktop.sh PATH
# --- end usage ---
set -Eeuo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/../lib/common.sh"
# shellcheck source=lib/platform.sh
source "$HERE/../lib/platform.sh"

[[ "${1:-}" == -h || "${1:-}" == --help ]] && usage 0
[[ $# -ge 1 ]] || usage 1
require_os wsl
[[ -e "$1" ]] || die "path does not exist: $1"

win_user="$(cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r')"
[[ -n "$win_user" ]] || die "could not read the Windows username via cmd.exe"
desktop="/mnt/c/Users/$win_user/OneDrive/Desktop"
[[ -d "$desktop" ]] || desktop="/mnt/c/Users/$win_user/Desktop"
[[ -d "$desktop" ]] || die "no Desktop folder found at /mnt/c/Users/$win_user"

step "Copying $1 -> $desktop"
cp -r "$1" "$desktop/"
good "Copied to $desktop"
