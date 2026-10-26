#!/usr/bin/env bash
# setup/macos.sh - macOS workstation setup. Run as the operator, via setup.sh.
#
# Usage:
#   ./setup.sh [selections] [options]       (dispatches here on macOS)
#   setup/macos.sh 1                         numeric menu, same as before
#   setup/macos.sh --basic                   full developer environment
#   setup/macos.sh --vram                    only raise the GPU memory limit
#
# Selections (numeric menu, comma-separated, or the named flag):
#   1  --basic   Homebrew CLI tools, Python, Go, Node, VS Code, LunarVim,
#                Docker (Colima), git config, Wi-Fi roaming, VRAM limit
#   2  --vram    raise the Apple Silicon GPU wired-memory limit only
#
# Options:
#   --only IDS   run only these module ids (comma-separated)
#   --skip IDS   skip these module ids
#   -h, --help   show this help
# --- end usage ---
set -Eeuo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
LI_ROOT="$(dirname "$HERE")"
export LI_ROOT
# shellcheck source=lib/common.sh
source "$LI_ROOT/lib/common.sh"
# shellcheck source=lib/platform.sh
source "$LI_ROOT/lib/platform.sh"
# shellcheck source=setup/common.sh
source "$HERE/common.sh"
for m in shell cli-tools python go node editors lunarvim docker git-config macos-tweaks; do
	# shellcheck source=/dev/null
	source "$HERE/modules/$m.sh"
done

require_os macos

want_basic="" want_vram=""

_select_num() {
	case "$1" in
	1) want_basic=y ;;
	2) want_vram=y ;;
	*) warn "ignoring unknown selection: $1" ;;
	esac
}

_menu() {
	cat <<-EOF

		${c_b}li-Scripts -- macOS setup${c_0}
		Choose options, comma-separated (e.g. 1,2):

		  ${c_g}1${c_0}  Basic setup     CLI tools, Python, Go, Node, VS Code, LunarVim, Docker, git
		  ${c_g}2${c_0}  VRAM limit      raise the Apple Silicon GPU memory cap only
	EOF
	local reply IFS=, n
	ask reply "Selections"
	for n in $reply; do _select_num "${n// /}"; done
}

parse_args() {
	local got=""
	while (($#)); do
		case "$1" in
		-h | --help) usage 0 ;;
		--basic) want_basic=y got=y ;;
		--vram) want_vram=y got=y ;;
		--only) LI_ONLY="${2:?--only needs ids}" && shift ;;
		--only=*) LI_ONLY="${1#*=}" ;;
		--skip) LI_SKIP="${2:?--skip needs ids}" && shift ;;
		--skip=*) LI_SKIP="${1#*=}" ;;
		[0-9]*)
			local IFS=, n
			for n in $1; do _select_num "${n// /}"; done
			got=y
			;;
		*) die "unknown argument: $1 (try: $0 --help)" ;;
		esac
		shift
	done
	[[ -n "$got" ]] || _menu
}

parse_args "$@"
export LI_ONLY="${LI_ONLY:-}" LI_SKIP="${LI_SKIP:-}"

# From here on we are actually provisioning, so enforce the run context and load
# config (seeding a live config.env on first run). Kept after parse_args so that
# --help neither requires a non-root shell nor writes config.env as a side effect.
[[ $EUID -eq 0 ]] && die "run macOS setup as your normal user, not root (brew refuses root)"
li_load_config
li_seed_config
li_load_config

need brew "install Homebrew first: https://brew.sh"

if [[ "$want_basic" == y ]]; then
	run_mod macos-tweaks "macOS tweaks" mod_macos_tweaks
	run_mod vram "VRAM limit" mod_vram
	run_mod shell "Shell environment" mod_shell
	run_mod cli-tools "CLI tools" mod_cli_tools
	run_mod python "Python toolchain" mod_python
	run_mod go "Go toolchain" mod_go
	run_mod node "Node.js toolchain" mod_node
	run_mod editors "VS Code" mod_editors
	run_mod lunarvim "LunarVim" mod_lunarvim
	run_mod docker "Docker (Colima)" mod_docker
	run_mod git-config "Git configuration" mod_git_config
	step "Setup complete"
	hint "Open a new terminal (or 'source ~/.bashrc') to pick up the changes."
elif [[ "$want_vram" == y ]]; then
	run_mod vram "VRAM limit" mod_vram
fi
