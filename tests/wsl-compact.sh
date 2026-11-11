#!/usr/bin/env bash
# tests/wsl-compact.sh - checks system/wsl-compact.sh with stand-ins for the Windows tools. Needs no Windows or WSL.
#   tests/wsl-compact.sh
# --- end usage ---
set -Eeuo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ROOT="$(dirname "$HERE")"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"
# shellcheck source=system/wsl-compact.sh
source "$ROOT/system/wsl-compact.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export LI_OS=wsl WSL_DISTRO_NAME=Fixture
CALLS="$work/calls"
FIXTURE_VHD="$work/ext4.vhdx"
truncate -s 20G "$FIXTURE_VHD"
GIB=1073741824
LOOKUP_OUT=$'\\\\?\\D:\\wsl\\fixture\\\r\next4.vhdx\r\n'
LOOKUP_RC=0
LAUNCH_RC=0
FAKE_USED=$((5 * GIB))
WANT_VHD='D:\wsl\fixture\ext4.vhdx'

# The only things replaced are the Windows executables and the filesystem numbers; the script under test runs as is.
powershell.exe() {
	if [[ "$*" == *Start-Process* ]]; then
		printf '%s\n' "$*" >>"$CALLS"
		return "$LAUNCH_RC"
	fi
	printf '%s' "$LOOKUP_OUT"
	return "$LOOKUP_RC"
}
wslpath() { printf '%s' "$FIXTURE_VHD"; }
df() { printf 'Used\n%s\n' "$FAKE_USED"; }

launches() { wc -l <"$CALLS" | tr -d ' '; }
expect_in() {
	[[ "$2" == *"$3"* ]] || {
		printf '%s\n' "$2" >&2
		fail "$1 (lacks: $3)"
	}
}
# run_main ARGS...: run main without a terminal; sets $out and $rc.
run_main() {
	rc=0
	out="$(main "$@" </dev/null 2>&1)" || rc=$?
}

: >"$CALLS"

# --- the registry lookup ------------------------------------------------------
[[ "$(vhd_windows_path Fixture)" == "$WANT_VHD" ]] || fail "extended-length prefix and trailing backslash are not trimmed"
pass "lookup trims the \\\\?\\ prefix and the trailing backslash"

LOOKUP_OUT=$'C:\\Users\\me\\LocalState\r\n'
[[ "$(vhd_windows_path Fixture)" == 'C:\Users\me\LocalState\ext4.vhdx' ]] || fail "missing VhdFileName does not default to ext4.vhdx"
pass "lookup defaults the file name to ext4.vhdx"

LOOKUP_OUT=$'\\\\?\\D:\\wsl\\fixture\\\r\next4.vhdx\r\n'
LOOKUP_RC=3
if (vhd_windows_path Ghost) >/dev/null 2>&1; then
	fail "an unregistered distro was accepted"
fi
LOOKUP_RC=0
pass "lookup fails for an unregistered distro"

if (WSL_DISTRO_NAME="bad'; calc" distro_name) >/dev/null 2>&1; then
	fail "a distro name with a quote reached the PowerShell string"
fi
pass "distro names with shell or PowerShell punctuation are refused"

# --- the elevated script ------------------------------------------------------
script="$(compact_script "D:\\wsl\\O'Brien\\ext4.vhdx")"
expect_in "single quote in the path is doubled for PowerShell" "$script" "\$vhd = 'D:\\wsl\\O''Brien\\ext4.vhdx'"
shutdown_line="$(grep -n 'wsl.exe --shutdown' <<<"$script" | head -1 | cut -d: -f1)"
attach_line="$(grep -n 'attach vdisk readonly' <<<"$script" | head -1 | cut -d: -f1)"
((shutdown_line < attach_line)) || fail "the disk is attached before WSL is stopped"
pass "WSL is stopped before the disk is attached"
finally_line="$(grep -n 'finally' <<<"$script" | head -1 | cut -d: -f1)"
detach_line="$(grep -n 'detach vdisk' <<<"$script" | head -1 | cut -d: -f1)"
((finally_line < detach_line)) || fail "detach is not in the finally block"
pass "the disk is detached in a finally block, so a failed compact never leaves it attached"

# --- --print ------------------------------------------------------------------
run_main --print
((rc == 0)) || fail "--print failed: $out"
expect_in "--print shows the Windows size" "$out" "20.0 GiB"
expect_in "--print shows the Linux usage" "$out" "5.0 GiB"
expect_in "--print shows the reclaimable amount" "$out" "15.0 GiB"
expect_in "--print shows the manual compact" "$out" "compact vdisk"
expect_in "--print names the disk" "$out" "select vdisk file=\"$WANT_VHD\""
[[ "$(launches)" == 0 ]] || fail "--print started the elevated compact"
run_main --print --yes
((rc == 0)) || fail "--print --yes failed: $out"
[[ "$(launches)" == 0 ]] || fail "--yes overrode --print and started the elevated compact"
pass "--print reports sizes and steps and starts nothing, even with --yes"

# --- confirmation -------------------------------------------------------------
run_main
((rc == 0)) || fail "a declined prompt should not be an error: $out"
expect_in "declining says nothing was stopped" "$out" "nothing was stopped"
[[ "$(launches)" == 0 ]] || fail "the compact started without a confirmation"
pass "without a yes the compact does not start"

# --- --yes --------------------------------------------------------------------
run_main --yes
((rc == 0)) || fail "--yes failed: $out"
[[ "$(launches)" == 1 ]] || fail "--yes should start the elevated compact exactly once"
payload="$(grep -o "'-EncodedCommand','[^']*'" "$CALLS" | cut -d"'" -f4 | base64 -d | iconv -f UTF-16LE -t UTF-8)"
[[ "$payload" == "$(compact_script "$WANT_VHD")" ]] || fail "the elevated payload is not the compact script for $WANT_VHD"
grep -q -- '-Verb RunAs' "$CALLS" || fail "the compact is not started elevated"
pass "--yes starts one elevated PowerShell carrying the compact script"

# --- failure and edge cases ---------------------------------------------------
: >"$CALLS"
LAUNCH_RC=1
run_main --yes
((rc != 0)) || fail "a declined Windows prompt reported success"
expect_in "a failed launch falls back to the manual steps" "$out" "compact vdisk"
LAUNCH_RC=0
pass "a declined Windows prompt is an error and prints the manual steps"

: >"$CALLS"
FAKE_USED=$((20 * GIB - GIB / 2))
run_main --yes
((rc == 0)) || fail "a full disk should not be an error: $out"
expect_in "nothing to gain is reported" "$out" "Nothing worth compacting"
[[ "$(launches)" == 0 ]] || fail "WSL was stopped to reclaim under 1 GiB"
FAKE_USED=$((5 * GIB))
pass "under 1 GiB to gain, WSL is left running even with --yes"

LI_OS=linux
run_main --yes
((rc != 0)) || fail "ran outside WSL"
[[ "$(launches)" == 0 ]] || fail "started a compact outside WSL"
LI_OS=wsl
pass "refuses to run outside WSL"

run_main --bogus
((rc != 0)) || fail "an unknown flag was accepted"
pass "unknown arguments are rejected"

echo "all wsl-compact checks passed"
