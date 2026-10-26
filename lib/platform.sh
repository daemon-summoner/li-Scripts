#!/usr/bin/env bash
# lib/platform.sh - OS/arch detection and a package-install abstraction.
# Source after common.sh. Provides: detect_os, detect_arch, require_os,
# is_wsl, pkg_update, pkg_install, pkg_installed.

[[ -n "${_LI_PLATFORM_SOURCED:-}" ]] && return 0
_LI_PLATFORM_SOURCED=1
[[ -n "${_LI_COMMON_SOURCED:-}" ]] || {
	echo "platform.sh requires common.sh to be sourced first" >&2
	return 1
}

# detect_os -> echoes one of: macos, wsl, linux. Cached in LI_OS.
detect_os() {
	if [[ -n "${LI_OS:-}" ]]; then
		printf '%s' "$LI_OS"
		return 0
	fi
	local os
	case "$(uname -s)" in
	Darwin) os=macos ;;
	Linux)
		# WSL exposes "microsoft" in the kernel string; it is a Linux that
		# needs a few Windows-interop quirks handled separately.
		if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
			os=wsl
		else
			os=linux
		fi
		;;
	*) os="$(uname -s)" ;;
	esac
	LI_OS="$os"
	printf '%s' "$os"
}

is_wsl() { [[ "$(detect_os)" == wsl ]]; }

# detect_arch -> normalized arch: x64 or arm64. Cached in LI_ARCH.
detect_arch() {
	if [[ -n "${LI_ARCH:-}" ]]; then
		printf '%s' "$LI_ARCH"
		return 0
	fi
	local arch
	case "$(uname -m)" in
	x86_64 | amd64) arch=x64 ;;
	aarch64 | arm64) arch=arm64 ;;
	*) arch="$(uname -m)" ;;
	esac
	LI_ARCH="$arch"
	printf '%s' "$arch"
}

# require_os macos|linux|wsl ... : die unless the current OS is one of them.
# "linux" matches plain linux and wsl; name "wsl" explicitly to require WSL.
require_os() {
	local cur want
	cur="$(detect_os)"
	for want in "$@"; do
		[[ "$cur" == "$want" ]] && return 0
		[[ "$want" == linux && "$cur" == wsl ]] && return 0
	done
	die "this runs only on: $*; detected '$cur'"
}

# --- package manager abstraction ----------------------------------------------
# One surface over apt (Debian/Ubuntu) and Homebrew (macOS). pkg_install treats
# a whole list as one transaction and reports, never aborting the whole run on a
# single package; callers decide what a miss means.

pkg_update() {
	case "$(detect_os)" in
	macos)
		need brew "install Homebrew: https://brew.sh"
		best_effort brew update
		;;
	linux | wsl)
		require_root "package updates"
		export DEBIAN_FRONTEND=noninteractive
		best_effort apt-get update
		;;
	esac
}

# pkg_installed NAME -> 0 if installed.
pkg_installed() {
	case "$(detect_os)" in
	macos) brew list --formula "$1" >/dev/null 2>&1 || brew list --cask "$1" >/dev/null 2>&1 ;;
	linux | wsl) dpkg -l "$1" 2>/dev/null | grep -q '^ii' ;;
	esac
}

# pkg_install PKG...: install the given packages idempotently.
pkg_install() {
	(($#)) || return 0
	case "$(detect_os)" in
	macos)
		need brew "install Homebrew: https://brew.sh"
		local p
		for p in "$@"; do
			if pkg_installed "$p"; then
				hint "already installed: $p"
			else
				best_effort brew install "$p"
			fi
		done
		;;
	linux | wsl)
		require_root "package installs"
		export DEBIAN_FRONTEND=noninteractive
		best_effort apt-get install -y -o Dpkg::Options::=--force-confold "$@"
		;;
	esac
}
