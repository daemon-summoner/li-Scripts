#!/usr/bin/env bash
# scp-helper.sh - send or receive files over scp with SSH connection reuse.
# Host, user and key default to config.env (LI_SCP_HOST/LI_REMOTE_USER/LI_SSH_KEY)
# and can be overridden per run with flags or environment variables.
#   scp-helper.sh [-u USER] [-H HOST] [-i KEY] {--send|-s|--receive|-r} SRC DST
#   scp-helper.sh -s ./file.txt /remote/path/file.txt
#   scp-helper.sh -u root -H 10.0.0.5 -r /remote/file.txt ./file.txt
# --- end usage ---
set -Eeuo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
LIB_DIR="$(cd "$HERE/../lib" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
li_load_config

remote_user="${LI_REMOTE_USER:-$USER}"
remote_host="${LI_SCP_HOST:-}"
ssh_key="${LI_SSH_KEY:-$HOME/.ssh/id_ed25519}"

args=()
while (($#)); do
	case "$1" in
	-u | --user)
		remote_user="$2"
		shift 2
		;;
	-H | --host)
		remote_host="$2"
		shift 2
		;;
	-i | --key)
		ssh_key="$2"
		shift 2
		;;
	-h | --help) usage 0 ;;
	*)
		args+=("$1")
		shift
		;;
	esac
done

((${#args[@]} >= 3)) || usage 1
[[ -n "$remote_host" ]] || die "no host set (try: -H HOST, or set LI_SCP_HOST in config.env)"

mode="${args[0]}" source="${args[1]}" dest="${args[2]}"
host="$remote_user@$remote_host"
ctrl="/tmp/scp_li_$$"
ssh_opts=(-i "$ssh_key" -o ControlMaster=auto -o "ControlPath=$ctrl" -o ControlPersist=60)
cleanup() { ssh -o "ControlPath=$ctrl" -O exit "$host" 2>/dev/null || true; }
trap cleanup EXIT

case "$mode" in
-s | --send)
	[[ -e "$source" ]] || die "local path does not exist: $source"
	step "Uploading $source -> $host:$dest"
	if [[ -d "$source" ]]; then
		scp "${ssh_opts[@]}" -r "$source" "$host:$dest"
	else
		scp "${ssh_opts[@]}" "$source" "$host:$dest"
	fi
	good "Uploaded: $source"
	;;
-r | --receive)
	# shellcheck disable=SC2029  # $source is a local value we intend to test on the remote
	local_type="$(ssh "${ssh_opts[@]}" "$host" "if [ -d '$source' ]; then echo dir; elif [ -e '$source' ]; then echo file; else echo missing; fi" 2>/dev/null || echo missing)"
	[[ "$local_type" != missing ]] || die "remote path missing or unreachable: $source"
	step "Downloading $host:$source -> $dest"
	if [[ "$local_type" == dir ]]; then
		scp "${ssh_opts[@]}" -r "$host:$source" "$dest"
	else
		scp "${ssh_opts[@]}" "$host:$source" "$dest"
	fi
	good "Downloaded to: $dest"
	;;
*) die "invalid mode '$mode' (use --send/-s or --receive/-r)" ;;
esac
