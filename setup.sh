#!/usr/bin/env bash
# setup.sh - cross-platform entry point for li-Scripts setup.
# Detects the OS and hands off to setup/linux.sh (Ubuntu/Debian, run with sudo)
# or setup/macos.sh (run as your normal user). All arguments pass straight
# through; run with --help to see the per-OS selections and options.
#
# Usage:
#   ./setup.sh [selections] [options]
#   sudo ./setup.sh 1,2,3        # Linux: core + security + server
#   ./setup.sh --basic           # macOS: full developer environment
# --- end usage ---
set -Eeuo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/platform.sh
source "$HERE/lib/platform.sh"

case "$(detect_os)" in
macos) exec bash "$HERE/setup/macos.sh" "$@" ;;
linux | wsl) exec bash "$HERE/setup/linux.sh" "$@" ;;
*) die "unsupported OS: $(uname -s)" ;;
esac
