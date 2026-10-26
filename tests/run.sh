#!/usr/bin/env bash
# tests/run.sh - lint and check every script in li-Scripts.
# Runs `bash -n` on all shell scripts, then `shellcheck -x` on the active tree
# (archive/ and dev/gha-runner/ are excluded: legacy kept as-is, and gha-runner
# ships its own suite at dev/gha-runner/tests/run.sh). Degrades loudly when a
# tool is missing.
#   tests/run.sh            run everything available
# --- end usage ---
set -Eeuo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ROOT="$(dirname "$HERE")"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"
cd "$ROOT"

# Collect shell scripts: *.sh plus the extensionless `li` dispatcher and setup.sh.
# Plain read loop (not mapfile) so this harness runs on the bash 3.2 that ships
# as /bin/bash on macOS.
all_scripts=()
while IFS= read -r f; do all_scripts+=("$f"); done < <(
	find . -type f \( -name '*.sh' -o -name 'li' \) \
		-not -path './.git/*' -not -path './*/.ruff_cache/*' | sort
)

# bash -n on everything, including archive and gha-runner.
syntax_bad=0
for f in "${all_scripts[@]}"; do
	# Only parse files that are actually bash.
	head -1 "$f" | grep -qE 'bash|^#!/bin/sh' || continue
	bash -n "$f" || {
		printf 'FAIL: bash -n %s\n' "$f" >&2
		syntax_bad=1
	}
done
((syntax_bad == 0)) || fail "syntax errors above"
pass "bash -n (${#all_scripts[@]} scripts)"

# Static analysis (shellcheck) on the active tree only.
if command -v shellcheck >/dev/null 2>&1; then
	active=()
	while IFS= read -r f; do active+=("$f"); done < <(
		printf '%s\n' "${all_scripts[@]}" | grep -vE '^\./(archive|dev/gha-runner)/'
	)
	sc_bad=0
	for f in "${active[@]}"; do
		head -1 "$f" | grep -q bash || continue
		shellcheck -x -e SC1091 "$f" || sc_bad=1
	done
	((sc_bad == 0)) || fail "shellcheck findings above in the active tree"
	pass "shellcheck -x (active tree, ${#active[@]} scripts)"
else
	skip "shellcheck not installed -- lint PARTIAL (bash -n only)"
fi

# gha-runner is a self-contained subproject with its own VM/Docker suite; run it
# separately when working on it:  bash dev/gha-runner/tests/run.sh

echo "all checks passed"
