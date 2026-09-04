#!/usr/bin/env bash
#
# Guided installer for the gha-vm runner fleet. Walks through host setup,
# GitHub credentials, the golden image, isolation and slot count, then leaves
# systemd units running that come back on their own after a reboot.
#
#   ./setup.sh              interactive (re-execs under sudo)
#   ./setup.sh -y [slots]   non-interactive; needs a filled-in config already
#
# Safe to re-run: every prompt defaults to what is already configured, so
# pressing enter through it changes nothing.
set -Eeuo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
GHA="$HERE/gha-vm.sh"
CONFIG="${GHA_CONFIG:-/etc/gha-vm/config.env}"
CONFIG_DIR="$(dirname "$CONFIG")"

# ------------------------------------------------------------------- ui ----

c_b=""
c_d=""
c_r=""
c_g=""
c_y=""
c_0=""
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && (($(tput colors 2>/dev/null || echo 0) >= 8)); then
	c_b="$(tput bold)"
	c_d="$(tput dim)"
	c_r="$(tput setaf 1)"
	c_g="$(tput setaf 2)"
	c_y="$(tput setaf 3)"
	c_0="$(tput sgr0)"
fi

step() { printf '\n%s==> %s%s\n' "$c_b" "$*" "$c_0"; }
info() { printf '    %s\n' "$*"; }
hint() { printf '    %s%s%s\n' "$c_d" "$*" "$c_0"; }
good() { printf '    %s%s%s\n' "$c_g" "$*" "$c_0"; }
warn() { printf '    %s%s%s\n' "$c_y" "$*" "$c_0"; }
die() {
	printf '\n%sERROR: %s%s\n' "$c_r" "$*" "$c_0" >&2
	exit 1
}

# Every prompt treats EOF as fatal. Falling back to a default there would
# silently accept choices nobody made, and a validation loop would spin.
ask() { # ask VAR "prompt" [default]
	local __var="$1" prompt="$2" def="${3:-}" ans
	if [[ -n "$def" ]]; then
		printf '    %s [%s%s%s]: ' "$prompt" "$c_b" "$def" "$c_0"
	else printf '    %s: ' "$prompt"; fi
	IFS= read -r ans || die "input ended; nothing was installed"
	[[ -z "$ans" ]] && ans="$def"
	printf -v "$__var" '%s' "$ans"
}

ask_secret() { # ask_secret VAR "prompt" [keep-if-empty]
	local __var="$1" prompt="$2" keep="${3:-}" ans
	printf '    %s%s: ' "$prompt" "${keep:+ (enter to keep current)}"
	IFS= read -rs ans || die "input ended; nothing was installed"
	printf '\n'
	[[ -z "$ans" ]] && ans="$keep"
	printf -v "$__var" '%s' "$ans"
}

ask_yn() { # ask_yn "prompt" [y|n]
	local prompt="$1" def="${2:-y}" ans h
	[[ "$def" == y ]] && h="Y/n" || h="y/N"
	while :; do
		printf '    %s [%s]: ' "$prompt" "$h"
		IFS= read -r ans || die "input ended; nothing was installed"
		case "${ans:-$def}" in
		[yY] | [yY][eE][sS]) return 0 ;;
		[nN] | [nN][oO]) return 1 ;;
		esac
	done
}

ask_choice() { # ask_choice VAR "prompt" default opt1 opt2 ...
	local __var="$1" prompt="$2" def="$3" ans
	shift 3
	while :; do
		printf '    %s (%s) [%s%s%s]: ' "$prompt" "$*" "$c_b" "$def" "$c_0"
		IFS= read -r ans || die "input ended; nothing was installed"
		ans="${ans:-$def}"
		local o
		for o in "$@"; do
			if [[ "$ans" == "$o" ]]; then
				printf -v "$__var" '%s' "$ans"
				return
			fi
		done
	done
}

# ---------------------------------------------------------------- config ----

# Current value of KEY in the config, empty if unset or the file is absent.
cfg_get() {
	[[ -r "$CONFIG" ]] || return 0
	(
		set +eu
		# shellcheck disable=SC1090
		source "$CONFIG" >/dev/null 2>&1
		printf '%s' "${!1:-}"
	)
}

# Replace the first "KEY=" or "#KEY=" line in place, else append. Rewrites
# through the original file so ownership and mode are preserved.
cfg_set() { cfg_set_in "$CONFIG" "$@"; }

# Rewrites through the original file so its owner and mode survive.
cfg_set_in() {
	local file="$1" key="$2" val="$3" tmp
	tmp="$(mktemp)"
	KEY="$key" VAL="$val" awk '
		BEGIN { k = ENVIRON["KEY"]; v = ENVIRON["VAL"]; done = 0 }
		!done && $0 ~ ("^#?" k "=") { print k "=" v; done = 1; next }
		{ print }
		END { if (!done) print k "=" v }
	' "$file" >"$tmp"
	cat "$tmp" >"$file"
	rm -f "$tmp"
}

# ------------------------------------------------------------------ main ----

usage() {
	sed -n '3,11p' "$(readlink -f "$0")" | sed 's/^# \?//'
	exit "${1:-0}"
}

NONINTERACTIVE=0
SLOTS=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	-y | --yes | --non-interactive)
		NONINTERACTIVE=1
		shift
		;;
	-h | --help) usage 0 ;;
	[0-9]*)
		SLOTS="$1"
		shift
		;;
	*)
		printf 'unknown argument: %s\n\n' "$1" >&2
		usage 1
		;;
	esac
done

if [[ $EUID -ne 0 ]]; then
	command -v sudo >/dev/null 2>&1 || die "run this as root"
	# `sudo env VAR=...` rather than `sudo -E`: env_reset drops the override on
	# a default sudoers policy, and -E is refused outright on many of them.
	exec sudo env GHA_CONFIG="$CONFIG" "$0" "$@"
fi

[[ -x "$GHA" ]] || die "gha-vm.sh not found next to this script ($GHA)"

# A pipe or a cron job has nobody to answer prompts; fall through to the
# scripted path rather than blocking forever on read.
if ((NONINTERACTIVE)) || [[ ! -t 0 ]]; then
	exec "$GHA" bootstrap ${SLOTS:+"$SLOTS"}
fi

printf '\n%sgha-vm setup%s  --  ephemeral GitHub Actions runners in throwaway KVM VMs\n' "$c_b" "$c_0"
hint "on $(hostname -s), $(nproc) cores, $(($(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 1024 / 1024))G RAM"
hint "safe to re-run; enter accepts the shown default"

# --- 1. host ---------------------------------------------------------------

step "1/6  Host dependencies"
info "KVM modules, qemu, guestfs, nftables, time sync, the gha user."
hint "Installs packages with apt. Takes a minute on a fresh server."
if ask_yn "Run host setup now?" y; then
	"$GHA" deps || die "host setup failed"
	good "host ready"
else
	info "skipped"
fi

# --- 2. github -------------------------------------------------------------

step "2/6  GitHub connection"

[[ -f "$CONFIG" ]] || die "$CONFIG missing; run host setup (step 1) first"

# ask/ask_choice/ask_secret assign through `printf -v`, which static analysis
# cannot follow; declaring the targets here keeps that visible.
scope=""
org=""
repo=""
mode=""
appid=""
src=""
pat=""
cpus=""
mem=""
disk=""

cur_scope="$(cfg_get SCOPE)"
cur_org="$(cfg_get GITHUB_ORG)"
cur_repo="$(cfg_get GITHUB_REPO)"
cur_mode="$(cfg_get AUTH_MODE)"
cur_appid="$(cfg_get GITHUB_APP_ID)"
cur_pat="$(cfg_get GITHUB_PAT)"
cur_key="$(cfg_get GITHUB_APP_KEY)"
cur_key="${cur_key:-$CONFIG_DIR/app.pem}"

hint "org scope gives one runner pool for every repo. A personal account has no"
hint "such scope -- there, pick repo, one pool per repo."
ask_choice scope "Scope" "${cur_scope:-org}" org repo

if [[ "$scope" == org ]]; then
	while :; do
		ask org "GitHub org name" "$cur_org"
		[[ "$org" =~ ^[A-Za-z0-9._-]+$ ]] && break
		warn "org names are letters, digits, dot, dash and underscore"
	done
	cfg_set SCOPE org
	cfg_set GITHUB_ORG "$org"
else
	while :; do
		ask repo "Repository (owner/name)" "$cur_repo"
		[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] && break
		warn "expected owner/name"
	done
	cfg_set SCOPE repo
	cfg_set GITHUB_REPO "$repo"
fi

printf '\n'
hint "A GitHub App is the safer option: its token lasts an hour and is scoped to"
hint "one permission. A PAT is a long-lived credential sitting in a file."
ask_choice mode "Auth mode" "${cur_mode:-app}" app pat

if [[ "$mode" == app ]]; then
	# The two JIT-runner endpoints need different permissions; naming the wrong
	# one here is the most common way this setup fails at the first job.
	if [[ "$scope" == org ]]; then
		app_new="https://github.com/organizations/$org/settings/apps/new"
		app_list="https://github.com/organizations/$org/settings/apps"
		app_perm='Organization permissions > "Self-hosted runners" > Read and write'
		app_where="the $org organization"
	else
		app_new="https://github.com/settings/apps/new"
		app_list="https://github.com/settings/apps"
		app_perm='Repository permissions > "Administration" > Read and write'
		app_where="the $repo repository"
	fi

	printf '\n'
	info "Create the app on github.com (about two minutes):"
	hint "  $app_new"
	info "  1. GitHub App name:  anything unique, e.g. gha-vm-runners"
	info "  2. Homepage URL:     required but unused -- any URL will do"
	info "  3. Webhook:          UNTICK \"Active\". This app receives nothing."
	info "  4. Permissions:      $app_perm"
	info "     Leave every other permission at \"No access\"."
	info "  5. Where can this app be installed: \"Only on this account\""
	info "  6. Create GitHub App."
	printf '\n'
	info "Then, on the app's page:"
	info "  7. Note the App ID at the top (a number, not the Client ID)."
	info "  8. Generate a private key -> a .pem downloads. You need its path below."
	info "  9. Install App (left sidebar) -> install it on $app_where."
	printf '\n'
	hint "  existing apps: $app_list"
	printf '\n'

	while :; do
		ask appid "App ID (step 7)" "$cur_appid"
		[[ "$appid" =~ ^[0-9]+$ ]] && break
		warn "the App ID is numeric -- not the Client ID (Iv1...), not the name"
	done

	if [[ -r "$cur_key" ]] && grep -q 'PRIVATE KEY' "$cur_key" 2>/dev/null; then
		good "private key already installed at $cur_key"
		keypath="$cur_key"
	else
		while :; do
			ask src "Path to the .pem private key (step 8)" ""
			[[ -r "$src" ]] || {
				warn "cannot read: $src"
				hint "if it is on your laptop: scp it here first, then give that path"
				continue
			}
			grep -q 'PRIVATE KEY' "$src" || {
				warn "that file is not a PEM private key"
				continue
			}
			break
		done
		keypath="$CONFIG_DIR/app.pem"
		gha_group="$(cfg_get GHA_USER)"
		gha_group="${gha_group:-gha}"
		getent group "$gha_group" >/dev/null ||
			die "group '$gha_group' does not exist; run host setup (step 1) first"
		if [[ "$(readlink -f "$src")" != "$(readlink -f "$keypath" 2>/dev/null)" ]]; then
			# The supervisor runs as this user and has to read the key.
			install -o root -g "$gha_group" -m 0640 "$src" "$keypath" ||
				die "could not install the key to $keypath"
		fi
		good "key installed at $keypath (root:$gha_group, 0640)"
	fi
	cfg_set AUTH_MODE app
	cfg_set GITHUB_APP_ID "$appid"
	cfg_set GITHUB_APP_KEY "$keypath"
else
	warn "a PAT is stored in plain text in $CONFIG and does not expire on its own."
	printf '\n'
	info "Create a classic token at:"
	hint "  https://github.com/settings/tokens/new"
	if [[ "$scope" == org ]]; then
		info "  Scope needed: admin:org"
		info "  If $org enforces SSO, click \"Configure SSO\" on the token"
		info "  afterwards and authorize it for $org, or every call 403s."
	else
		info "  Scope needed: repo"
	fi
	printf '\n'
	while :; do
		ask_secret pat "Personal access token" "$cur_pat"
		[[ -n "$pat" ]] && break
		warn "cannot be empty"
	done
	cfg_set AUTH_MODE pat
	cfg_set GITHUB_PAT "$pat"
fi
good "credentials written to $CONFIG"

# --- 3. sizing -------------------------------------------------------------

step "3/6  VM size per slot"

# A host profile is sourced after config.env, so it -- not config.env -- decides
# sizing on a machine that has one. Write the answers where they take effect.
prof_out="$("$GHA" profile)"
# `profile` echoes capacity after its own summary and both print a "profile"
# line; exit on the first so this reads the header, not the capacity repeat.
prof_name="$(printf '%s\n' "$prof_out" | awk '/^profile /{print $2; exit}')"
prof_file="$(printf '%s\n' "$prof_out" | awk '/^loaded from/ && $3 !~ /^\(none/ {print $3; exit}')"
sizing_file="$CONFIG"
if [[ -n "$prof_file" ]]; then
	sizing_file="$prof_file"
	info "This host matches profile '$prof_name'."
	hint "  Sizing comes from $prof_file, which overrides $CONFIG."
	hint "  Answers below are written there."
fi

cur_cpus="$(printf '%s\n' "$prof_out" | awk '/^  VM_CPUS/{print $2; exit}')"
cur_mem="$(printf '%s\n' "$prof_out" | awk '/^  VM_MEM/{print $2; exit}')"
cur_disk="$(printf '%s\n' "$prof_out" | awk '/^  VM_DISK/{print $2; exit}')"
hint "One slot = one VM = one concurrent job. These are per-slot, not totals."
ask cpus "vCPUs per job" "${cur_cpus:-4}"
ask mem "Memory per job (e.g. 8G)" "${cur_mem:-8G}"
ask disk "Max disk per job (e.g. 80G, thin-provisioned)" "${cur_disk:-80G}"
cfg_set_in "$sizing_file" VM_CPUS "$cpus"
cfg_set_in "$sizing_file" VM_MEM "$mem"
cfg_set_in "$sizing_file" VM_DISK "$disk"

# --- 4. image --------------------------------------------------------------

step "4/6  Golden image"
golden="$(cfg_get STATE_DIR)"
golden="${golden:-/var/lib/gha-vm}/golden.qcow2"
if [[ -f "$golden" ]]; then
	good "already built: $golden ($(du -h "$golden" | cut -f1))"
	if ask_yn "Rebuild it? (downloads Ubuntu, ~10 minutes)" n; then
		"$GHA" image || die "image build failed"
	fi
else
	info "Downloads and verifies the Ubuntu cloud image, installs Docker and the"
	info "runner into it. Runs once; every job boots a copy-on-write clone."
	hint "Takes about 10 minutes and a few GB of disk."
	ask_yn "Build it now?" y || die "the golden image is required; re-run when ready"
	"$GHA" image || die "image build failed"
fi

# --- 5. isolation ----------------------------------------------------------

step "5/6  Network isolation"
info "Blocks jobs from reaching this host's own services, your LAN and the"
info "cloud metadata address. DNS stays open."
"$GHA" net || die "could not apply the isolation rules"
good "isolation active and set to reload at boot"

step "Preflight"
if ! "$GHA" doctor; then
	# Most of what doctor catches here has exactly one correct answer (load the
	# module, join the kvm group, tighten a mode, install the ruleset). Fix
	# those and re-check rather than handing the operator a list of commands.
	printf '\n'
	info "Some checks failed. Repairing what can be repaired automatically..."
	"$GHA" repair || warn "repair could not complete"
	printf '\n'
	info "Re-checking:"
	if "$GHA" doctor; then
		good "all preflight checks pass now"
	else
		printf '\n'
		warn "these need you; they have no safe automatic fix."
		ask_yn "Install slots anyway?" n || die "stopped; fix the items above and re-run"
	fi
fi

# --- 6. slots --------------------------------------------------------------

step "6/6  Concurrency"
"$GHA" capacity
rec="$("$GHA" capacity | awk '/^recommended/{print $2}')"
printf '\n'
[[ -n "$SLOTS" ]] || ask SLOTS "How many concurrent jobs should this machine run?" "$rec"
if ! [[ "$SLOTS" =~ ^[0-9]+$ ]] || ((SLOTS < 1)); then
	die "slot count must be a positive number"
fi
if [[ -n "$rec" ]] && ((SLOTS > rec)); then
	warn "$SLOTS is above the recommended $rec; jobs may contend for memory."
	ask_yn "Continue with $SLOTS?" n || die "stopped"
fi

"$GHA" install "$SLOTS" || die "install failed"

# --- done ------------------------------------------------------------------

printf '\n%s==> Done%s\n' "$c_g" "$c_0"
good "$SLOTS slots enabled; they start automatically after a reboot"
printf '\n'
info "watch jobs      journalctl -fu 'gha-vm@*'"
info "check state     gha-vm status"
info "resize fleet    sudo gha-vm install <n>"
info "remove          sudo gha-vm uninstall"
printf '\n'
hint "Runners appear under the $scope's Actions > Runners settings within a minute."
hint "Target them with:  runs-on: [self-hosted, linux, x64]"
printf '\n'
