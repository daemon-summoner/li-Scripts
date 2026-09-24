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
# --- end usage ---
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
	IFS= read -r ans || die "input ended; setup aborted, re-run ./setup.sh to continue"
	[[ -z "$ans" ]] && ans="$def"
	printf -v "$__var" '%s' "$ans"
}

ask_secret() { # ask_secret VAR "prompt" [keep-if-empty]
	local __var="$1" prompt="$2" keep="${3:-}" ans
	printf '    %s%s: ' "$prompt" "${keep:+ (enter to keep current)}"
	IFS= read -rs ans || die "input ended; setup aborted, re-run ./setup.sh to continue"
	printf '\n'
	[[ -z "$ans" ]] && ans="$keep"
	printf -v "$__var" '%s' "$ans"
}

# Takes the key either way, deciding on the first line so there is only one
# prompt: a pasted PEM block (collected up to its END line, so no Ctrl-D) or a
# path to the downloaded .pem. Returns the key in VAR; the caller writes it out.
# Never echoes it back, and never puts it on a command line where /proc would
# expose it to every user on the box.
ask_key() { # ask_key VAR
	local __var="$1" line body="" lines=0 src
	info 'Private key (step 8): paste the whole PEM block, or give a path to the .pem'
	printf '    '
	IFS= read -r line || die "input ended; setup aborted, re-run ./setup.sh to continue"
	line="${line%$'\r'}"

	if [[ "$line" == *"-----BEGIN "*"PRIVATE KEY-----"* ]]; then
		body="$line"
		while [[ "$line" != *"-----END "*"PRIVATE KEY-----"* ]]; do
			IFS= read -r line ||
				die "input ended before the key's END line; setup aborted, re-run ./setup.sh to continue"
			line="${line%$'\r'}"
			# A paste that never terminates would otherwise read forever. A 4096-bit
			# key is about 51 lines.
			if ((++lines > 200)); then
				warn "no END line after 200 lines; that does not look like a PEM key"
				return 1
			fi
			body+=$'\n'"$line"
		done
	else
		src="${line/#\~/$(invoker_home)}"
		[[ -n "$src" ]] || {
			warn "nothing entered"
			return 1
		}
		[[ -r "$src" ]] || {
			warn "cannot read: $src"
			hint "paste the key contents instead, or scp the .pem here first"
			return 1
		}
		body="$(cat "$src")"
	fi

	printf '%s\n' "$body" | openssl pkey -noout 2>/dev/null || {
		warn "that is not a usable private key (openssl could not read it)"
		hint "GitHub's file starts with: -----BEGIN RSA PRIVATE KEY-----"
		return 1
	}
	printf -v "$__var" '%s' "$body"
}

ask_yn() { # ask_yn "prompt" [y|n]
	local prompt="$1" def="${2:-y}" ans h
	[[ "$def" == y ]] && h="Y/n" || h="y/N"
	while :; do
		printf '    %s [%s]: ' "$prompt" "$h"
		IFS= read -r ans || die "input ended; setup aborted, re-run ./setup.sh to continue"
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
		IFS= read -r ans || die "input ended; setup aborted, re-run ./setup.sh to continue"
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

# Home of the user who ran sudo, for expanding a pasted ~/path. Under sudo
# $HOME is root's.
invoker_home() {
	local h=""
	if [[ -n "${SUDO_USER:-}" ]]; then
		h="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
	fi
	printf '%s' "${h:-$HOME}"
}

# Effective value of KEY after config.env, the host profile, local.env and
# the built-in defaults; empty when the config is absent.
cfg_get() {
	[[ -r "$CONFIG" ]] || return 0
	"$GHA" config "$1"
}

# Atomic in-place edits through gha-vm.sh, which quotes values, keeps owner
# and mode, and comments out duplicate live keys.
cfg_set() { "$GHA" config-set "$1" "$2" "$CONFIG"; }
cfg_unset() { "$GHA" config-unset "$1" "$CONFIG"; }
cfg_set_in() { "$GHA" config-set "$2" "$3" "$1"; }

# ------------------------------------------------------------------ main ----

usage() {
	sed -n '3,/^# --- end usage ---$/{/^# --- end usage ---$/!p}' "$(readlink -f "$0")" | sed 's/^# \{0,1\}//'
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

# Everything below leans on /proc, KVM, apt, nftables and systemd. Refuse
# before the sudo re-exec so a laptop never gets as far as a password prompt.
[[ "$(uname -s)" == Linux ]] || die "gha-vm runs only on a Linux (Ubuntu) host with KVM; this is $(uname -s). Run setup.sh on the server, not on your workstation."

if [[ $EUID -ne 0 ]]; then
	command -v sudo >/dev/null 2>&1 || die "run this as root"
	# `sudo env VAR=...` rather than `sudo -E`: env_reset drops the override on
	# a default sudoers policy, and -E is refused outright on many of them.
	exec sudo env GHA_CONFIG="$CONFIG" "$0" "$@"
fi

[[ -x "$GHA" ]] || die "gha-vm.sh not found next to this script ($GHA)"

# A pipe or a cron job has nobody to answer prompts. -y takes the scripted
# path; without it, stopping here beats blocking forever on the first read.
if ((NONINTERACTIVE)); then
	exec "$GHA" bootstrap ${SLOTS:+"$SLOTS"}
fi
[[ -t 0 ]] || die "stdin is not a terminal; use -y for non-interactive setup"

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

# ask/ask_choice/ask_secret/ask_key assign through `printf -v`, which static
# analysis cannot follow; declaring the targets here keeps that visible.
scope=""
org=""
repo=""
mode=""
appid=""
keypem=""
keep_key=0
pat=""
cpus=""
mem=""
disk=""
mem1=""
pct=""

cur_scope="$(cfg_get SCOPE)"
cur_org="$(cfg_get GITHUB_ORG)"
cur_repo="$(cfg_get GITHUB_REPO)"
cur_mode="$(cfg_get AUTH_MODE)"
cur_appid="$(cfg_get GITHUB_APP_ID)"
cur_pat="$(cfg_get GITHUB_PAT)"
cur_key="$(cfg_get GITHUB_APP_KEY)"
cur_key="${cur_key:-$CONFIG_DIR/app.pem}"
server_url="$(cfg_get GITHUB_SERVER_URL)"
server_url="${server_url:-https://github.com}"

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
	[[ -n "$cur_repo" ]] && cfg_unset GITHUB_REPO
else
	while :; do
		ask repo "Repository (owner/name)" "$cur_repo"
		[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] && break
		warn "expected owner/name"
	done
	cfg_set SCOPE repo
	cfg_set GITHUB_REPO "$repo"
	[[ -n "$cur_org" ]] && cfg_unset GITHUB_ORG
fi

printf '\n'
hint "A GitHub App is the safer option: its token lasts an hour and is scoped to"
hint "one permission. A PAT is a long-lived credential sitting in a file."
ask_choice mode "Auth mode" "${cur_mode:-app}" app pat

if [[ "$mode" == app ]]; then
	# The two JIT-runner endpoints need different permissions; naming the wrong
	# one here is the most common way this setup fails at the first job.
	if [[ "$scope" == org ]]; then
		app_new="$server_url/organizations/$org/settings/apps/new"
		app_list="$server_url/organizations/$org/settings/apps"
		app_perm='Organization permissions > "Self-hosted runners" > Read and write'
		app_where="the $org organization"
	else
		app_new="$server_url/settings/apps/new"
		app_list="$server_url/settings/apps"
		app_perm='Repository permissions > "Administration" > Read and write'
		app_where="the $repo repository"
	fi

	printf '\n'
	info "Create the app on ${server_url#https://} (about two minutes):"
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
	info "  8. Generate a private key -> a .pem downloads. Open it and copy the"
	info "     whole block; you paste it below (a file path also works)."
	info "  9. Install App (left sidebar) -> install it on $app_where."
	printf '\n'
	hint "  existing apps: $app_list"
	printf '\n'

	while :; do
		ask appid "App ID (step 7)" "$cur_appid"
		[[ "$appid" =~ ^[0-9]+$ ]] && break
		warn "the App ID is numeric -- not the Client ID (Iv1...), not the name"
	done

	# A readable PEM on disk is not evidence that it belongs to THIS app. Rotating
	# to a new app leaves the old key in place, still valid-looking and completely
	# useless -- every token mint then 404s with the app installed and nothing
	# obviously wrong. A changed App ID proves the mismatch, so replace by default
	# there; otherwise keep by default, so pressing enter through changes nothing.
	keep_key=0
	if [[ -r "$cur_key" ]] && grep -q 'PRIVATE KEY' "$cur_key" 2>/dev/null; then
		if [[ -n "$cur_appid" && "$appid" != "$cur_appid" ]]; then
			warn "the App ID changed ($cur_appid -> $appid), so the key at $cur_key"
			warn "belongs to the old app and cannot authenticate as the new one."
			ask_yn "Replace the private key?" y || keep_key=1
		else
			good "private key already installed at $cur_key"
			ask_yn "Keep it?" y && keep_key=1
		fi
	fi

	if ((keep_key)); then
		keypath="$cur_key"
	else
		keypath="$CONFIG_DIR/app.pem"
		gha_group="$(cfg_get GHA_USER)"
		gha_group="${gha_group:-gha}"
		getent group "$gha_group" >/dev/null ||
			die "group '$gha_group' does not exist; run host setup (step 1) first"

		keypem=""
		until ask_key keypem; do :; done

		# Create it empty at its final owner and mode first: writing then chmod'ing
		# would leave the key world-readable for the moment in between. The
		# supervisor runs as this group and has to read it.
		install -o root -g "$gha_group" -m 0640 /dev/null "$keypath" ||
			die "could not create $keypath"
		printf '%s\n' "$keypem" >"$keypath" ||
			die "could not write the key to $keypath"
		unset keypem
		good "key installed at $keypath (root:$gha_group, 0640)"
	fi
	cfg_set AUTH_MODE app
	cfg_set GITHUB_APP_ID "$appid"
	cfg_set GITHUB_APP_KEY "$keypath"
	# A PAT left behind would be a live credential nothing uses.
	[[ -n "$cur_pat" ]] && cfg_unset GITHUB_PAT
else
	warn "a PAT is stored in plain text in $CONFIG and does not expire on its own."
	printf '\n'
	info "Create a classic token at:"
	hint "  $server_url/settings/tokens/new"
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
	"$GHA" config-set GITHUB_PAT - "$CONFIG" <<<"$pat"
fi
good "credentials written to $CONFIG"

# --- 3. sizing -------------------------------------------------------------

step "3/6  VM size per slot"

# Sizing answers go to local.env, the per-host override that is sourced after
# config.env and the shipped profile, so they take effect on a machine with a
# profile and survive `deps` refreshing the profiles.
prof_name="$(cfg_get HOST_PROFILE)"
prof_file="$(cfg_get PROFILE_FILE)"
sizing_file="$(cfg_get LOCAL_FILE)"
[[ -n "$sizing_file" ]] || die "gha-vm.sh config LOCAL_FILE returned nothing; is $GHA current?"
if [[ -n "$prof_file" ]]; then
	info "This host matches profile '$prof_name' ($prof_file)."
fi
hint "  Answers below are written to $sizing_file, which overrides both."
if [[ ! -e "$sizing_file" ]]; then
	gha_group="$(cfg_get GHA_USER)"
	install -d -o root -g "${gha_group:-gha}" -m 0750 "$(dirname "$sizing_file")"
	printf '# Per-host overrides written by setup.sh; sourced after the profile.\n' |
		install -o root -g "${gha_group:-gha}" -m 0640 /dev/stdin "$sizing_file" ||
		die "could not create $sizing_file"
fi

cur_cpus="$(cfg_get VM_CPUS)"
cur_mem="$(cfg_get VM_MEM)"
cur_disk="$(cfg_get VM_DISK)"
hint "One slot = one VM = one concurrent job. These are per-slot, not totals."
while :; do
	ask cpus "vCPUs per job" "${cur_cpus:-4}"
	[[ "$cpus" =~ ^[1-9][0-9]*$ ]] && break
	warn "a positive whole number, e.g. 4"
done
while :; do
	ask mem "Memory per job (e.g. 8G)" "${cur_mem:-8G}"
	[[ "$mem" =~ ^[0-9]+[MGmg]?$ ]] && ((10#${mem%[MGmg]} > 0)) && break
	warn "a size like 8G or 8192M"
done
while :; do
	ask disk "Max disk per job (e.g. 80G, thin-provisioned)" "${cur_disk:-80G}"
	[[ "$disk" =~ ^[0-9]+[MGTmgt]$ ]] && break
	warn "a size with a unit, like 80G"
done
cfg_set_in "$sizing_file" VM_CPUS "$cpus"
cfg_set_in "$sizing_file" VM_MEM "$mem"
cfg_set_in "$sizing_file" VM_DISK "$disk"

cur_mem1="$(cfg_get VM_MEM_1)"
cur_pct="$(cfg_get MEM_OVERCOMMIT_PCT)"
hint "Slot 1 can be a bigger VM for heavy jobs; workflows reach it with"
hint "runs-on: [self-hosted, large]. 'none' makes it the same as the others."
while :; do
	ask mem1 "Memory for slot 1" "${cur_mem1:-none}"
	[[ "$mem1" == none ]] && break
	[[ "$mem1" =~ ^[0-9]+[MGmg]?$ ]] && ((10#${mem1%[MGmg]} > 0)) && break
	warn "a size like 16G, or none"
done
if [[ "$mem1" == none ]]; then
	"$GHA" config-unset VM_MEM_1 "$sizing_file"
	"$GHA" config-unset RUNNER_LABELS_EXTRA_1 "$sizing_file"
else
	cfg_set_in "$sizing_file" VM_MEM_1 "$mem1"
	cfg_set_in "$sizing_file" RUNNER_LABELS_EXTRA_1 "$(cfg_get RUNNER_LABELS_EXTRA_1 | grep . || echo large)"
fi
hint "All VMs share one memory budget. At 100% the slot count is what fits with"
hint "every VM at full size; above it, extra slots wait until the VMs' real use"
hint "leaves room, which is most of the time since jobs rarely peak together."
while :; do
	ask pct "Memory overcommit %" "${cur_pct:-100}"
	[[ "$pct" =~ ^[1-9][0-9]*$ ]] && break
	warn "a whole percent, e.g. 100 or 200"
done
cfg_set_in "$sizing_file" MEM_OVERCOMMIT_PCT "$pct"

# --- 4. image --------------------------------------------------------------

step "4/6  Golden image"
golden="$(cfg_get GOLDEN)"
golden="${golden:-/var/lib/gha-vm/golden.qcow2}"
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
info "Blocks jobs from reaching this host's own services and addresses, your"
info "LAN, the cloud metadata address and other non-routable ranges. DNS stays"
info "open, and NET_ALLOW_CIDRS in $CONFIG punches holes for a LAN mirror."
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

active_before="$(systemctl list-units --no-legend --state=active 'gha-vm@*.service' 2>/dev/null | wc -l)"
"$GHA" install "$SLOTS" || die "install failed"

# Running supervisors keep the old unit and script until restarted, and an
# idle runner never finishes a job to pick them up on its own.
if ((active_before > 0)); then
	printf '\n'
	info "$active_before slot(s) were already running the previous version."
	if ask_yn "Restart them now? (idle slots at once, busy ones after their job)" y; then
		"$GHA" restart all || die "restart failed; see: journalctl -u 'gha-vm@*'"
	else
		warn "they stay on the old version until: sudo gha-vm restart all"
	fi
fi

# --- done ------------------------------------------------------------------

printf '\n%s==> Done%s\n' "$c_g" "$c_0"
good "$SLOTS slots enabled; they start automatically after a reboot"
printf '\n'
info "watch jobs      journalctl -fu 'gha-vm@*'"
info "check state     gha-vm status"
info "resize fleet    sudo gha-vm install <n>"
info "pause a slot    sudo gha-vm drain <n>   (undrain to resume)"
info "roll back       sudo gha-vm rollback   (previous golden image)"
info "remove          sudo gha-vm uninstall"
printf '\n'
hint "Runners appear under the $scope's Actions > Runners settings within a minute."
hint "Target them with:  runs-on: [self-hosted, linux, $(cfg_get RUNNER_ARCH)]"
printf '\n'
