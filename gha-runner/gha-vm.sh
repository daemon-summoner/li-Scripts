#!/usr/bin/env bash
#
# gha-vm.sh - ephemeral GitHub Actions runners in throwaway KVM microVMs.
# Host: Ubuntu 26.04 LTS (Resolute Raccoon).
#
#   gha-vm.sh bootstrap [n]     bare server -> running slots, in order
#   gha-vm.sh deps              kvm, host packages, time sync, user, config skeleton
#   gha-vm.sh image             build the golden qcow2 (download + customize)
#   gha-vm.sh net               nftables rules isolating VMs from host and LAN
#   gha-vm.sh profile           which machine is this, and what sizing it picked
#   gha-vm.sh capacity          how many slots this host can carry
#   gha-vm.sh doctor            preflight checks
#   gha-vm.sh repair            fix the preflight items that have one right answer
#   gha-vm.sh install <count>   install scripts + systemd units for <count> slots
#   gha-vm.sh uninstall         stop and remove units
#   gha-vm.sh status            slot and runner status
#   gha-vm.sh upgrade           pin the latest runner release, rebuild the image
#   gha-vm.sh run <slot>        supervisor loop for one slot (systemd entrypoint)
#   gha-vm.sh netcheck          assert the isolation rules are loaded (ExecStartPre)
#   gha-vm.sh reap | clean      cleanup
#
# Isolation model: the boundary is the VM, not a namespace. Inside the guest the
# runner can be root, use docker, run privileged containers, whatever. An escape
# from the job lands in a disk image we delete seconds later.
#
# The GitHub credential never enters the guest. This script mints a single-use
# JIT config on the host and hands only that in via a cloud-init seed.

set -Eeuo pipefail

CONFIG="${GHA_CONFIG:-/etc/gha-vm/config.env}"
SELF="$(readlink -f "$0")"
HERE="$(dirname "$SELF")"
API="https://api.github.com"
APIV="2022-11-28"
MIN_RUNNER_VERSION="2.329.0"

# Install destinations. Overridable so the generated units and ruleset can be
# rendered into a staging tree and checked before they touch a live host.
LIBEXEC="${GHA_LIBEXEC:-/usr/local/lib/gha-vm}"
SYSTEMD_DIR="${GHA_SYSTEMD_DIR:-/etc/systemd/system}"
NFT_CONF="${GHA_NFT_CONF:-/etc/gha-vm/nftables.conf}"
NFT_MAIN="${GHA_NFT_MAIN:-/etc/nftables.conf}"
PROFILE_DIR="${GHA_PROFILE_DIR:-/etc/gha-vm/profiles}"
UNIT="$SYSTEMD_DIR/gha-vm@.service"
UPGRADE_UNIT="$SYSTEMD_DIR/gha-vm-upgrade.service"
UPGRADE_TIMER="$SYSTEMD_DIR/gha-vm-upgrade.timer"

# Guest prints this on the serial console once it is about to start the runner.
# Absence of it inside BOOT_TIMEOUT means the VM never came up; kill it rather
# than hold a slot hostage for MAX_LIFETIME.
READY_MARKER='GHA-VM: runner starting'

log() { printf '[%(%Y-%m-%dT%H:%M:%S%z)T] %s\n' -1 "$*" >&2; }
die() {
	log "ERROR: $*"
	exit 1
}
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1 (try: $SELF deps)"; }

# ---------------------------------------------------------------- config ----

apply_defaults() {
	UBUNTU_RELEASE="${UBUNTU_RELEASE:-26.04}"
	CLOUDIMG_BASE="${CLOUDIMG_BASE:-https://cloud-images.ubuntu.com/releases/${UBUNTU_RELEASE}/release}"
	CLOUDIMG_NAME="${CLOUDIMG_NAME:-ubuntu-${UBUNTU_RELEASE}-server-cloudimg-amd64.img}"

	STATE_DIR="${STATE_DIR:-/var/lib/gha-vm}"
	GOLDEN="${GOLDEN:-$STATE_DIR/golden.qcow2}"
	RUN_DIR="${RUN_DIR:-$STATE_DIR/run}"
	GHA_USER="${GHA_USER:-gha}"

	VM_CPUS="${VM_CPUS:-4}"
	VM_MEM="${VM_MEM:-8G}"
	VM_DISK="${VM_DISK:-80G}"
	VM_CPU="${VM_CPU:-host}"
	NESTED_VIRT="${NESTED_VIRT:-0}"

	MAX_LIFETIME="${MAX_LIFETIME:-21600}"
	BOOT_TIMEOUT="${BOOT_TIMEOUT:-420}"
	IDLE_TIMEOUT="${IDLE_TIMEOUT:-0}"
	MIN_FREE_GB="${MIN_FREE_GB:-20}"

	HOST_RESERVE_GB="${HOST_RESERVE_GB:-8}"
	CPU_OVERCOMMIT="${CPU_OVERCOMMIT:-2}"
	DISK_PER_SLOT_GB="${DISK_PER_SLOT_GB:-30}"

	RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,x64,vm,ephemeral,docker,$(hostname -s)}"
	RUNNER_GROUP_ID="${RUNNER_GROUP_ID:-1}"
	NAME_PREFIX="${NAME_PREFIX:-gha-$(hostname -s)}"
	ALLOW_UNVERIFIED_RUNNER="${ALLOW_UNVERIFIED_RUNNER:-0}"
	AUTO_RUNNER_VERSION="${AUTO_RUNNER_VERSION:-1}"
	SPARSIFY="${SPARSIFY:-1}"
	APT_LOCK_WAIT="${APT_LOCK_WAIT:-120}"
	APT_LOCK_TRIES="${APT_LOCK_TRIES:-5}"
	REQUIRE_ISOLATION="${REQUIRE_ISOLATION:-1}"

	# 0 = let the hardware decide. A profile sets this when the machine has a job
	# other than running CI and must not be sized to its nameplate.
	MAX_SLOTS="${MAX_SLOTS:-0}"
	AUTOTUNE="${AUTOTUNE:-1}"
	AUTOTUNE_HEADROOM_GB="${AUTOTUNE_HEADROOM_GB:-4}"
	AUTOTUNE_APPLIED=0
	HOST_PROFILE="${HOST_PROFILE:-$(hostname -s)}"
	PROFILE_FILE="${PROFILE_FILE:-}"
	autotune_reserve
}

# ---------------------------------------------------------------- profile ----

# Which machine is this? One checkout serves the whole fleet: each host picks up
# its own sizing without a per-machine edit to config.env. machine-id is tried
# first because it survives a rename; hostname is the readable fallback, and is
# what an operator normally names the file after.
detect_host_profile() {
	local id
	if [[ -n "${HOST_PROFILE:-}" ]]; then
		printf '%s' "$HOST_PROFILE"
		return
	fi
	id="$(cat /etc/machine-id 2>/dev/null || true)"
	if [[ -n "$id" && -r "$PROFILE_DIR/$id.env" ]]; then
		printf '%s' "$id"
		return
	fi
	printf '%s' "$(hostname -s)"
}

# Sourced after config.env so a profile wins over it, and before apply_defaults
# so the defaults still fill whatever neither file set.
load_profile() {
	local f
	HOST_PROFILE="$(detect_host_profile)"
	PROFILE_FILE=""
	for f in "$PROFILE_DIR/$HOST_PROFILE.env" "$PROFILE_DIR/default.env"; do
		if [[ -r "$f" ]]; then
			PROFILE_FILE="$f"
			# shellcheck disable=SC1090
			source "$f"
			return 0
		fi
	done
	return 0
}

# A box that already runs other services cannot lend the runners its whole RAM.
# Raise the reserve to cover what is resident right now, so capacity reflects
# real spare memory rather than the nameplate. Only ever raises: a profile that
# sets a bigger reserve by hand keeps it.
autotune_reserve() {
	((AUTOTUNE)) || return 0
	local total avail used want
	total=$(($(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 1024 / 1024))
	avail=$(($(awk '/^MemAvailable:/{print $2}' /proc/meminfo) / 1024 / 1024))
	used=$((total - avail))
	want=$((used + AUTOTUNE_HEADROOM_GB))
	if ((want > HOST_RESERVE_GB)); then
		HOST_RESERVE_GB="$want"
		AUTOTUNE_APPLIED=1
	fi
	return 0
}

# True when this host is itself a guest. Runner VMs then run nested, which works
# wherever /dev/kvm exists but is materially slower -- worth saying out loud
# rather than letting it look like a broken image.
host_is_virtual() {
	local v
	v="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)"
	case "$v" in
	QEMU | *VMware* | *VirtualBox* | *Xen* | *KVM* | *Bochs* | *"Microsoft Corporation"*) return 0 ;;
	esac
	command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --quiet
}

# Used by deps and capacity, which must work before the operator has written a
# config. Everything else goes through load_config and gets the hard checks.
load_config_optional() {
	if [[ -r "$CONFIG" ]]; then
		# shellcheck disable=SC1090
		source "$CONFIG"
	fi
	load_profile
	apply_defaults
}

load_config() {
	[[ -r "$CONFIG" ]] || die "config not readable: $CONFIG (try: $SELF deps)"

	local mode
	mode="$(stat -c '%a' "$CONFIG")"
	((8#$mode & 8#0022)) && die "$CONFIG is group/world writable (mode $mode); chmod 0640"
	((8#$mode & 8#0004)) && log "WARN: $CONFIG is world readable (mode $mode); it may hold a PAT"

	# shellcheck disable=SC1090
	source "$CONFIG"
	load_profile

	: "${SCOPE:?set SCOPE=org|repo}"
	: "${AUTH_MODE:?set AUTH_MODE=app|pat}"
	: "${RUNNER_VERSION:?set RUNNER_VERSION}"

	apply_defaults

	case "$SCOPE" in
	org) : "${GITHUB_ORG:?set GITHUB_ORG when SCOPE=org}" ;;
	repo)
		: "${GITHUB_REPO:?set GITHUB_REPO=owner/name when SCOPE=repo}"
		# Repo-scoped runners have no runner groups; the API only accepts 1.
		RUNNER_GROUP_ID=1
		;;
	*) die "SCOPE must be org or repo" ;;
	esac

	case "$AUTH_MODE" in
	app | pat) ;;
	*) die "AUTH_MODE must be app or pat" ;;
	esac
}

mem_to_gb() { # accepts 8G / 8192M / 8
	local v="${1^^}"
	case "$v" in
	*G) printf '%s' "${v%G}" ;;
	*M) printf '%s' "$((${v%M} / 1024))" ;;
	*) printf '%s' "$v" ;;
	esac
}

# ------------------------------------------------------------------ auth ----

_b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

_app_jwt() {
	local now hdr pl unsigned sig
	now=$(date +%s)
	hdr=$(printf '{"alg":"RS256","typ":"JWT"}' | _b64url)
	pl=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$GITHUB_APP_ID" | _b64url)
	unsigned="${hdr}.${pl}"
	sig=$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$GITHUB_APP_KEY" -binary | _b64url)
	printf '%s.%s' "$unsigned" "$sig"
}

_TOKEN=""
_TOKEN_EXP=0

auth_token() {
	if [[ "$AUTH_MODE" == pat ]]; then
		: "${GITHUB_PAT:?}"
		printf '%s' "$GITHUB_PAT"
		return
	fi

	local now
	now=$(date +%s)
	if [[ -n "$_TOKEN" && $now -lt $((_TOKEN_EXP - 300)) ]]; then
		printf '%s' "$_TOKEN"
		return
	fi

	: "${GITHUB_APP_ID:?}" "${GITHUB_APP_KEY:?}"
	[[ -r "$GITHUB_APP_KEY" ]] || die "cannot read app key: $GITHUB_APP_KEY"

	local jwt inst_url inst_id perms resp
	jwt="$(_app_jwt)"
	# The two JIT-runner endpoints want different permissions, and asking for one
	# the installation does not hold is a 422 rather than a smaller token.
	#   org  -> Organization permissions: "Self-hosted runners" (write)
	#   repo -> Repository permissions:   "Administration" (write)
	if [[ "$SCOPE" == org ]]; then
		inst_url="$API/orgs/$GITHUB_ORG/installation"
		perms='{"permissions":{"organization_self_hosted_runners":"write"}}'
	else
		inst_url="$API/repos/$GITHUB_REPO/installation"
		perms='{"permissions":{"administration":"write"}}'
	fi

	inst_id=$(curl -fsS --max-time 30 --retry 3 --retry-delay 2 --retry-connrefused \
		-H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" \
		-H "X-GitHub-Api-Version: $APIV" "$inst_url" | jq -r '.id')
	[[ -n "$inst_id" && "$inst_id" != null ]] || die "app not installed on that org/repo"

	resp=$(curl -fsS --max-time 30 -X POST -H "Authorization: Bearer $jwt" \
		-H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: $APIV" \
		-d "$perms" \
		"$API/app/installations/$inst_id/access_tokens") ||
		die "could not mint an installation token. The app is installed but is
probably missing its permission: $([[ "$SCOPE" == org ]] &&
			echo 'Organization permissions > Self-hosted runners > Read and write' ||
			echo 'Repository permissions > Administration > Read and write')
Set it under the app's Permissions page, then accept the request under the
organization's Installed GitHub Apps entry."
	_TOKEN=$(jq -r '.token' <<<"$resp")
	_TOKEN_EXP=$(date -d "$(jq -r '.expires_at' <<<"$resp")" +%s)
	[[ -n "$_TOKEN" && "$_TOKEN" != null ]] || die "failed to mint installation token"
	printf '%s' "$_TOKEN"
}

api() {
	local method="$1" path="$2" body="${3:-}" tok
	tok="$(auth_token)"
	if [[ -n "$body" ]]; then
		# No --retry on writes: a lost response would double-register a runner.
		curl -fsS --max-time 30 -X "$method" -H "Authorization: Bearer $tok" \
			-H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: $APIV" \
			-d "$body" "$API$path"
	else
		curl -fsS --max-time 30 --retry 3 --retry-delay 2 --retry-connrefused \
			-X "$method" -H "Authorization: Bearer $tok" \
			-H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: $APIV" "$API$path"
	fi
}

runners_path() {
	if [[ "$SCOPE" == org ]]; then
		printf '/orgs/%s/actions/runners' "$GITHUB_ORG"
	else printf '/repos/%s/actions/runners' "$GITHUB_REPO"; fi
}

# One JSON object per line. Paginates: a two-host fleet plus stale registrations
# passes 100 entries sooner than it looks.
list_runners() {
	local page=1 resp n
	while ((page <= 20)); do
		resp=$(api GET "$(runners_path)?per_page=100&page=$page")
		jq -c '.runners[]' <<<"$resp"
		n=$(jq '.runners|length' <<<"$resp")
		if ((n < 100)); then break; fi
		page=$((page + 1))
	done
}

mint_jit() {
	local name="$1" body
	body=$(jq -nc --arg n "$name" --arg l "$RUNNER_LABELS" --argjson g "$RUNNER_GROUP_ID" \
		'{name:$n, runner_group_id:$g, labels:($l|split(",")), work_folder:"_work"}')
	api POST "$(runners_path)/generate-jitconfig" "$body" | jq -er '.encoded_jit_config'
}

# ------------------------------------------------------------------ deps ----

DEPS_PACKAGES=(
	qemu-system-x86 qemu-utils ovmf
	cloud-image-utils guestfs-tools
	nftables curl jq openssl ca-certificates gpgv util-linux
	ubuntu-cloudimage-keyring
)

apt_available() {
	local c
	c="$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{print $2}')"
	[[ -n "$c" && "$c" != "(none)" ]]
}

# Names the processes holding any apt lock. Reads /proc directly so it needs no
# package of its own (fuser and lsof are not guaranteed on a minimal server).
apt_lock_holder() {
	local lock dir pid holders=()
	# One find per lock over the already-globbed fd directories. Readlinking
	# each fd individually forks thousands of times on a busy host.
	for lock in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
		/var/lib/apt/lists/lock /var/cache/apt/archives/lock; do
		[[ -e "$lock" ]] || continue
		while read -r dir; do
			[[ -n "$dir" ]] || continue
			pid="${dir#/proc/}"
			pid="${pid%%/*}"
			holders+=("$(cat "/proc/$pid/comm" 2>/dev/null || echo '?') (pid $pid)")
		done < <(find /proc/[0-9]*/fd -maxdepth 1 -lname "$lock" -printf '%h\n' 2>/dev/null)
	done
	((${#holders[@]})) || return 0
	printf '%s\n' "${holders[@]}" | sort -u | paste -sd', ' -
}

# unattended-upgrades, apt-daily and an unfinished do-release-upgrade all hold
# the apt locks, sometimes for a long time. Dying instantly on that leaves a
# half-configured host, so wait it out and name the blocker if it never clears.
# Only lock failures retry -- a 404 or an unmet dependency fails immediately.
apt_get() {
	local out tries=0 rc holder
	out="$(mktemp)"
	while :; do
		rc=0
		apt-get -o "DPkg::Lock::Timeout=$APT_LOCK_WAIT" "$@" 2>&1 | tee "$out" || rc=$?
		if ((rc == 0)); then
			rm -f "$out"
			return 0
		fi
		if ! grep -qiE 'could not get lock|unable to lock|is held by' "$out"; then
			rm -f "$out"
			die "apt-get $* failed (rc=$rc); see the output above"
		fi
		tries=$((tries + 1))
		((tries >= APT_LOCK_TRIES)) && break
		holder="$(apt_lock_holder)"
		log "apt is locked${holder:+ by $holder}; attempt $tries/$APT_LOCK_TRIES, waiting ${APT_LOCK_WAIT}s"
		sleep "$APT_LOCK_WAIT"
	done
	holder="$(apt_lock_holder)"
	rm -f "$out"
	die "apt is still locked after $APT_LOCK_TRIES attempts${holder:+; held by $holder}.
Let that finish (an interrupted 'do-release-upgrade' often waits forever on a
prompt inside screen/tmux), or stop it, then re-run."
}

# guestfs-tools lives in universe, which is on by default for Ubuntu Server but
# not for every minimal or cloud image.
ensure_apt_components() {
	local p missing=()
	for p in "$@"; do apt_available "$p" || missing+=("$p"); done
	((${#missing[@]})) || return 0

	log "enabling the universe component for: ${missing[*]}"
	command -v add-apt-repository >/dev/null 2>&1 ||
		apt_get install -y --no-install-recommends software-properties-common
	add-apt-repository -y universe
	apt_get update

	for p in "${missing[@]}"; do
		apt_available "$p" || die "package unavailable even with universe enabled: $p"
	done
}

# CPU virtualization and the matching KVM module. Nothing downstream works
# without these, so both are hard failures rather than doctor warnings.
# Prints the loaded kvm backend, empty if none. /sys/module is the authority and
# needs no pipeline: `lsmod | grep -q` returns 141 under `set -o pipefail` when
# grep matches an early line and lsmod dies on SIGPIPE, which reads as "not
# loaded" for a module that is in fact loaded.
kvm_module() {
	local m
	for m in kvm_amd kvm_intel; do
		if [[ -d "/sys/module/$m" ]]; then
			printf '%s' "$m"
			return 0
		fi
	done
	return 1
}

# Whether $1 can actually open /dev/kvm read-write.
#
# As root this drops privileges with setpriv and opens the device for real.
# setpriv is a plain syscall wrapper -- no PAM -- which matters because
# `sudo -u <user>` and `runuser` put the target through PAM's account stack,
# and that can refuse a system account with a nologin shell even where the
# kernel would allow the open. Unprivileged callers cannot drop privileges, so
# they fall back to the permission arithmetic.
user_can_use_kvm() {
	local user="$1"
	[[ -c /dev/kvm ]] || return 1
	if [[ $EUID -ne 0 ]] || ! command -v setpriv >/dev/null 2>&1; then
		kvm_perm_allows "$user"
		return
	fi
	setpriv --reuid "$user" --regid "$user" --init-groups --inh-caps=-all \
		-- sh -c 'exec 3<>/dev/kvm' >/dev/null 2>&1
}

# Does the group/mode arithmetic say $1 may open /dev/kvm read-write?
kvm_perm_allows() {
	local user="$1" gid mode groups
	[[ -c /dev/kvm ]] || return 1
	gid="$(stat -c %g /dev/kvm 2>/dev/null)" || return 1
	mode="$(stat -c %a /dev/kvm 2>/dev/null)" || return 1

	# world rw
	if (((8#$mode & 8#0006) == 8#0006)); then
		return 0
	fi
	groups=" $(id -G "$user" 2>/dev/null || true) "
	if [[ "$groups" == *" $gid "* ]] && (((8#$mode & 8#0060) == 8#0060)); then
		return 0
	fi
	return 1
}

setup_kvm() {
	local kmod
	if grep -qm1 -E '^flags.*\bvmx\b' /proc/cpuinfo; then
		kmod=kvm_intel
	elif grep -qm1 -E '^flags.*\bsvm\b' /proc/cpuinfo; then
		kmod=kvm_amd
	else die "this CPU exposes neither vmx nor svm; enable virtualization (SVM/VT-x) in the BIOS"; fi

	modprobe kvm "$kmod" || die "could not load $kmod; virtualization is likely disabled in the BIOS"
	printf '# installed by gha-vm.sh deps\nkvm\n%s\n' "$kmod" >/etc/modules-load.d/gha-vm.conf
	[[ -c /dev/kvm ]] || die "$kmod loaded but /dev/kvm is missing"
	log "kvm ready ($kmod)"
}

# A GitHub App JWT is only valid within a minute of real time, so a drifting
# clock shows up as an authentication failure with no obvious cause.
setup_timesync() {
	if ! systemctl is-active --quiet chrony ntpsec systemd-timesyncd 2>/dev/null; then
		apt_get install -y --no-install-recommends systemd-timesyncd
		systemctl enable --now systemd-timesyncd.service
	fi
	if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" != yes ]]; then
		log "WARN: clock is not NTP-synchronized yet; GitHub App auth fails on skew"
	else
		log "clock synchronized"
	fi
}

cmd_deps() {
	[[ $EUID -eq 0 ]] || die "deps must run as root"

	local id_like=""
	[[ -r /etc/os-release ]] && id_like="$(. /etc/os-release && printf '%s %s' "${ID:-}" "${ID_LIKE:-}")"
	[[ "$id_like" == *ubuntu* || "$id_like" == *debian* ]] ||
		die "deps targets Ubuntu (found: ${id_like:-unknown}); install the packages in DEPS_PACKAGES by hand"

	setup_kvm

	export DEBIAN_FRONTEND=noninteractive
	apt_get update
	ensure_apt_components "${DEPS_PACKAGES[@]}"
	apt_get install -y --no-install-recommends "${DEPS_PACKAGES[@]}"

	setup_timesync
	systemctl enable nftables.service >/dev/null 2>&1 ||
		log "WARN: could not enable nftables.service; isolation rules will not survive a reboot"

	id -u "$GHA_USER" >/dev/null 2>&1 ||
		useradd -r -m -d "$STATE_DIR" -s /usr/sbin/nologin "$GHA_USER"
	usermod -aG kvm "$GHA_USER"

	install -d -o "$GHA_USER" -g "$GHA_USER" -m 0750 "$STATE_DIR" "$RUN_DIR"
	install -d -o root -g "$GHA_USER" -m 0750 "$(dirname "$CONFIG")"

	if [[ ! -e "$CONFIG" && -r "$HERE/config.vm.env.example" ]]; then
		install -o root -g "$GHA_USER" -m 0640 "$HERE/config.vm.env.example" "$CONFIG"
		log "wrote config skeleton: $CONFIG"
	fi

	# Profiles ship in the checkout so one tree serves the whole fleet; each host
	# loads only the one matching its own name or machine-id.
	install -d -o root -g "$GHA_USER" -m 0750 "$PROFILE_DIR"
	if [[ -d "$HERE/profiles" ]]; then
		local p
		for p in "$HERE"/profiles/*.env; do
			[[ -e "$p" ]] || continue
			install -o root -g "$GHA_USER" -m 0640 "$p" "$PROFILE_DIR/"
		done
		log "installed profiles: $(find "$PROFILE_DIR" -name '*.env' -printf '%f ' 2>/dev/null)"
	fi
	# Re-resolve now that the files exist; deps sourced the config before this.
	load_profile
	apply_defaults
	log "this host matches profile '$HOST_PROFILE'${PROFILE_FILE:+ ($PROFILE_FILE)}"

	log "host ready; $GHA_USER is in the kvm group"
	config_is_filled || log "NEXT: fill in $CONFIG, then run: $SELF bootstrap <slots>"
}

# True once the operator has supplied the values that have no useful default.
config_is_filled() {
	[[ -r "$CONFIG" ]] || return 1
	# Read in a subshell: deps may have written the skeleton after the parent
	# already sourced the config.
	(
		# shellcheck disable=SC1090
		source "$CONFIG"
		case "${SCOPE:-}" in
		org) [[ -n "${GITHUB_ORG:-}" ]] || exit 1 ;;
		repo) [[ -n "${GITHUB_REPO:-}" ]] || exit 1 ;;
		*) exit 1 ;;
		esac
		case "${AUTH_MODE:-}" in
		app) [[ -n "${GITHUB_APP_ID:-}" && -r "${GITHUB_APP_KEY:-/nonexistent}" ]] || exit 1 ;;
		pat) [[ -n "${GITHUB_PAT:-}" ]] || exit 1 ;;
		*) exit 1 ;;
		esac
	)
}

# Everything from a bare Ubuntu server to running slots, in order, stopping at
# the one step that needs a human: the GitHub credentials.
cmd_bootstrap() {
	[[ $EUID -eq 0 ]] || die "bootstrap must run as root"
	local count="${1:-}"

	cmd_deps

	if ! config_is_filled; then
		log ""
		log "STOPPING: $CONFIG still needs your GitHub settings."
		log "  1. sudoedit $CONFIG            # SCOPE, GITHUB_ORG/REPO, AUTH_MODE, app id"
		log "  2. install -o root -g $GHA_USER -m 0640 app.pem $(dirname "$CONFIG")/app.pem"
		log "  3. $SELF bootstrap ${count:-<slots>}"
		return 2
	fi

	# Re-read: deps may have just written the config this run.
	load_config

	if [[ -f "$GOLDEN" ]]; then
		log "golden image present, skipping the build (rebuild with: $SELF image)"
	else
		cmd_image
	fi
	cmd_net

	if ! cmd_doctor; then
		die "doctor reported problems; fix them and re-run: $SELF bootstrap ${count:-}"
	fi

	if [[ -z "$count" ]]; then
		cmd_capacity
		log ""
		log "pick a slot count from the recommendation above, then: $SELF install <slots>"
		return 0
	fi
	cmd_install "$count"
}

# ----------------------------------------------------------------- image ----

# OVMF CODE and VARS must come from the same build. A 4M CODE paired with a
# legacy 2M VARS produces a VM that silently fails to boot.
ovmf_pair() {
	local c v
	for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
		v="${c/CODE/VARS}"
		[[ "$c" == */ovmf/OVMF.fd ]] && v=/usr/share/ovmf/OVMF_VARS.fd
		if [[ -r "$c" && -r "$v" ]]; then
			printf '%s\n%s\n' "$c" "$v"
			return
		fi
	done
	die "no matching OVMF CODE/VARS pair found (apt install ovmf)"
}

runner_asset_sha() {
	local ver="$1"
	api GET "/repos/actions/runner/releases/tags/v${ver}" | jq -r '.body' |
		grep -iA2 "actions-runner-linux-x64-${ver}\.tar\.gz" |
		grep -oiE '[0-9a-f]{64}' | head -n1
}

latest_runner_version() {
	api GET "/repos/actions/runner/releases/latest" | jq -er '.tag_name' | sed 's/^v//'
}

# qemu-img resize grows the qcow2 container; the partition table and filesystem
# inside still describe the cloud image's ~3.5G root. cloud-init would grow them
# at first boot, but virt-customize never boots the guest -- so without this the
# package installs below fail with ENOSPC *inside* the image, while the host
# still shows hundreds of gigabytes free.
grow_guest_root() {
	local img="$1" before after
	before="$(guest_root_free_mb "$img")"
	# Single-quoted on purpose: these expand in the guest shell, not here.
	# shellcheck disable=SC2016
	virt-customize -a "$img" --run-command '
set -e
root=$(findmnt -no SOURCE /)
disk=/dev/$(lsblk -no PKNAME "$root")
part=$(printf %s "$root" | grep -oE "[0-9]+$")
growpart "$disk" "$part" || true
resize2fs "$root"
' >/dev/null || die "could not expand the guest root filesystem (growpart/resize2fs failed)"
	after="$(guest_root_free_mb "$img")"
	log "guest root grown to fit $VM_DISK: ${before:-?}M -> ${after:-?}M free"

	# Everything installed below needs room; failing here beats failing halfway
	# through a package install with a confusing dpkg error.
	[[ -n "$after" ]] && ((after < 6144)) &&
		die "guest root has only ${after}M free after expanding to $VM_DISK; raise VM_DISK"
	return 0
}

# virt-df --csv: Filesystem,1K-blocks,Used,Available,Use%. The image has several
# filesystems (ESP, /boot, root); the root is the largest, so report that one.
guest_root_free_mb() {
	virt-df --csv -a "$1" 2>/dev/null |
		awk -F, 'NR>1 && $1 ~ /\/dev\// && $2+0 > big { big = $2+0; free = int($4/1024) }
		         END { if (free != "") print free }'
}

cmd_image() {
	[[ $EUID -eq 0 ]] || die "image must run as root"
	need qemu-img
	need virt-customize
	need virt-df
	need curl
	need jq
	need gpgv
	[[ -r /usr/share/keyrings/ubuntu-cloudimage-keyring.gpg ]] ||
		die "missing /usr/share/keyrings/ubuntu-cloudimage-keyring.gpg (apt install ubuntu-cloudimage-keyring)"

	local work base rsha tmp
	work="$STATE_DIR/build"
	base="$work/$CLOUDIMG_NAME"
	install -d -m 0750 "$work"

	if [[ ! -f "$base" ]]; then
		log "downloading $CLOUDIMG_NAME"
		curl -fSL --progress-bar -o "$base.part" "$CLOUDIMG_BASE/$CLOUDIMG_NAME"
		curl -fsSL -o "$work/SHA256SUMS" "$CLOUDIMG_BASE/SHA256SUMS"
		curl -fsSL -o "$work/SHA256SUMS.gpg" "$CLOUDIMG_BASE/SHA256SUMS.gpg"
		gpgv --keyring /usr/share/keyrings/ubuntu-cloudimage-keyring.gpg \
			"$work/SHA256SUMS.gpg" "$work/SHA256SUMS" ||
			die "SHA256SUMS signature check failed"
		mv -f "$base.part" "$base"
		(cd "$work" && grep " [ *]\?${CLOUDIMG_NAME}\$" SHA256SUMS | sha256sum -c -) ||
			{
				rm -f "$base"
				die "cloud image checksum mismatch"
			}
		log "cloud image signature and checksum OK"
	fi

	rsha="${RUNNER_SHA256:-$(runner_asset_sha "$RUNNER_VERSION" || true)}"
	if [[ -z "$rsha" ]]; then
		[[ "$ALLOW_UNVERIFIED_RUNNER" == 1 ]] ||
			die "could not resolve the runner tarball SHA-256 for v$RUNNER_VERSION.
Pin it with RUNNER_SHA256= in $CONFIG (see the release notes at
https://github.com/actions/runner/releases/tag/v$RUNNER_VERSION),
or set ALLOW_UNVERIFIED_RUNNER=1 to install it unverified."
		log "WARN: installing the runner tarball unverified (ALLOW_UNVERIFIED_RUNNER=1)"
	fi

	tmp="$work/golden.building.qcow2"
	rm -f "$tmp"
	cp --reflink=auto "$base" "$tmp"
	qemu-img resize "$tmp" "$VM_DISK"

	export LIBGUESTFS_BACKEND=direct

	grow_guest_root "$tmp"

	virt-customize -a "$tmp" \
		--update \
		--install docker.io,git,jq,curl,unzip,zip,ca-certificates,build-essential,rsync,gnupg \
		--run-command 'apt-get purge -y snapd || true' \
		--run-command 'useradd -m -s /bin/bash -G docker runner' \
		--run-command 'install -d -o runner -g runner /opt/actions-runner' \
		--run-command "cd /opt/actions-runner \
        && curl -fsSLo r.tgz https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz \
        && { [ -z '${rsha}' ] || echo '${rsha}  r.tgz' | sha256sum -c -; } \
        && tar xzf r.tgz && rm r.tgz && ./bin/installdependencies.sh \
        && mkdir -p _work && chown -R runner:runner /opt/actions-runner" \
		--write '/etc/cloud/cloud.cfg.d/99-nocloud.cfg:datasource_list: [ NoCloud, None ]' \
		--write '/etc/docker/daemon.json:{"log-driver":"local","log-opts":{"max-size":"32m","max-file":"2"}}' \
		--run-command 'systemctl disable --now unattended-upgrades apt-daily.timer apt-daily-upgrade.timer man-db.timer motd-news.timer fstrim.timer systemd-networkd-wait-online.service 2>/dev/null || true' \
		--run-command 'sed -i "s/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/" /etc/default/grub && update-grub' \
		--upload "$HERE/gha-job.sh:/usr/local/bin/gha-job.sh" \
		--chmod '0755:/usr/local/bin/gha-job.sh' \
		--run-command 'systemctl enable docker' \
		--run-command 'apt-get clean && rm -rf /var/lib/apt/lists/* /var/log/journal/*' \
		--truncate /etc/machine-id \
		--delete /var/lib/dbus/machine-id

	# Overlay reads are served from the host page cache shared by every slot, so a
	# smaller golden directly cuts per-slot memory pressure.
	if [[ "$SPARSIFY" == 1 ]]; then
		log "sparsifying golden image"
		virt-sparsify --in-place "$tmp" || die "virt-sparsify failed (set SPARSIFY=0 to skip)"
	fi

	mv -f "$tmp" "$GOLDEN"
	chown "$GHA_USER":"$GHA_USER" "$GOLDEN"
	chmod 0644 "$GOLDEN"
	log "golden image ready: $GOLDEN ($(du -h "$GOLDEN" | cut -f1), runner $RUNNER_VERSION, ubuntu $UBUNTU_RELEASE)"
	log "running slots adopt it when their current VM finishes"
}

cmd_upgrade() {
	[[ $EUID -eq 0 ]] || die "upgrade must run as root"
	local latest sha
	latest="$(latest_runner_version)"
	[[ -n "$latest" ]] || die "could not resolve the latest runner release"

	if [[ "$latest" == "$RUNNER_VERSION" && -f "$GOLDEN" ]]; then
		log "already on runner $latest; rebuilding anyway to pick up guest package updates"
	fi

	if [[ "$AUTO_RUNNER_VERSION" == 1 && "$latest" != "$RUNNER_VERSION" ]]; then
		sha="$(runner_asset_sha "$latest" || true)"
		cp -a "$CONFIG" "$CONFIG.bak"
		sed -i "s/^RUNNER_VERSION=.*/RUNNER_VERSION=$latest/" "$CONFIG"
		if [[ -n "$sha" ]]; then
			if grep -qE '^#?RUNNER_SHA256=' "$CONFIG"; then
				sed -i "s|^#\?RUNNER_SHA256=.*|RUNNER_SHA256=$sha|" "$CONFIG"
			else
				printf 'RUNNER_SHA256=%s\n' "$sha" >>"$CONFIG"
			fi
		fi
		RUNNER_VERSION="$latest"
		RUNNER_SHA256="${sha:-}"
		log "pinned runner $latest in $CONFIG (previous config saved as $CONFIG.bak)"
	fi

	cmd_image
}

# ------------------------------------------------------------------- net ----

# $1 is 4 or 6: the nameservers of that family the host actually resolves with.
host_resolvers() {
	local f pat='^[0-9]+(\.[0-9]+){3}$'
	[[ "$1" == 6 ]] && pat='^[0-9a-fA-F]*:[0-9a-fA-F:]*$'
	for f in /etc/resolv.conf /run/systemd/resolve/resolv.conf; do
		[[ -r "$f" ]] && awk '/^nameserver[ \t]/ {print $2}' "$f"
	done | sed 's/%.*//' | grep -E "$pat" | sort -u
}

cmd_net() {
	[[ $EUID -eq 0 ]] || die "net must run as root"
	id -u "$GHA_USER" >/dev/null 2>&1 || die "user $GHA_USER does not exist (run: $SELF deps)"

	local uid r4 r6 dns_rules=""
	uid="$(id -u "$GHA_USER")"

	# QEMU's user-mode network maps the guest's default gateway (10.0.2.2) onto
	# the host's loopback, so without this every service bound to 127.0.0.1 is
	# reachable from inside a job. Blocking loopback also blocks the local
	# resolver, so punch a hole for the nameservers in use, port 53 only.
	r4="$(host_resolvers 4 | paste -sd, -)"
	r6="$(host_resolvers 6 | paste -sd, -)"

	local proto
	for proto in udp tcp; do
		[[ -n "$r4" ]] && dns_rules+="    meta skuid $uid ip  daddr { $r4 } $proto dport 53 counter accept"$'\n'
		[[ -n "$r6" ]] && dns_rules+="    meta skuid $uid ip6 daddr { $r6 } $proto dport 53 counter accept"$'\n'
	done
	[[ -n "$dns_rules" ]] ||
		log "WARN: no nameserver found in resolv.conf; guest DNS will break once loopback is blocked"

	install -d -o root -g "$GHA_USER" -m 0750 "$(dirname "$NFT_CONF")"
	cat >"$NFT_CONF" <<EOF
table inet gha
delete table inet gha
table inet gha {
  chain output {
    type filter hook output priority 0; policy accept;
${dns_rules}    meta skuid $uid ip  daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } counter drop
    meta skuid $uid ip6 daddr { ::1, fc00::/7, fe80::/10 } counter drop
  }
}
EOF
	nft -c -f "$NFT_CONF" || die "generated ruleset is invalid: $NFT_CONF"
	nft -f "$NFT_CONF"
	grep -q "$NFT_CONF" "$NFT_MAIN" 2>/dev/null ||
		printf 'include "%s"\n' "$NFT_CONF" >>"$NFT_MAIN"
	systemctl enable nftables >/dev/null 2>&1 || true

	log "uid $uid blocked from host loopback, RFC1918 and link-local; DNS allowed to: ${r4:-none} ${r6:-}"
	log "NOTE: this also blocks a LAN apt mirror or internal registry. Add accept rules above the drops in $NFT_CONF if you need one."
}

# ------------------------------------------------------------------- run ----

# Reap only this slot's own stale registrations. A host-wide reap here would
# race a sibling slot whose runner is registered but has not booted yet -- it
# reads as "offline" and deleting it invalidates that slot's live JIT config.
reap_slot() {
	local slot="$1" id
	while read -r id; do
		[[ -n "$id" ]] || continue
		log "slot $slot: reaping stale runner id=$id"
		api DELETE "$(runners_path)/$id" >/dev/null ||
			log "slot $slot: WARN could not delete runner id=$id; it will be retried next cycle"
	done < <(list_runners | jq -r --arg p "${NAME_PREFIX}-${slot}-" \
		'select(.name|startswith($p)) | select(.status=="offline") | .id')
}

reap_one() {
	local target="$1" id
	id=$(list_runners | jq -r --arg n "$target" 'select(.name==$n) | .id' | head -n1)
	[[ -n "$id" ]] && api DELETE "$(runners_path)/$id" >/dev/null
}

# A reboot or a SIGKILL leaves this slot's overlay behind; nothing else ever
# deletes it, so the disk leaks one image per unclean stop. Only safe to call
# while holding the slot's flock.
reap_slot_dirs() {
	local slot="$1" d
	while read -r d; do
		[[ -n "$d" ]] || continue
		log "slot $slot: removing orphaned run dir $(basename "$d")"
		rm -rf "$d"
	done < <(find "$RUN_DIR" -mindepth 1 -maxdepth 1 -type d \
		-name "${NAME_PREFIX}-${slot}-*" 2>/dev/null)
}

# Guests run untrusted workflow code, so a slot that comes up before (or
# without) the isolation rules is a hole, not a degraded mode. The unit calls
# this as root via ExecStartPre, because listing nftables needs CAP_NET_ADMIN
# and the supervisor itself runs unprivileged.
cmd_netcheck() {
	if [[ "$REQUIRE_ISOLATION" != 1 ]]; then
		log "REQUIRE_ISOLATION=0: starting without verifying host/LAN isolation"
		return 0
	fi
	local rules
	# Captured, not piped into grep: under `set -o pipefail` a `grep -q` that
	# matches early makes nft die on SIGPIPE and the pipeline return 141, which
	# would read as "loopback unblocked" and refuse to start every slot.
	rules="$(nft list table inet gha 2>/dev/null)" ||
		die "nftables table 'inet gha' is not loaded; jobs would reach the host and LAN (run: $SELF net, or set REQUIRE_ISOLATION=0)"
	[[ "$rules" == *'127.0.0.0/8'* ]] ||
		die "the gha nftables table is loaded but does not block host loopback (re-run: $SELF net)"
}

# Available GiB on the filesystem holding $1. Empty when df cannot read it;
# every caller reports "unknown" rather than assuming there is room.
free_gb() {
	local out
	out=$(df -BG --output=avail "$1" 2>/dev/null | tail -1) || out=""
	printf '%s' "${out//[!0-9]/}"
}

cmd_run() {
	need qemu-system-x86_64
	need cloud-localds
	need qemu-img
	need flock
	local slot="${1:-1}"
	[[ "$slot" =~ ^[0-9]+$ ]] || die "slot must be a number"

	[[ -f "$GOLDEN" ]] || die "golden image missing: $GOLDEN (run: $SELF image)"
	install -d -m 0750 "$RUN_DIR"

	# Guards against a hand-started supervisor racing the systemd one.
	exec 9>"$RUN_DIR/.slot-$slot.lock"
	flock -n 9 || die "slot $slot already has a supervisor running"

	local code vars pair
	pair="$(ovmf_pair)"
	code="$(sed -n 1p <<<"$pair")"
	vars="$(sed -n 2p <<<"$pair")"

	local name dir vmpid="" tailpid="" fails=0 stopping=0
	local cpu="$VM_CPU"
	if [[ "$NESTED_VIRT" != 1 && "$cpu" == host ]]; then
		if grep -qm1 '^flags.*\bvmx\b' /proc/cpuinfo; then
			cpu="host,vmx=off"
		elif grep -qm1 '^flags.*\bsvm\b' /proc/cpuinfo; then cpu="host,svm=off"; fi
	fi

	shutdown() {
		stopping=1
		log "slot $slot: stopping"
		[[ -n "$vmpid" ]] && kill -TERM "$vmpid" 2>/dev/null || true
		[[ -n "$tailpid" ]] && kill -TERM "$tailpid" 2>/dev/null || true
		[[ -n "${name:-}" ]] && { reap_one "$name" || true; }
		[[ -n "${dir:-}" ]] && rm -rf "$dir"
		exit 0
	}
	trap shutdown INT TERM

	reap_slot_dirs "$slot"
	# A GitHub outage here must not stop the slot from serving jobs.
	reap_slot "$slot" || log "slot $slot: WARN startup reap failed; continuing"

	while ((stopping == 0)); do
		local avail
		avail="$(free_gb "$RUN_DIR")"
		if [[ -z "$avail" ]]; then
			log "slot $slot: WARN cannot read free space under $RUN_DIR; starting anyway"
		elif ((avail < MIN_FREE_GB)); then
			log "slot $slot: only ${avail}G free under $RUN_DIR (need ${MIN_FREE_GB}G); waiting 60s"
			sleep 60
			continue
		fi

		name="${NAME_PREFIX}-${slot}-$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')"
		dir="$RUN_DIR/$name"
		install -d -m 0700 "$dir"

		local jit
		if ! jit="$(mint_jit "$name")"; then
			log "slot $slot: jit mint failed, retry in 30s"
			rm -rf "$dir"
			sleep 30
			continue
		fi

		printf '#cloud-config\nhostname: %s\nusers: []\ndisable_root: true\nssh_pwauth: false\nwrite_files:\n  - path: /run/gha-jit\n    encoding: b64\n    permissions: "0600"\n    content: %s\nruncmd:\n  - [ /usr/local/bin/gha-job.sh ]\n' \
			"$name" "$(printf '%s' "$jit" | base64 -w0)" >"$dir/user-data"
		printf 'instance-id: %s\nlocal-hostname: %s\n' "$name" "$name" >"$dir/meta-data"
		cloud-localds "$dir/seed.img" "$dir/user-data" "$dir/meta-data"
		rm -f "$dir/user-data"
		jit=""

		qemu-img create -q -f qcow2 -F qcow2 -b "$GOLDEN" "$dir/disk.qcow2" >/dev/null
		cp "$vars" "$dir/vars.fd"
		: >"$dir/console.log"

		# Console goes to a file so the watchdog can read it; tail relays it to the
		# journal so `journalctl -fu gha-vm@N` still shows a live job.
		tail -n +1 -F "$dir/console.log" >&2 &
		tailpid=$!

		local started
		started=$(date +%s)
		qemu-system-x86_64 \
			-name "$name" \
			-machine q35,accel=kvm -cpu "$cpu" \
			-smp "$VM_CPUS" -m "$VM_MEM" \
			-drive "if=pflash,format=raw,readonly=on,file=$code" \
			-drive "if=pflash,format=raw,file=$dir/vars.fd" \
			-drive "file=$dir/disk.qcow2,if=virtio,format=qcow2,cache=unsafe,discard=unmap" \
			-drive "file=$dir/seed.img,if=virtio,format=raw,readonly=on" \
			-netdev user,id=n0,ipv6=off -device virtio-net-pci,netdev=n0 \
			-device virtio-rng-pci \
			-device virtio-balloon-pci,free-page-reporting=on \
			-display none -monitor none -serial "file:$dir/console.log" \
			-no-reboot -rtc base=utc &
		vmpid=$!

		local reason="" ready=0 now elapsed
		while kill -0 "$vmpid" 2>/dev/null; do
			sleep 5
			now=$(date +%s)
			elapsed=$((now - started))
			if ((ready == 0)) && grep -qF "$READY_MARKER" "$dir/console.log" 2>/dev/null; then
				ready=1
				log "slot $slot: $name up after ${elapsed}s"
			fi
			if ((ready == 0 && elapsed > BOOT_TIMEOUT)); then
				reason="boot-timeout"
				break
			fi
			if ((elapsed > MAX_LIFETIME)); then
				reason="max-lifetime"
				break
			fi
		done

		if [[ -n "$reason" ]]; then
			log "slot $slot: killing $name ($reason after ${elapsed}s)"
			kill -TERM "$vmpid" 2>/dev/null || true
			local w=0
			while kill -0 "$vmpid" 2>/dev/null && ((w < 60)); do
				sleep 1
				w=$((w + 1))
			done
			kill -KILL "$vmpid" 2>/dev/null || true
		fi

		local rc=0
		wait "$vmpid" || rc=$?
		vmpid=""
		kill -TERM "$tailpid" 2>/dev/null || true
		wait "$tailpid" 2>/dev/null || true
		tailpid=""

		elapsed=$(($(date +%s) - started))
		if ((ready == 0)); then
			log "slot $slot: $name never reached the runner; last console lines:"
			tail -n 20 "$dir/console.log" >&2 || true
		fi

		rm -rf "$dir"
		dir=""
		reap_one "$name" || true
		name=""
		log "slot $slot: vm exited rc=$rc after ${elapsed}s${reason:+ ($reason)}"

		if ((elapsed < 30 || ready == 0)); then
			fails=$((fails + 1))
			local backoff=$((fails > 6 ? 60 : fails * 10))
			log "slot $slot: unhealthy cycle #$fails, backing off ${backoff}s"
			sleep "$backoff"
		else
			fails=0
		fi
	done
}

# ------------------------------------------------------------- reap/clean ----

# Host-wide reap. Skips names that still have a live run directory, so it is
# safe to run while slots are working.
cmd_reap() {
	local id name
	while read -r id name; do
		[[ -n "$id" ]] || continue
		if [[ -d "$RUN_DIR/$name" ]]; then continue; fi
		log "reaping stale runner $name (id=$id)"
		api DELETE "$(runners_path)/$id" >/dev/null ||
			log "WARN could not delete runner $name (id=$id)"
	done < <(list_runners | jq -r --arg p "$NAME_PREFIX" \
		'select(.name|startswith($p)) | select(.status=="offline") | "\(.id) \(.name)"')
}

cmd_clean() {
	local d
	for d in "$RUN_DIR"/*/; do
		[[ -d "$d" ]] || continue
		rm -rf "$d"
	done
	cmd_reap
}

# ---------------------------------------------------------------- doctor ----

cmd_capacity() {
	local ram cores avail per_mem slots_mem slots_cpu slots_disk rec bound
	ram=$(($(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 1024 / 1024))
	cores=$(nproc)
	avail="$(free_gb "$STATE_DIR")"
	avail="${avail:-0}"
	per_mem="$(mem_to_gb "$VM_MEM")"

	slots_mem=$(((ram - HOST_RESERVE_GB) / per_mem))
	slots_cpu=$((cores * CPU_OVERCOMMIT / VM_CPUS))
	slots_disk=$((avail / DISK_PER_SLOT_GB))
	((slots_mem < 0)) && slots_mem=0

	rec=$slots_mem
	bound=memory
	if ((slots_cpu < rec)); then
		rec=$slots_cpu
		bound=cpu
	fi
	if ((slots_disk < rec)); then
		rec=$slots_disk
		bound=disk
	fi

	local virt="" tuned=""
	host_is_virtual && virt='  [virtual: runner VMs nest]'
	((AUTOTUNE_APPLIED)) && tuned=', autotuned to what is resident now'

	printf 'profile        %s  %s\n' "$HOST_PROFILE" \
		"${PROFILE_FILE:-(no file in $PROFILE_DIR; built-in defaults + autotune)}"
	printf 'host           %s cores, %sG RAM, %sG free under %s%s\n' \
		"$cores" "$ram" "$avail" "$STATE_DIR" "$virt"
	printf 'per slot       %s vCPU, %s RAM, %sG disk budget\n' "$VM_CPUS" "$VM_MEM" "$DISK_PER_SLOT_GB"
	printf 'memory limit   %s slots  (reserving %sG for the host%s)\n' \
		"$slots_mem" "$HOST_RESERVE_GB" "$tuned"
	printf 'cpu limit      %s slots  (%sx overcommit)\n' "$slots_cpu" "$CPU_OVERCOMMIT"
	printf 'disk limit     %s slots\n' "$slots_disk"

	if ((MAX_SLOTS > 0)) && ((rec > MAX_SLOTS)); then
		printf 'profile cap    %s slots  (MAX_SLOTS; this host has other work)\n' "$MAX_SLOTS"
		rec=$MAX_SLOTS
		bound="MAX_SLOTS"
	fi

	printf '\nrecommended    %s slots  (%s-bound)  ->  %s install %s\n' \
		"$rec" "$bound" "$SELF" "$rec"
	printf '\nBalloon free-page-reporting returns idle guest memory to the host, so the\n'
	printf 'memory limit above is a worst case with every slot running a heavy job.\n'
}

# "Which machine am I on, and what sizing did that pick?" -- the one command to
# run on a new host before installing anything.
cmd_profile() {
	local ram avail
	ram=$(($(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 1024 / 1024))
	avail="$(free_gb "$STATE_DIR")"

	printf 'hostname       %s\n' "$(hostname -s)"
	printf 'machine-id     %s\n' "$(cat /etc/machine-id 2>/dev/null || echo unknown)"
	printf 'hardware       %s cores, %sG RAM, %sG free under %s\n' \
		"$(nproc)" "$ram" "${avail:-0}" "$STATE_DIR"
	printf 'virtualised    %s\n' "$(host_is_virtual && echo 'yes (runner VMs nest)' || echo no)"
	printf 'kvm            %s\n' "$([[ -c /dev/kvm ]] && echo present || echo ABSENT)"
	printf '\nprofile        %s\n' "$HOST_PROFILE"
	if [[ -n "$PROFILE_FILE" ]]; then
		printf 'loaded from    %s\n' "$PROFILE_FILE"
	else
		printf 'loaded from    (none found in %s; using config + built-in defaults)\n' "$PROFILE_DIR"
	fi
	local tuned="" cap=uncapped
	((AUTOTUNE_APPLIED)) && tuned='   (autotuned up from the configured floor)'
	((MAX_SLOTS > 0)) && cap="$MAX_SLOTS"

	printf '\neffective sizing\n'
	printf '  VM_CPUS            %s\n' "$VM_CPUS"
	printf '  VM_MEM             %s\n' "$VM_MEM"
	printf '  VM_DISK            %s\n' "$VM_DISK"
	printf '  HOST_RESERVE_GB    %s%s\n' "$HOST_RESERVE_GB" "$tuned"
	printf '  DISK_PER_SLOT_GB   %s\n' "$DISK_PER_SLOT_GB"
	printf '  MIN_FREE_GB        %s\n' "$MIN_FREE_GB"
	printf '  MAX_SLOTS          %s\n' "$cap"
	printf '\n'
	cmd_capacity
}

# Fix the preflight items that have one obvious correct answer, so a failed
# doctor becomes a repaired host rather than a list of commands to paste.
# Anything needing a human decision (credentials, scope, a public repo) is left
# for doctor to report.
cmd_repair() {
	[[ $EUID -eq 0 ]] || die "repair must run as root"
	local fixed=0

	if ! kvm_module >/dev/null && grep -qm1 -E '^flags.*\b(vmx|svm)\b' /proc/cpuinfo; then
		log "repair: loading the kvm module"
		setup_kvm
		fixed=1
	fi

	if id -u "$GHA_USER" >/dev/null 2>&1; then
		if [[ -c /dev/kvm ]] && ! user_can_use_kvm "$GHA_USER"; then
			log "repair: adding $GHA_USER to the kvm group"
			usermod -aG kvm "$GHA_USER"
			fixed=1
			# udev owns /dev/kvm's group; a stale node predating the kvm group
			# leaves a correct group list still unable to open it.
			if ! user_can_use_kvm "$GHA_USER" && command -v udevadm >/dev/null 2>&1; then
				log "repair: retriggering udev for /dev/kvm"
				udevadm trigger --name-match=kvm >/dev/null 2>&1 || true
				udevadm settle --timeout=5 >/dev/null 2>&1 || true
			fi
		fi
		install -d -o "$GHA_USER" -g "$GHA_USER" -m 0750 "$STATE_DIR" "$RUN_DIR"
	fi

	if [[ -e "$CONFIG" ]]; then
		local mode
		mode="$(stat -c '%a' "$CONFIG")"
		if ((8#$mode & 8#0007)) || [[ "$(stat -c '%U:%G' "$CONFIG")" != "root:$GHA_USER" ]]; then
			log "repair: tightening $CONFIG to root:$GHA_USER 0640"
			chown "root:$GHA_USER" "$CONFIG"
			chmod 0640 "$CONFIG"
			fixed=1
		fi
	fi

	if [[ "${AUTH_MODE:-}" == app && -e "${GITHUB_APP_KEY:-}" ]] &&
		! user_can_read "$GHA_USER" "$GITHUB_APP_KEY"; then
		log "repair: fixing ownership of $GITHUB_APP_KEY"
		chown "root:$GHA_USER" "$GITHUB_APP_KEY"
		chmod 0640 "$GITHUB_APP_KEY"
		fixed=1
	fi

	if ! nft list table inet gha >/dev/null 2>&1; then
		log "repair: installing the nftables isolation rules"
		cmd_net
		fixed=1
	fi

	if ((fixed)); then
		log "repair: done"
	else
		log "repair: nothing to fix"
	fi
	return 0
}

# Same privilege-drop rationale as user_can_use_kvm.
user_can_read() {
	local user="$1" file="$2"
	[[ -e "$file" ]] || return 1
	if [[ $EUID -ne 0 ]] || ! command -v setpriv >/dev/null 2>&1; then
		return 0
	fi
	setpriv --reuid "$user" --regid "$user" --init-groups --inh-caps=-all \
		-- test -r "$file" >/dev/null 2>&1
}

cmd_doctor() {
	local ok=0 apt_holder
	printf 'kvm: '
	if user_can_use_kvm "$GHA_USER"; then
		echo OK
	elif [[ -c /dev/kvm ]]; then
		echo "present but $GHA_USER cannot open it (add to kvm group)"
		ok=1
	else
		echo "FAIL: no /dev/kvm (virtualization off in BIOS?)"
		ok=1
	fi

	printf 'tools: '
	local miss=()
	for t in qemu-system-x86_64 qemu-img cloud-localds virt-customize nft jq curl openssl flock; do
		command -v "$t" >/dev/null 2>&1 || miss+=("$t")
	done
	if ((${#miss[@]})); then
		echo "missing: ${miss[*]}"
		ok=1
	else echo OK; fi

	printf 'ovmf: '
	if ovmf_pair >/dev/null 2>&1; then echo "OK ($(ovmf_pair | tr '\n' ' '))"; else
		echo FAIL
		ok=1
	fi

	printf 'config perms: '
	local mode
	mode="$(stat -c '%a' "$CONFIG" 2>/dev/null || echo 000)"
	if ((8#$mode & 8#0007)); then
		echo "FAIL: $CONFIG is mode $mode; want 0640 root:$GHA_USER"
		ok=1
	elif ! sudo -u "$GHA_USER" test -r "$CONFIG"; then
		echo "FAIL: $GHA_USER cannot read $CONFIG"
		ok=1
	else echo "OK ($mode)"; fi

	if [[ "$AUTH_MODE" == app ]]; then
		printf 'app key: '
		if sudo -u "$GHA_USER" test -r "$GITHUB_APP_KEY"; then
			echo OK
		else
			echo "FAIL: $GHA_USER cannot read $GITHUB_APP_KEY (chown root:$GHA_USER, chmod 0640)"
			ok=1
		fi
	fi

	printf 'kvm module: '
	if kvm_module; then
		echo "OK ($(kvm_module))"
	elif grep -qm1 -E '^flags.*\b(vmx|svm)\b' /proc/cpuinfo; then
		echo "not loaded (run: $SELF deps)"
		ok=1
	else
		echo "FAIL: CPU exposes neither vmx nor svm; enable virtualization in the BIOS"
		ok=1
	fi

	printf 'apt: '
	apt_holder="$(apt_lock_holder)"
	if [[ -n "$apt_holder" ]]; then
		echo "locked by $apt_holder; deps will wait on it"
		ok=1
	else echo OK; fi

	printf 'clock: '
	if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == yes ]]; then echo OK; else
		echo "not NTP-synchronized; GitHub App auth fails on skew"
		ok=1
	fi

	printf 'golden image: '
	if [[ -f "$GOLDEN" ]]; then echo "OK ($GOLDEN, $(du -h "$GOLDEN" | cut -f1))"; else
		echo "missing (run: $SELF image)"
		ok=1
	fi

	printf 'free disk: '
	local avail
	avail="$(free_gb "$STATE_DIR")"
	if [[ -n "$avail" ]] && ((avail >= MIN_FREE_GB)); then
		echo "OK (${avail}G)"
	else
		echo "LOW (${avail:-?}G, MIN_FREE_GB=$MIN_FREE_GB)"
		ok=1
	fi

	printf 'runner version: %s ' "$RUNNER_VERSION"
	if [[ "$(printf '%s\n%s\n' "$MIN_RUNNER_VERSION" "$RUNNER_VERSION" | sort -V | head -1)" == "$MIN_RUNNER_VERSION" ]]; then echo "OK (>= $MIN_RUNNER_VERSION)"; else
		echo "FAIL: below enforced minimum"
		ok=1
	fi

	printf 'auth: '
	if auth_token >/dev/null 2>&1; then echo "OK ($AUTH_MODE)"; else
		echo FAIL
		ok=1
	fi
	printf 'runner admin access: '
	if api GET "$(runners_path)" >/dev/null 2>&1; then echo OK; else
		if [[ "$AUTH_MODE" == app ]]; then
			if [[ "$SCOPE" == org ]]; then
				echo "FAIL: grant the app Organization permissions > Self-hosted runners > Read and write, then accept the request in the org's Installed GitHub Apps"
			else
				echo "FAIL: grant the app Repository permissions > Administration > Read and write, then accept the request under the repo's Installed GitHub Apps"
			fi
		elif [[ "$SCOPE" == org ]]; then
			echo "FAIL: the PAT needs the admin:org scope (and SSO authorization if $GITHUB_ORG enforces it)"
		else
			echo "FAIL: the PAT needs the repo scope"
		fi
		ok=1
	fi

	printf 'public repo exposure: '
	if [[ "$SCOPE" == repo ]]; then
		if [[ "$(api GET "/repos/$GITHUB_REPO" | jq -r .private)" == false ]]; then
			echo "DANGER: $GITHUB_REPO is public; fork PRs execute arbitrary code here"
			ok=1
		else echo OK; fi
	else
		if [[ "$(api GET "/orgs/$GITHUB_ORG/repos?type=public&per_page=1" | jq 'length')" -gt 0 ]]; then
			echo "DANGER: org has public repos; restrict the runner group to private repos"
			ok=1
		else echo OK; fi
	fi

	printf 'host isolation: '
	local nft_rules=""
	nft_rules="$(nft list table inet gha 2>/dev/null)" || nft_rules=""
	if [[ -z "$nft_rules" ]]; then
		echo "not installed (run: $SELF net)"
		ok=1
	elif [[ "$nft_rules" != *'127.0.0.0/8'* ]]; then
		echo "FAIL: loopback not blocked; jobs can reach host services via 10.0.2.2 (re-run: $SELF net)"
		ok=1
	else echo OK; fi

	printf 'slot count: '
	local running
	running=$(systemctl list-units --no-legend --state=active 'gha-vm@*.service' 2>/dev/null | wc -l)
	echo "$running active (see: $SELF capacity)"

	return "$ok"
}

cmd_status() {
	echo "== slots =="
	systemctl list-units --no-pager --no-legend 'gha-vm@*.service' 2>/dev/null || echo "none installed"
	echo
	echo "== live VMs =="
	local d found=0
	for d in "$RUN_DIR"/*/; do
		[[ -d "$d" ]] || continue
		found=1
		printf '%-46s %s\n' "$(basename "$d")" "$(du -sh "$d" 2>/dev/null | cut -f1)"
	done
	((found)) || echo "none"
	echo
	echo "== registered runners ($NAME_PREFIX) =="
	list_runners | jq -r --arg p "$NAME_PREFIX" \
		'select(.name|startswith($p)) | "\(.name)\t\(.status)\tbusy=\(.busy)"' | column -t
}

# --------------------------------------------------------------- install ----

cmd_install() {
	local count="${1:-2}"
	[[ $EUID -eq 0 ]] || die "install must run as root"
	[[ "$count" =~ ^[0-9]+$ && "$count" -ge 1 ]] || die "install needs a slot count >= 1"

	# An explicit count from the operator wins over the profile, but going past
	# what the profile reserved this machine for is worth saying out loud.
	if ((MAX_SLOTS > 0)) && ((count > MAX_SLOTS)); then
		log "WARN: installing $count slots, above MAX_SLOTS=$MAX_SLOTS from profile '$HOST_PROFILE'"
		log "WARN: this host was profiled for other work too; check '$SELF capacity'"
	fi

	# The unit must not depend on a git checkout that can move or change under a
	# running fleet.
	install -d -m 0755 "$LIBEXEC"
	install -m 0755 "$HERE/gha-vm.sh" "$LIBEXEC/gha-vm.sh"
	install -m 0755 "$HERE/gha-job.sh" "$LIBEXEC/gha-job.sh"
	ln -sfn "$LIBEXEC/gha-vm.sh" /usr/local/bin/gha-vm

	local mem_gb
	mem_gb="$(mem_to_gb "$VM_MEM")"

	cat >"$UNIT" <<EOF
[Unit]
Description=Ephemeral GitHub Actions runner VM (slot %i)
After=network-online.target nftables.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=${GHA_USER}
Group=${GHA_USER}
SupplementaryGroups=kvm
Environment=GHA_CONFIG=${CONFIG}
ExecStartPre=+${LIBEXEC}/gha-vm.sh netcheck
ExecStart=${LIBEXEC}/gha-vm.sh run %i
Restart=always
RestartSec=5
TimeoutStopSec=300
KillSignal=SIGTERM
KillMode=mixed

# One runaway slot must not take the host down with it.
MemoryMax=$((mem_gb + 2))G
CPUWeight=50
IOWeight=50

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${STATE_DIR}
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ProtectProc=invisible
RestrictSUIDSGID=true
RestrictNamespaces=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
SystemCallArchitectures=native
LockPersonality=true
MemoryDenyWriteExecute=false
DeviceAllow=/dev/kvm rw

[Install]
WantedBy=multi-user.target
EOF

	cat >"$UPGRADE_UNIT" <<EOF
[Unit]
Description=Rebuild the gha-vm golden image on the latest runner release

[Service]
Type=oneshot
Environment=GHA_CONFIG=${CONFIG}
ExecStart=${LIBEXEC}/gha-vm.sh upgrade
EOF

	cat >"$UPGRADE_TIMER" <<EOF
[Unit]
Description=Weekly gha-vm golden image rebuild

[Timer]
OnCalendar=Sun 03:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

	chown -R "$GHA_USER":"$GHA_USER" "$STATE_DIR"
	systemctl daemon-reload

	# Shrinking the fleet must actually shrink it.
	local u i
	while read -r u; do
		i="${u##*@}"
		i="${i%.service}"
		if [[ "$i" =~ ^[0-9]+$ ]] && ((i > count)); then
			log "removing surplus slot $i"
			systemctl disable --now "gha-vm@${i}.service" >/dev/null 2>&1 || true
		fi
	done < <(systemctl list-unit-files --no-legend 'gha-vm@*.service' 2>/dev/null | awk '{print $1}')

	for i in $(seq 1 "$count"); do systemctl enable --now "gha-vm@${i}.service"; done
	systemctl enable --now gha-vm-upgrade.timer >/dev/null 2>&1 || true

	log "installed $count slots; logs: journalctl -fu 'gha-vm@*'"
	cmd_capacity
}

cmd_uninstall() {
	[[ $EUID -eq 0 ]] || die "uninstall must run as root"
	local u
	while read -r u; do
		[[ -n "$u" ]] || continue
		systemctl disable --now "$u" >/dev/null 2>&1 || true
	done < <(systemctl list-units --no-legend --all 'gha-vm@*.service' 2>/dev/null | awk '{print $1}')
	systemctl disable --now gha-vm-upgrade.timer >/dev/null 2>&1 || true
	rm -f "$UNIT" "$UPGRADE_UNIT" "$UPGRADE_TIMER"
	systemctl daemon-reload
	cmd_clean
	log "units removed; $STATE_DIR, $CONFIG and the nftables rules were left in place"
}

# ------------------------------------------------------------------ main ----

main() {
	local cmd="${1:-}"
	shift || true
	case "$cmd" in
	bootstrap)
		load_config_optional
		cmd_bootstrap "$@"
		;;
	deps)
		load_config_optional
		cmd_deps
		;;
	capacity)
		load_config_optional
		cmd_capacity
		;;
	profile)
		load_config_optional
		cmd_profile
		;;
	image)
		load_config
		cmd_image
		;;
	upgrade)
		load_config
		cmd_upgrade
		;;
	net)
		load_config
		cmd_net
		;;
	run)
		load_config
		cmd_run "$@"
		;;
	netcheck)
		load_config
		cmd_netcheck
		;;
	reap)
		load_config
		cmd_reap
		;;
	clean)
		load_config
		cmd_clean
		;;
	doctor)
		load_config
		cmd_doctor
		;;
	repair)
		load_config
		cmd_repair
		;;
	status)
		load_config
		cmd_status
		;;
	install)
		load_config
		cmd_install "$@"
		;;
	uninstall)
		load_config
		cmd_uninstall
		;;
	*)
		sed -n '2,25p' "$SELF"
		exit 1
		;;
	esac
}

main "$@"
