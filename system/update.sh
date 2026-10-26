#!/usr/bin/env bash
# update.sh - update and upgrade all system packages.
# On Ubuntu/Debian: apt update + upgrade + dist-upgrade + autoremove + clean.
# On macOS: brew update + upgrade + cleanup.
#   update.sh            update everything
#   update.sh -h         this help
# --- end usage ---
set -Eeuo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
LIB_DIR="$(cd "$HERE/../lib" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/platform.sh
source "$LIB_DIR/platform.sh"

[[ "${1:-}" == -h || "${1:-}" == --help ]] && usage 0

case "$(detect_os)" in
macos)
	need brew "install Homebrew: https://brew.sh"
	step "Updating Homebrew"
	brew update
	step "Upgrading formulae and casks"
	brew upgrade
	step "Cleaning up"
	brew cleanup
	;;
linux | wsl)
	# apt needs root; re-exec under sudo so the script is runnable as a user.
	if [[ $EUID -ne 0 ]]; then
		need sudo
		exec sudo "$(readlink -f "$0")" "$@"
	fi
	export DEBIAN_FRONTEND=noninteractive
	step "apt update"
	apt-get update
	step "apt upgrade"
	apt-get -y upgrade
	step "apt dist-upgrade"
	apt-get -y dist-upgrade
	step "Removing unused packages"
	apt-get -y autoremove
	apt-get -y clean
	;;
*) die "unsupported OS: $(detect_os)" ;;
esac
good "System up to date."
