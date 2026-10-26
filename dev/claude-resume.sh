#!/usr/bin/env bash
# claude-resume.sh - resume the last Claude Code session, skipping permission prompts.
#   claude-resume.sh [extra claude args...]
# --- end usage ---
set -Eeuo pipefail
[[ "${1:-}" == -h || "${1:-}" == --help ]] && {
	sed -n '3,/^# --- end usage ---$/{/^# --- end usage ---$/!p}' "$0" | sed 's/^# \{0,1\}//'
	exit 0
}
command -v claude >/dev/null 2>&1 || {
	echo "claude CLI not found on PATH" >&2
	exit 1
}
exec claude --resume --dangerously-skip-permissions "$@"
