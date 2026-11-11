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

# apply CONTENT: seed the fixture with CONTENT (printf %b escapes), run the module, keep its output in $out.
apply() {
	printf '%b' "$1" >"$LI_WSLCONFIG"
	out="$(mod_wsl_config 2>&1)" || {
		printf '%s\n' "$out" >&2
		fail "mod_wsl_config failed on a fixture"
	}
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

echo "all wslconfig checks passed"
