#!/usr/bin/env bash
# rsync-sync.sh - rsync a file or folder to a remote SYNC directory over SSH.
# Host, user, key and destination root come from config.env
# (LI_RSYNC_HOST/LI_REMOTE_USER/LI_RSYNC_KEY/LI_RSYNC_DEST), overridable by env.
#   rsync-sync.sh PATH            sync PATH to HOST:DEST/PATH
#   rsync-sync.sh -h              this help
# --- end usage ---
set -Eeuo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
LIB_DIR="$(cd "$HERE/../lib" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
li_load_config

[[ "${1:-}" == -h || "${1:-}" == --help ]] && usage 0
[[ $# -ge 1 ]] || {
	warn "no path given"
	usage 1
}

path="$1"
host="${LI_RSYNC_HOST:-}"
user="${LI_REMOTE_USER:-$USER}"
key="${LI_RSYNC_KEY:-$HOME/.ssh/id_rsa}"
dest="${LI_RSYNC_DEST:-/home/$user/SYNC}"
[[ -n "$host" ]] || die "no host set (set LI_RSYNC_HOST in config.env)"
[[ -e "$path" ]] || die "path does not exist: $path"

step "Syncing $path -> $user@$host:$dest/$path"
rsync -e "ssh -i $key" -a "$path" "$user@$host:$dest/$path"
good "Synced $path"
