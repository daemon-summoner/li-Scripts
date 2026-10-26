#!/usr/bin/env bash
# setup/common.sh - glue shared by setup/linux.sh and setup/macos.sh.
# Sourced after lib/common.sh and lib/platform.sh. Provides the target-user
# model (so one module body works whether it runs as root provisioning another
# user on Linux or as the operator on macOS), the module runner that honors
# --only/--skip, and the reboot prompt that replaces the old forced reboot.

[[ -n "${_LI_SETUP_COMMON_SOURCED:-}" ]] && return 0
_LI_SETUP_COMMON_SOURCED=1
[[ -n "${_LI_COMMON_SOURCED:-}" && -n "${_LI_PLATFORM_SOURCED:-}" ]] || {
	echo "setup/common.sh requires lib/common.sh and lib/platform.sh first" >&2
	return 1
}

# SETUP_DIR is setup/, SETUP_FILES the shared dotfiles/configs modules install.
SETUP_DIR="${SETUP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck disable=SC2034  # consumed by sourced modules
SETUP_FILES="$SETUP_DIR/files"

# --- target user --------------------------------------------------------------
# The Linux provisioner runs as root and sets up a named login; macOS runs as
# the operator. Modules speak only to LI_TARGET_USER / LI_TARGET_HOME and use
# as_user, so the same body serves both. Defaults to the current user.
LI_TARGET_USER="${LI_TARGET_USER:-$(id -un)}"
LI_TARGET_HOME="${LI_TARGET_HOME:-$HOME}"

# li_set_target USER: point the target at USER and resolve its home. Dies if the
# account has no home directory on disk.
li_set_target() {
	local user="$1" home
	home="$(eval echo "~$user" 2>/dev/null)" || die "cannot resolve home for '$user'"
	[[ -d "$home" ]] || die "home directory does not exist: $home (create the user first)"
	LI_TARGET_USER="$user"
	LI_TARGET_HOME="$home"
}

# as_user CMD...: run CMD as the target user. A no-op wrapper when the target is
# already the current user (macOS, or Linux run by the operator), otherwise via
# sudo -u with the target's HOME and a PATH that sees its user-local bins.
as_user() {
	if [[ "$LI_TARGET_USER" == "$(id -un)" ]]; then
		"$@"
	else
		sudo -u "$LI_TARGET_USER" \
			env "HOME=$LI_TARGET_HOME" \
			"PATH=$LI_TARGET_HOME/.local/bin:/usr/local/bin:/usr/local/go/bin:$PATH" \
			"$@"
	fi
}

# own_target PATH...: chown path(s) to the target user:group. No-op when the
# target is the current user (nothing to hand off).
own_target() {
	[[ "$LI_TARGET_USER" == "$(id -un)" ]] && return 0
	chown -R "$LI_TARGET_USER:$(id -gn "$LI_TARGET_USER")" "$@"
}

# --- module runner ------------------------------------------------------------
# LI_ONLY / LI_SKIP are comma-separated module ids from --only / --skip. A
# module runs unless it is skipped, or an --only list exists that omits it.
_in_csv() {
	local needle="$1" csv="$2" IFS=,
	local item
	for item in $csv; do [[ "$item" == "$needle" ]] && return 0; done
	return 1
}

# run_mod ID "Header" fn_name: run module ID (calling fn_name) subject to
# --only/--skip, under a section header. Returns 0 when skipped.
run_mod() {
	local id="$1" header="$2" fn="$3"
	if [[ -n "${LI_ONLY:-}" ]] && ! _in_csv "$id" "$LI_ONLY"; then
		hint "skip $id (not in --only)"
		return 0
	fi
	if [[ -n "${LI_SKIP:-}" ]] && _in_csv "$id" "$LI_SKIP"; then
		hint "skip $id (--skip)"
		return 0
	fi
	step "$header"
	"$fn"
}

# --- reboot -------------------------------------------------------------------
# The old scripts rebooted on their own after a countdown. Now a reboot only
# happens when asked: --reboot on the command line (LI_REBOOT=1), else a prompt
# that defaults to no, so an unattended run never reboots by surprise.
li_reboot_or_prompt() {
	require_os linux
	if [[ "${LI_REBOOT:-0}" == 1 ]]; then
		step "Rebooting now (--reboot)"
		reboot
		return
	fi
	if [[ "${LI_NO_REBOOT:-0}" == 1 ]]; then
		hint "Reboot skipped (--no-reboot). Reboot manually to load all changes."
		return
	fi
	if confirm "Setup done. Reboot now to load all changes?" n; then
		step "Rebooting"
		reboot
	else
		hint "Not rebooting. Reboot manually when convenient to load all changes."
	fi
}
