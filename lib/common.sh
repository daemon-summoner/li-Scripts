#!/usr/bin/env bash
# lib/common.sh - shared helpers for li-Scripts.
# Source it, never execute it:  source "$LIB_DIR/common.sh"
# Provides: colors, log/die/need/warn, usage sentinel, confirm, append_once,
# install_atomic, retry, best_effort, require_root. Safe under set -euo pipefail.

# Guard against double-sourcing (modules source each other).
[[ -n "${_LI_COMMON_SOURCED:-}" ]] && return 0
_LI_COMMON_SOURCED=1

# --- colors -------------------------------------------------------------------
# Gated on a real terminal with >=8 colors; every var is pre-set empty so
# `set -u` is safe when output is piped or redirected.
c_b="" c_d="" c_r="" c_g="" c_y="" c_c="" c_m="" c_0=""
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && (($(tput colors 2>/dev/null || echo 0) >= 8)); then
	c_b="$(tput bold)"
	c_d="$(tput dim)"
	c_r="$(tput setaf 1)"
	c_g="$(tput setaf 2)"
	c_y="$(tput setaf 3)"
	# shellcheck disable=SC2034  # palette vars for sourcing scripts
	c_c="$(tput setaf 6)"
	# shellcheck disable=SC2034
	c_m="$(tput setaf 5)"
	c_0="$(tput sgr0)"
fi

# --- logging ------------------------------------------------------------------
# step = bold section header, info = indented body, hint = dim aside,
# good = green, warn = yellow (non-fatal), log = timestamped to stderr.
step() { printf '\n%s==> %s%s\n' "$c_b" "$*" "$c_0"; }
info() { printf '    %s\n' "$*"; }
hint() { printf '    %s%s%s\n' "$c_d" "$*" "$c_0"; }
good() { printf '    %s%s%s\n' "$c_g" "$*" "$c_0"; }
warn() { printf '    %sWARN: %s%s\n' "$c_y" "$*" "$c_0" >&2; }
log() { printf '%s[%s] %s%s\n' "$c_d" "$(date '+%H:%M:%S')" "$*" "$c_0" >&2; }

# die: red message to stderr, exit 1. Messages name the remedy: die "x (try: y)".
die() {
	printf '\n%sERROR: %s%s\n' "$c_r" "$*" "$c_0" >&2
	exit 1
}

# need: assert a command exists, or die naming what is missing.
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1${2:+ ($2)}"; }

# --- usage --------------------------------------------------------------------
# Help lives in the caller's own header comment, between line 3 and the
# `# --- end usage ---` sentinel. One source of truth; -h cannot drift.
usage() {
	# awk (not sed) so it is identical on GNU and BSD/macOS. Prints lines from
	# line 3 to the sentinel, stripping a leading "# " from each.
	awk 'NR>=3 { if ($0=="# --- end usage ---") exit; sub(/^# ?/,""); print }' \
		"$(readlink -f "${BASH_SOURCE[1]:-$0}")"
	exit "${1:-0}"
}

# --- prompts ------------------------------------------------------------------
# confirm "question" [default y|n] -> returns 0 for yes. Non-interactive stdin
# falls back to the default rather than hanging.
confirm() {
	local prompt="$1" def="${2:-n}" ans suffix
	[[ "$def" == y ]] && suffix="[Y/n]" || suffix="[y/N]"
	if [[ ! -t 0 ]]; then
		[[ "$def" == y ]]
		return
	fi
	printf '    %s %s ' "$prompt" "$suffix"
	IFS= read -r ans || ans=""
	[[ -z "$ans" ]] && ans="$def"
	[[ "$ans" =~ ^[Yy] ]]
}

# ask VAR "prompt" [default] -> reads a value into VAR, defaulting on empty.
ask() {
	local __var="$1" prompt="$2" def="${3:-}" ans
	if [[ -n "$def" ]]; then
		printf '    %s [%s%s%s]: ' "$prompt" "$c_b" "$def" "$c_0"
	else
		printf '    %s: ' "$prompt"
	fi
	IFS= read -r ans || die "input ended; aborted"
	[[ -z "$ans" ]] && ans="$def"
	printf -v "$__var" '%s' "$ans"
}

# --- filesystem ---------------------------------------------------------------
# append_once FILE LINE: add LINE to FILE only if an exact match is absent.
append_once() {
	local file="$1" line="$2"
	[[ -f "$file" ]] || : >"$file"
	grep -qxF -- "$line" "$file" 2>/dev/null || printf '%s\n' "$line" >>"$file"
}

# install_atomic MODE SRC DST: copy through a same-dir temp file + rename, so a
# reader never sees a half-written target.
install_atomic() {
	local mode="$1" src="$2" dst="$3" tmp
	tmp="$(mktemp "$dst.XXXXXX")" || die "cannot create temp file next to $dst"
	if ! install -m "$mode" "$src" "$tmp"; then
		rm -f "$tmp"
		die "could not copy $src to $dst"
	fi
	mv -f "$tmp" "$dst"
}

# --- control flow -------------------------------------------------------------
# retry N CMD...: run CMD up to N times with linear backoff. Dies if all fail.
retry() {
	local attempts="$1" i=0 delay=2
	shift
	until "$@"; do
		i=$((i + 1))
		((i >= attempts)) && die "command failed after $attempts attempts: $*"
		warn "attempt $i/$attempts failed, retrying in ${delay}s: $*"
		sleep "$delay"
		delay=$((delay + 2))
	done
}

# best_effort CMD...: run CMD without letting a failure abort the script under
# set -e. Logs a warning instead. Use only where a failure is genuinely optional.
best_effort() {
	"$@" || warn "non-fatal: command failed: $*"
}

# require_root: assert EUID 0, or die naming the action. require_root "install"
require_root() {
	[[ $EUID -eq 0 ]] || die "${1:-this command} must run as root (try: sudo ...)"
}

# --- config -------------------------------------------------------------------
# LI_ROOT is the repo root (lib/ lives directly under it). LI_CONFIG_DIR and the
# config file are overridable so tests can point them at a fixture tree.
LI_ROOT="${LI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# li_load_config: source config/config.env if present; otherwise fall back to
# config.env.example so a fresh clone still works. Sets LI_CONFIG_IS_EXAMPLE=1
# when only the example was available (the signal that these are not the
# operator's own values, so we never push personal data like an SSH key onto a
# machine from the shipped sample). Values use `: "${VAR:=default}"`, so an
# environment variable set before the call always wins over the file.
li_load_config() {
	local dir="${LI_CONFIG_DIR:-$LI_ROOT/config}"
	# shellcheck disable=SC2034  # consumed by sourcing scripts
	LI_CONFIG_FILE="$dir/config.env"
	# shellcheck disable=SC2034
	LI_CONFIG_IS_EXAMPLE=""
	if [[ -r "$LI_CONFIG_FILE" ]]; then
		# shellcheck disable=SC1090
		source "$LI_CONFIG_FILE"
	elif [[ -r "$dir/config.env.example" ]]; then
		# shellcheck disable=SC1090
		source "$dir/config.env.example"
		# shellcheck disable=SC2034
		LI_CONFIG_IS_EXAMPLE=1
	fi
}

# li_seed_config: on first run, create config/config.env from the example and
# let the operator edit it, so their values persist and stop tracking the
# sample. No-op when a live config already exists.
li_seed_config() {
	local dir="${LI_CONFIG_DIR:-$LI_ROOT/config}"
	[[ -r "$dir/config.env" ]] && return 0
	[[ -r "$dir/config.env.example" ]] || return 0
	install_atomic 0600 "$dir/config.env.example" "$dir/config.env"
	good "Created $dir/config.env from the sample."
	hint "Edit it to set your own git identity, keys and hosts."
}
