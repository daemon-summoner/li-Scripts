#!/usr/bin/env bash
# tests/wslconfig.sh - checks the .wslconfig edit made by setup/modules/wsl.sh against fixture files. Needs no
# Windows, WSL or Docker.
#   tests/wslconfig.sh
# --- end usage ---
set -Eeuo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ROOT="$(dirname "$HERE")"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/platform.sh
source "$ROOT/lib/platform.sh"
# shellcheck source=setup/modules/wsl.sh
source "$ROOT/setup/modules/wsl.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export LI_OS=wsl
export LI_WSLCONFIG="$work/.wslconfig"
out=""

# apply_as MODULE CONTENT: seed the fixture with CONTENT (printf %b escapes), run MODULE, keep its output in $out.
apply_as() {
	printf '%b' "$2" >"$LI_WSLCONFIG"
	out="$("$1" 2>&1)" || {
		printf '%s\n' "$out" >&2
		fail "$1 failed on a fixture"
	}
}
apply() { apply_as mod_wsl_config "$1"; }

# apply_mem RAM_MIB CONTENT: like apply, for mod_wsl_memory on a PC that reports RAM_MIB of RAM.
apply_mem() {
	LI_WSL_HOST_RAM_MIB="$1" apply_as mod_wsl_memory "$2"
}

# expect_file NAME EXPECTED: the fixture must equal EXPECTED byte for byte (printf %b escapes).
expect_file() {
	printf '%b' "$2" >"$work/expected"
	cmp -s "$work/expected" "$LI_WSLCONFIG" || {
		diff "$work/expected" "$LI_WSLCONFIG" >&2 || true
		fail "$1"
	}
	pass "$1"
}

# expect_out NAME TEXT: the module's output must mention TEXT.
expect_out() {
	[[ "$out" == *"$2"* ]] || {
		printf '%s\n' "$out" >&2
		fail "$1 (output lacks: $2)"
	}
}

rm -f "$LI_WSLCONFIG"
out="$(mod_wsl_config 2>&1)"
expect_file "missing file is created with the setting" '[experimental]\nautoMemoryReclaim=gradual\n'
expect_out "missing file: tells the operator to restart WSL" "wsl --shutdown"

apply '[wsl2]\nmemory=48GB\nprocessors=8\n'
expect_file "other sections are kept and [experimental] is appended" \
	'[wsl2]\nmemory=48GB\nprocessors=8\n\n[experimental]\nautoMemoryReclaim=gradual\n'

apply '[experimental]\nsparseVhd=true\n'
expect_file "an existing [experimental] section gains the key once" \
	'[experimental]\nautoMemoryReclaim=gradual\nsparseVhd=true\n'

apply '[experimental]\nautoMemoryReclaim=gradual\n'
expect_file "an already-applied setting leaves the file untouched" '[experimental]\nautoMemoryReclaim=gradual\n'
expect_out "already applied: says so" "already sets"

apply '[experimental]\nautoMemoryReclaim=dropcache\n'
expect_file "a different operator value is not overwritten" '[experimental]\nautoMemoryReclaim=dropcache\n'
expect_out "different value: says it left it alone" "leaving that value alone"

apply '[wsl2]\nautoMemoryReclaim=disabled\n'
expect_file "the same key in another section does not count" \
	'[wsl2]\nautoMemoryReclaim=disabled\n\n[experimental]\nautoMemoryReclaim=gradual\n'

apply '[experimental]\n# autoMemoryReclaim=disabled\n'
expect_file "a commented-out key does not count" \
	'[experimental]\nautoMemoryReclaim=gradual\n# autoMemoryReclaim=disabled\n'

apply '[wsl2]\r\nmemory=48GB\r\n'
expect_file "CRLF files keep CRLF on every line" \
	'[wsl2]\r\nmemory=48GB\r\n\r\n[experimental]\r\nautoMemoryReclaim=gradual\r\n'
apply '[experimental]\r\nsparseVhd=true\r\n'
expect_file "CRLF is kept when the key goes into an existing section" \
	'[experimental]\r\nautoMemoryReclaim=gradual\r\nsparseVhd=true\r\n'

apply '[wsl2]\r\nmemory=48GB\r\n'
cp "$LI_WSLCONFIG" "$work/after-first"
out="$(mod_wsl_config 2>&1)"
cmp -s "$work/after-first" "$LI_WSLCONFIG" || fail "a CRLF file is not edited again on the second run"
pass "a second run on the CRLF result changes nothing"

apply '[Experimental]\nAUTOMEMORYRECLAIM=gradual\n'
expect_file "section and key names match without case" '[Experimental]\nAUTOMEMORYRECLAIM=gradual\n'
expect_out "case-insensitive match: says already applied" "already sets"

rm -f "$LI_WSLCONFIG"
if (LI_OS=linux mod_wsl_config) >/dev/null 2>&1; then
	fail "mod_wsl_config ran outside WSL"
fi
[[ ! -e "$LI_WSLCONFIG" ]] || fail "mod_wsl_config wrote a file outside WSL"
pass "refuses to run outside WSL and writes nothing"

# --- memory sizing: half the PC's RAM, at most 32GB ---------------------------
# expect_gb RAM_MIB GB: wsl_memory_gb must turn RAM_MIB into GB.
expect_gb() {
	local got
	got="$(wsl_memory_gb "$1")"
	[[ "$got" == "$2" ]] || fail "half of $1 MiB should be ${2}GB, got ${got}GB"
	pass "half of $1 MiB is ${2}GB"
}
expect_gb 8192 4
expect_gb 12288 6
expect_gb 16286 8 # a "16 GB" PC reports about 15.9 GiB
expect_gb 32586 16
expect_gb 65228 32 # a "64 GB" PC: half is 31.8, which rounds up to the cap
expect_gb 96696 32 # this PC: 94.4 GiB, half is 47, capped
expect_gb 131072 32

for bad in abc 0 "" -5 512; do
	if (wsl_memory_gb "$bad") >/dev/null 2>&1; then
		fail "wsl_memory_gb accepted '$bad'"
	fi
done
pass "unusable RAM figures are refused"

rm -f "$LI_WSLCONFIG"
out="$(LI_WSL_HOST_RAM_MIB=131072 mod_wsl_memory 2>&1)"
expect_file "missing file is created with the capped memory" '[wsl2]\nmemory=32GB\n'
expect_out "missing file: tells the operator to restart WSL" "wsl --shutdown"
expect_out "missing file: shows how the size was chosen" "PC RAM is 128.0 GiB; half, capped at 32GB, is 32GB"

apply_mem 32586 '[wsl2]\nprocessors=8\n'
expect_file "memory goes into an existing [wsl2] section" '[wsl2]\nmemory=16GB\nprocessors=8\n'

apply_mem 32586 '[experimental]\nautoMemoryReclaim=gradual\n'
expect_file "[wsl2] is appended and other sections are kept" \
	'[experimental]\nautoMemoryReclaim=gradual\n\n[wsl2]\nmemory=16GB\n'

apply_mem 32586 '[wsl2]\nmemory=48GB\n'
expect_file "an operator memory value is not overwritten" '[wsl2]\nmemory=48GB\n'
expect_out "different memory: says it left it alone" "leaving that value alone"

apply_mem 32586 '[wsl2]\nmemory=16GB\n'
expect_file "an already-applied memory leaves the file untouched" '[wsl2]\nmemory=16GB\n'
expect_out "memory already applied: says so" "already sets"

apply_mem 32586 '[experimental]\nmemory=1GB\n'
expect_file "memory in another section does not count" '[experimental]\nmemory=1GB\n\n[wsl2]\nmemory=16GB\n'

apply_mem 32586 '[wsl2]\n# memory=64GB\n'
expect_file "a commented-out memory does not count" '[wsl2]\nmemory=16GB\n# memory=64GB\n'

apply_mem 32586 '[wsl2]\r\nprocessors=8\r\n'
expect_file "CRLF is kept when memory goes into an existing section" '[wsl2]\r\nmemory=16GB\r\nprocessors=8\r\n'

apply_mem 32586 '[WSL2]\nMemory=16GB\n'
expect_file "section and key names match without case for memory" '[WSL2]\nMemory=16GB\n'
expect_out "memory case-insensitive match: says already applied" "already sets"

printf '%b' '[wsl2]\nprocessors=8\n' >"$LI_WSLCONFIG"
if (LI_WSL_HOST_RAM_MIB=abc mod_wsl_memory) >/dev/null 2>&1; then
	fail "mod_wsl_memory accepted an unusable RAM figure"
fi
expect_file "an unusable RAM figure leaves the file untouched" '[wsl2]\nprocessors=8\n'

if (LI_OS=linux LI_WSL_HOST_RAM_MIB=32586 mod_wsl_memory) >/dev/null 2>&1; then
	fail "mod_wsl_memory ran outside WSL"
fi
expect_file "mod_wsl_memory writes nothing outside WSL" '[wsl2]\nprocessors=8\n'

# Without the override the PC's RAM comes from powershell.exe; a stand-in on PATH plays Windows.
mkdir "$work/bin"
printf '#!/bin/sh\nprintf "34359738368\\r\\n"\n' >"$work/bin/powershell.exe"
chmod +x "$work/bin/powershell.exe"
printf '%b' '[wsl2]\nprocessors=8\n' >"$LI_WSLCONFIG"
out="$(
	unset LI_WSL_HOST_RAM_MIB
	PATH="$work/bin:$PATH" mod_wsl_memory 2>&1
)"
expect_file "the PC's RAM is read from powershell.exe" '[wsl2]\nmemory=16GB\nprocessors=8\n'
expect_out "powershell.exe answer: shows the PC's RAM" "PC RAM is 32.0 GiB"

printf '#!/bin/sh\necho "Access is denied"\n' >"$work/bin/powershell.exe"
printf '%b' '[wsl2]\nprocessors=8\n' >"$LI_WSLCONFIG"
if (
	unset LI_WSL_HOST_RAM_MIB
	PATH="$work/bin:$PATH" mod_wsl_memory
) >/dev/null 2>&1; then
	fail "mod_wsl_memory accepted a non-numeric answer from powershell.exe"
fi
expect_file "a non-numeric powershell.exe answer leaves the file untouched" '[wsl2]\nprocessors=8\n'

echo "all wslconfig checks passed"
