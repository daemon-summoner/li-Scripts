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
#   gha-vm.sh install [count]   install scripts + systemd units (count defaults to the installed fleet size, else 2)
#   gha-vm.sh uninstall         stop and remove units
#   gha-vm.sh status            slot and runner status
#   gha-vm.sh upgrade [--check] pin the latest runner release, rebuild the image
#   gha-vm.sh rollback          swap golden.qcow2.prev back into place
#   gha-vm.sh drain|undrain [slot|all]   finish the current job, then take no more
#   gha-vm.sh restart [slot|all]         drain, then restart the slot unit(s)
#   gha-vm.sh config [KEY]      effective configuration after profile + defaults
#   gha-vm.sh config-set KEY VALUE|- [FILE]   pin one key (- reads the value from stdin)
#   gha-vm.sh config-unset KEY [FILE]         remove one key
#   gha-vm.sh render            write units + ruleset to GHA_SYSTEMD_DIR/GHA_NFT_CONF
#   gha-vm.sh run <slot>        supervisor loop for one slot (systemd entrypoint)
#   gha-vm.sh netcheck          assert the isolation rules are loaded (ExecStartPre)
#   gha-vm.sh reap | clean [--force]     cleanup
#
# Isolation model: the boundary is the VM, not a namespace. Inside the guest the
# runner can be root, use docker, run privileged containers, whatever. An escape
# from the job lands in a disk image we delete seconds later.
#
# The GitHub credential never enters the guest. This script mints a single-use
# JIT config on the host and hands only that in via a cloud-init seed.
# --- end usage ---

set -Eeuo pipefail

CONFIG="${GHA_CONFIG:-/etc/gha-vm/config.env}"
SELF="$(readlink -f "$0")"
HERE="$(dirname "$SELF")"
APIV="2022-11-28"
MIN_RUNNER_VERSION="2.329.0"
# actions/runner releases live on github.com even for a GHES fleet.
PUBLIC_API="https://api.github.com"

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

# Consecutive JIT mint failures a supervisor tolerates before it exits and
# lets the unit restart it (a restart re-runs netcheck, which refreshes the
# nftables sets). At the default backoff this is five minutes of retries.
JIT_FAILS_BEFORE_RESTART=5

log() { printf '[%(%Y-%m-%dT%H:%M:%S%z)T] %s\n' -1 "$*" >&2; }
die() {
	log "ERROR: $*"
	exit 1
}
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1 (try: $SELF deps)"; }

# ---------------------------------------------------------------- config ----

apply_defaults() {
	# Only x86_64 has been exercised end to end. arm64 is parametrised through
	# the same knobs but has not been booted on real hardware.
	HOST_ARCH="${HOST_ARCH:-$(uname -m)}"
	case "$HOST_ARCH" in
	x86_64 | amd64)
		RUNNER_ARCH="${RUNNER_ARCH:-x64}"
		CLOUDIMG_ARCH="${CLOUDIMG_ARCH:-amd64}"
		QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
		QEMU_MACHINE="${QEMU_MACHINE:-q35,accel=kvm}"
		QEMU_PACKAGE="${QEMU_PACKAGE:-qemu-system-x86}"
		;;
	aarch64 | arm64)
		RUNNER_ARCH="${RUNNER_ARCH:-arm64}"
		CLOUDIMG_ARCH="${CLOUDIMG_ARCH:-arm64}"
		QEMU_BIN="${QEMU_BIN:-qemu-system-aarch64}"
		QEMU_MACHINE="${QEMU_MACHINE:-virt,accel=kvm,gic-version=host}"
		QEMU_PACKAGE="${QEMU_PACKAGE:-qemu-system-arm}"
		;;
	*) die "unsupported HOST_ARCH '$HOST_ARCH' (x86_64 or aarch64)" ;;
	esac
	QEMU_SANDBOX="${QEMU_SANDBOX:-1}"
	QEMU_EXTRA_ARGS="${QEMU_EXTRA_ARGS:-}"

	UBUNTU_RELEASE="${UBUNTU_RELEASE:-26.04}"
	CLOUDIMG_BASE="${CLOUDIMG_BASE:-https://cloud-images.ubuntu.com/releases/${UBUNTU_RELEASE}/release}"
	CLOUDIMG_NAME="${CLOUDIMG_NAME:-ubuntu-${UBUNTU_RELEASE}-server-cloudimg-${CLOUDIMG_ARCH}.img}"

	# GitHub Enterprise Server: set GITHUB_SERVER_URL and the API follows at
	# /api/v3 unless GITHUB_API_URL says otherwise. Trailing slashes are dropped
	# so path concatenation below never doubles them.
	GITHUB_SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}"
	GITHUB_SERVER_URL="${GITHUB_SERVER_URL%/}"
	if [[ -z "${GITHUB_API_URL:-}" ]]; then
		if [[ "$GITHUB_SERVER_URL" == "https://github.com" ]]; then
			GITHUB_API_URL="https://api.github.com"
		else
			GITHUB_API_URL="$GITHUB_SERVER_URL/api/v3"
		fi
	fi
	GITHUB_API_URL="${GITHUB_API_URL%/}"
	RUNNER_DOWNLOAD_BASE="${RUNNER_DOWNLOAD_BASE:-https://github.com/actions/runner/releases/download}"
	RUNNER_DOWNLOAD_BASE="${RUNNER_DOWNLOAD_BASE%/}"

	# Host-side proxy for this script's own curl calls. Exported in both cases
	# because curl reads the lowercase form and most tools the uppercase.
	local pv lv
	for pv in HTTP_PROXY HTTPS_PROXY NO_PROXY; do
		lv="${pv,,}"
		[[ -n "${!pv:-}" || -z "${!lv:-}" ]] || printf -v "$pv" '%s' "${!lv}"
		if [[ -n "${!pv:-}" ]]; then
			export "${pv?}"
			export "$lv=${!pv}"
		fi
	done
	# Proxy baked into the guest (apt, docker, the runner). Empty = none.
	GUEST_HTTP_PROXY="${GUEST_HTTP_PROXY:-}"
	GUEST_NO_PROXY="${GUEST_NO_PROXY:-localhost,127.0.0.1,::1,10.0.2.2}"

	API_MAXTIME="${API_MAXTIME:-30}"
	API_RETRY="${API_RETRY:-3}"

	# Resolvers used only while virt-customize builds the image; the guest's own
	# resolv.conf is restored before the golden is sealed. 169.254.2.3 is the DNS
	# forwarder built into the qemu slirp NAT that libguestfs puts the appliance
	# behind (net=169.254.2.15/16, gateway .2). The public resolvers follow it as
	# a fallback in case that layout changes.
	GUEST_DNS="${GUEST_DNS:-169.254.2.3 1.1.1.1 8.8.8.8}"

	STATE_DIR="${STATE_DIR:-/var/lib/gha-vm}"
	GOLDEN="${GOLDEN:-$STATE_DIR/golden.qcow2}"
	RUN_DIR="${RUN_DIR:-$STATE_DIR/run}"
	GHA_USER="${GHA_USER:-gha}"

	VM_CPUS="${VM_CPUS:-4}"
	VM_MEM="${VM_MEM:-8G}"
	# A bare number means GiB here; qemu -m would read it as MiB.
	[[ "$VM_MEM" =~ ^[0-9]+$ ]] && VM_MEM="${VM_MEM}G"
	VM_DISK="${VM_DISK:-80G}"
	VM_CPU="${VM_CPU:-host}"
	NESTED_VIRT="${NESTED_VIRT:-0}"

	MAX_LIFETIME="${MAX_LIFETIME:-21600}"
	BOOT_TIMEOUT="${BOOT_TIMEOUT:-420}"
	MIN_FREE_GB="${MIN_FREE_GB:-20}"

	# Supervisor lifecycle. STOP_GRACE_SEC is how long a stopping slot lets a
	# running job finish; the unit's TimeoutStopSec is derived from it.
	STOP_GRACE_SEC="${STOP_GRACE_SEC:-900}"
	REAP_ON_STOP="${REAP_ON_STOP:-1}"
	REAP_INTERVAL="${REAP_INTERVAL:-3600}"
	JIT_BACKOFF_MAX="${JIT_BACKOFF_MAX:-600}"
	CLOCK_SYNC_WAIT="${CLOCK_SYNC_WAIT:-120}"

	HOST_RESERVE_GB="${HOST_RESERVE_GB:-8}"
	CPU_OVERCOMMIT="${CPU_OVERCOMMIT:-2}"
	DISK_PER_SLOT_GB="${DISK_PER_SLOT_GB:-30}"

	RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,${RUNNER_ARCH},vm,ephemeral,docker}"
	RUNNER_LABELS_APPEND_HOST="${RUNNER_LABELS_APPEND_HOST:-1}"
	RUNNER_GROUP_ID="${RUNNER_GROUP_ID:-1}"
	RUNNER_GROUP="${RUNNER_GROUP:-}"
	NAME_PREFIX="${NAME_PREFIX:-gha-$(hostname -s)}"
	ALLOW_UNVERIFIED_RUNNER="${ALLOW_UNVERIFIED_RUNNER:-0}"
	AUTO_RUNNER_VERSION="${AUTO_RUNNER_VERSION:-1}"
	UPGRADE_REBUILD="${UPGRADE_REBUILD:-always}"
	SPARSIFY="${SPARSIFY:-1}"
	APT_LOCK_WAIT="${APT_LOCK_WAIT:-120}"
	APT_LOCK_TRIES="${APT_LOCK_TRIES:-5}"
	REQUIRE_ISOLATION="${REQUIRE_ISOLATION:-1}"

	# Egress filter. NET_ALLOW_CIDRS punches holes (a LAN mirror, a registry);
	# the two BLOCK knobs add the non-routable ranges and the host's own
	# addresses to the drop list.
	NET_ALLOW_CIDRS="${NET_ALLOW_CIDRS:-}"
	NET_BLOCK_EXTRA="${NET_BLOCK_EXTRA:-1}"
	NET_BLOCK_HOST_ADDRS="${NET_BLOCK_HOST_ADDRS:-1}"
	NET_DNS_ADDRS="${NET_DNS_ADDRS:-}"
	NET_HOST_ADDRS="${NET_HOST_ADDRS:-}"
	NET_ENDPOINT_ADDRS="${NET_ENDPOINT_ADDRS:-}"

	# Golden image build and swap.
	GUEST_PACKAGES="${GUEST_PACKAGES:-docker.io,git,jq,curl,unzip,zip,ca-certificates,build-essential,rsync,gnupg}"
	GUEST_EXTRA_PACKAGES="${GUEST_EXTRA_PACKAGES:-}"
	IMAGE_HOOK_DIR="${IMAGE_HOOK_DIR:-$(dirname "$CONFIG")/image.d}"
	GUEST_PRE_JOB_HOOK="${GUEST_PRE_JOB_HOOK:-}"
	GUEST_RUNTIME_DNS="${GUEST_RUNTIME_DNS:-}"
	IMAGE_SELFTEST="${IMAGE_SELFTEST:-1}"
	GOLDEN_KEEP_PREVIOUS="${GOLDEN_KEEP_PREVIOUS:-1}"
	GOLDEN_MAX_AGE_DAYS="${GOLDEN_MAX_AGE_DAYS:-21}"

	# Host OS maintenance.
	HOST_UNATTENDED="${HOST_UNATTENDED:-1}"
	HOST_AUTO_REBOOT="${HOST_AUTO_REBOOT:-0}"
	HOST_AUTO_REBOOT_TIME="${HOST_AUTO_REBOOT_TIME:-04:30}"

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
#
# Only a HOST_PROFILE the operator set counts as explicit. The value from an
# earlier detection in this process is re-detected, so a profile that `deps`
# installed moments ago (bootstrap runs deps, then capacity) is picked up.
_HOST_PROFILE_DETECTED=""
detect_host_profile() { # sets HOST_PROFILE
	local id
	[[ -n "${HOST_PROFILE:-}" && "$HOST_PROFILE" != "$_HOST_PROFILE_DETECTED" ]] && return 0
	id="$(cat /etc/machine-id 2>/dev/null || true)"
	if [[ -n "$id" && -r "$PROFILE_DIR/$id.env" ]]; then
		_HOST_PROFILE_DETECTED="$id"
	else
		_HOST_PROFILE_DETECTED="$(hostname -s)"
	fi
	HOST_PROFILE="$_HOST_PROFILE_DETECTED"
}

# Sourced after config.env so a profile wins over it, and before apply_defaults
# so the defaults still fill whatever neither file set. local.env is sourced
# last: it is the per-host override that setup.sh writes sizing answers to,
# and `deps` never overwrites it when it refreshes the shipped profiles.
load_profile() {
	local f chosen
	detect_host_profile
	chosen="$HOST_PROFILE"
	PROFILE_FILE=""
	LOCAL_FILE="$PROFILE_DIR/local.env"
	for f in "$PROFILE_DIR/$HOST_PROFILE.env" "$PROFILE_DIR/default.env"; do
		if [[ -r "$f" ]]; then
			PROFILE_FILE="$f"
			source_profile_file "$f" "$chosen"
			break
		fi
	done
	[[ -r "$LOCAL_FILE" ]] && source_profile_file "$LOCAL_FILE" "$chosen"
	return 0
}

# Sources one profile file. The files describe a host; which one applies was
# decided by the caller, so a HOST_PROFILE line inside is reverted to $2.
source_profile_file() {
	# shellcheck disable=SC1090
	source "$1"
	if [[ "$HOST_PROFILE" != "$2" ]]; then
		log "WARN: $1 sets HOST_PROFILE=$HOST_PROFILE; ignored, '$2' stays in effect"
		HOST_PROFILE="$2"
	fi
}

# A box that already runs other services cannot lend the runners its whole RAM.
# Raise the reserve to cover what is resident right now, so capacity reflects
# real spare memory rather than the nameplate. Only ever raises: a profile that
# sets a bigger reserve by hand keeps it.
autotune_reserve() {
	((AUTOTUNE)) || return 0
	local total avail used want k
	for k in HOST_RESERVE_GB AUTOTUNE_HEADROOM_GB; do
		[[ "${!k}" =~ ^[0-9]+$ ]] || die "$k must be a whole number of GiB (got '${!k}')"
	done
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

	validate_sizing
}

# Sizing values feed qemu and integer arithmetic; a typo here otherwise shows
# up as a division by zero in capacity or a qemu usage error on every cycle.
validate_sizing() {
	[[ "$VM_MEM" =~ ^[0-9]+[MGmg]?$ ]] || die "VM_MEM must be like 8G or 8192M (got '$VM_MEM')"
	[[ "$VM_CPUS" =~ ^[1-9][0-9]*$ ]] || die "VM_CPUS must be a positive integer (got '$VM_CPUS')"
	[[ "$VM_DISK" =~ ^[0-9]+[MGTmgt]$ ]] || die "VM_DISK must be like 80G (got '$VM_DISK')"
	(($(mem_to_mb "$VM_MEM") > 0)) || die "VM_MEM must be above zero (got '$VM_MEM')"
	[[ "$RUNNER_GROUP_ID" =~ ^[0-9]+$ ]] || die "RUNNER_GROUP_ID must be a number (got '$RUNNER_GROUP_ID')"
	local k
	for k in STOP_GRACE_SEC REAP_INTERVAL JIT_BACKOFF_MAX CLOCK_SYNC_WAIT BOOT_TIMEOUT MAX_LIFETIME MIN_FREE_GB \
		HOST_RESERVE_GB AUTOTUNE_HEADROOM_GB CPU_OVERCOMMIT MAX_SLOTS API_RETRY API_MAXTIME; do
		[[ "${!k}" =~ ^[0-9]+$ ]] || die "$k must be a whole number (got '${!k}')"
	done
	[[ "$DISK_PER_SLOT_GB" =~ ^[1-9][0-9]*$ ]] || die "DISK_PER_SLOT_GB must be a positive integer (got '$DISK_PER_SLOT_GB')"
	local u
	for u in GITHUB_SERVER_URL GITHUB_API_URL RUNNER_DOWNLOAD_BASE; do
		[[ "${!u}" == https://* ]] || die "$u must start with https:// (got '${!u}')"
	done
}

mem_to_mb() { # accepts 8G / 8192M / 8 (bare = GiB)
	local v="${1^^}"
	case "$v" in
	*G) printf '%s' "$((${v%G} * 1024))" ;;
	*M) printf '%s' "${v%M}" ;;
	*) printf '%s' "$((v * 1024))" ;;
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

	local jwt inst_url inst_id perms resp code target
	jwt="$(_app_jwt)"
	# The two JIT-runner endpoints want different permissions, and asking for one
	# the installation does not hold is a 422 rather than a smaller token.
	#   org  -> Organization permissions: "Self-hosted runners" (write)
	#   repo -> Repository permissions:   "Administration" (write)
	if [[ "$SCOPE" == org ]]; then
		inst_url="$GITHUB_API_URL/orgs/$GITHUB_ORG/installation"
		perms='{"permissions":{"organization_self_hosted_runners":"write"}}'
		target="organization '$GITHUB_ORG'"
	else
		inst_url="$GITHUB_API_URL/repos/$GITHUB_REPO/installation"
		perms='{"permissions":{"administration":"write"}}'
		target="repository '$GITHUB_REPO'"
	fi

	# -f would collapse "app is not installed" (404), "GitHub rejected the key or
	# the app id" (401) and a GitHub outage (5xx) into one exit code, and each one
	# needs a different fix. Keep the status and say which happened.
	resp=$(curl_bearer "$jwt" --max-time "$API_MAXTIME" --retry "$API_RETRY" --retry-delay 2 \
		--retry-connrefused -w '\n%{http_code}' "$inst_url") ||
		die "could not reach $inst_url"
	code="${resp##*$'\n'}"
	resp="${resp%$'\n'*}"
	case "$code" in
	200) ;;
	401) die "GitHub rejected the app credentials for app id '$GITHUB_APP_ID'
(HTTP 401: $(jq -r '.message // empty' <<<"$resp")).
The key in $GITHUB_APP_KEY no longer matches the app, or GITHUB_APP_ID is wrong.
Generate a fresh private key on the app's settings page and replace that file." ;;
	404) die "GitHub App id '$GITHUB_APP_ID' is not installed on $target (HTTP 404).
The app authenticated, so its id and key are fine -- the installation is gone.
Either it was uninstalled, or $target was renamed or deleted.
Re-install it from the app's 'Install App' page, then confirm it is listed under
that account's Installed GitHub Apps. Update GITHUB_ORG/GITHUB_REPO in $CONFIG
if the name changed." ;;
	*) die "unexpected HTTP $code from $inst_url: $(jq -r '.message // .' <<<"$resp")" ;;
	esac

	inst_id=$(jq -r '.id' <<<"$resp")
	[[ -n "$inst_id" && "$inst_id" != null ]] ||
		die "no installation id in GitHub's reply for $target: $resp"

	resp=$(curl_bearer "$jwt" -f --max-time "$API_MAXTIME" -X POST -d "$perms" \
		"$GITHUB_API_URL/app/installations/$inst_id/access_tokens") ||
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

CURL_OPTS=(--proto '=https' --tlsv1.2 --connect-timeout 10)

# The bearer header goes in on stdin (-H @-), so the token never sits on a
# command line that /proc exposes to every user on the host.
curl_bearer() {
	local tok="$1"
	shift
	printf 'Authorization: Bearer %s\n' "$tok" |
		curl -sS "${CURL_OPTS[@]}" -H @- -H "Accept: application/vnd.github+json" \
			-H "X-GitHub-Api-Version: $APIV" "$@"
}

api() {
	local method="$1" path="$2" body="${3:-}" tok resp code hdr ra
	# auth_token dies inside a command substitution, so its status must be tested
	# here: bash suppresses set -e for the whole call tree whenever a caller tests
	# the result (`if ! jit="$(mint_jit ...)"`), and going on regardless would send
	# an empty bearer token -- surfacing GitHub's 401 in place of the real reason.
	tok="$(auth_token)" || return 1
	[[ -n "$tok" ]] || die "auth_token returned an empty token"

	local opts=(--max-time "$API_MAXTIME" -X "$method" -w '\n%{http_code}')
	if [[ -n "$body" ]]; then
		# No --retry on writes: a lost response would double-register a runner.
		opts+=(-d "$body")
	elif ((API_RETRY > 0)); then
		opts+=(--retry "$API_RETRY" --retry-delay 2 --retry-connrefused)
	fi
	hdr="$(mktemp)" || {
		log "api: $method $path: could not create a temp file for the response headers"
		return 1
	}
	if ! resp="$(curl_bearer "$tok" -D "$hdr" "${opts[@]}" "$GITHUB_API_URL$path")"; then
		rm -f "$hdr"
		log "api: $method $path: request failed (no HTTP status)"
		return 1
	fi
	code="${resp##*$'\n'}"
	resp="${resp%$'\n'*}"
	case "$code" in
	2??)
		rm -f "$hdr"
		printf '%s' "$resp"
		;;
	*)
		ra=""
		if [[ "$code" == 403 || "$code" == 429 ]]; then
			ra="$(awk 'tolower($1)=="retry-after:"{print $2}' "$hdr" | tr -d '\r')"
		fi
		rm -f "$hdr"
		log "api: $method $path -> HTTP $code${ra:+ (retry-after ${ra}s)}: $(jq -r '.message // empty' <<<"$resp" 2>/dev/null | head -c 200)"
		return 1
		;;
	esac
}

runners_path() {
	if [[ "$SCOPE" == org ]]; then
		printf '/orgs/%s/actions/runners' "$GITHUB_ORG"
	else printf '/repos/%s/actions/runners' "$GITHUB_REPO"; fi
}

# One JSON object per line. Paginates: a two-host fleet plus stale registrations
# passes 100 entries sooner than it looks. Callers capture the output into a
# variable first, so an API failure is a logged non-zero status and never
# reads as "no runners registered".
list_runners() {
	local page=1 resp n
	while ((page <= 20)); do
		resp=$(api GET "$(runners_path)?per_page=100&page=$page") || return 1
		jq -c '.runners[]' <<<"$resp"
		n=$(jq '.runners|length' <<<"$resp")
		if ((n < 100)); then break; fi
		page=$((page + 1))
	done
}

# Labels as a JSON array: trimmed, empties dropped, duplicates collapsed, with
# the host's short name appended when RUNNER_LABELS_APPEND_HOST=1 so a workflow
# can pin one machine with runs-on: [self-hosted, <hostname>].
runner_labels_json() {
	local l="$RUNNER_LABELS"
	[[ "$RUNNER_LABELS_APPEND_HOST" == 1 ]] && l+=",$(hostname -s)"
	jq -nc --arg l "$l" \
		'$l | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | unique'
}

# Resolves RUNNER_GROUP (a name) into _RG_ID once per process; RUNNER_GROUP_ID
# is the fallback and the only option for repo scope, which has no groups.
# Returns 1 when the API call fails and 2 when the group does not exist, so a
# mint can back off and retry instead of the supervisor exiting.
_RG_ID=""
runner_group_id() {
	[[ -z "$_RG_ID" ]] || return 0
	if [[ -z "$RUNNER_GROUP" || "$SCOPE" != org ]]; then
		_RG_ID="$RUNNER_GROUP_ID"
		return 0
	fi
	local resp id
	resp="$(api GET "/orgs/$GITHUB_ORG/actions/runner-groups?per_page=100")" || return 1
	id="$(jq -r --arg n "$RUNNER_GROUP" '.runner_groups[] | select(.name == $n) | .id' <<<"$resp" | head -n1)"
	[[ "$id" =~ ^[0-9]+$ ]] || {
		log "ERROR: runner group '$RUNNER_GROUP' not found in organization $GITHUB_ORG"
		return 2
	}
	_RG_ID="$id"
}

mint_jit() {
	local name="$1" body gid labels
	runner_group_id || return 1
	gid="$_RG_ID"
	labels="$(runner_labels_json)"
	body=$(jq -nc --arg n "$name" --argjson l "$labels" --argjson g "$gid" \
		'{name:$n, runner_group_id:$g, labels:$l, work_folder:"_work"}')
	api POST "$(runners_path)/generate-jitconfig" "$body" | jq -er '.encoded_jit_config'
}

# ------------------------------------------------------------------ deps ----

# Host packages, one per line; the qemu and firmware packages follow HOST_ARCH,
# so this reads after apply_defaults.
deps_packages() {
	local fw=ovmf
	[[ "$RUNNER_ARCH" == arm64 ]] && fw=qemu-efi-aarch64
	printf '%s\n' \
		"$QEMU_PACKAGE" qemu-utils "$fw" \
		cloud-image-utils guestfs-tools \
		nftables curl jq openssl ca-certificates gpgv util-linux bsdextrautils iproute2 \
		ubuntu-cloudimage-keyring \
		isc-dhcp-client
	# isc-dhcp-client: the libguestfs appliance runs dhclient to bring its NIC
	# up, and supermin only copies in binaries from packages listed in its own
	# supermin.d/packages -- which names isc-dhcp-client, no longer part of a
	# default Ubuntu install. Without it the build appliance has loopback only,
	# and every apt fetch inside virt-customize fails as "Temporary failure
	# resolving".
}

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

# True when the CPU advertises hardware virtualization. On arm64 the flag is
# not in cpuinfo; /dev/kvm existing is the only signal.
cpu_has_virt() {
	if [[ "$RUNNER_ARCH" == x64 ]]; then
		grep -qm1 -E '^flags.*\b(vmx|svm)\b' /proc/cpuinfo
	else
		[[ -c /dev/kvm ]]
	fi
}

setup_kvm() {
	local kmod
	if [[ "$RUNNER_ARCH" == arm64 ]]; then
		# KVM is built into the arm64 kernel; there is no module to load.
		[[ -c /dev/kvm ]] || die "no /dev/kvm on this arm64 host; the firmware or hypervisor is not exposing virtualization"
		log "kvm ready (built-in)"
		return 0
	fi
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
# systemd-time-wait-sync makes time-sync.target mean "synchronized", which the
# slot units order after, so the first JWT after a reboot is minted on real time.
setup_timesync() {
	if ! systemctl is-active --quiet chrony ntpsec systemd-timesyncd 2>/dev/null; then
		apt_get install -y --no-install-recommends systemd-timesyncd
		systemctl enable --now systemd-timesyncd.service
	fi
	if systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
		systemctl enable systemd-time-wait-sync.service >/dev/null 2>&1 ||
			log "WARN: could not enable systemd-time-wait-sync.service; slots may mint a JWT before the clock is synced after a reboot"
	fi
	if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" != yes ]]; then
		log "WARN: clock is not NTP-synchronized yet; GitHub App auth fails on skew"
	else
		log "clock synchronized"
	fi
}

# Security updates on the host itself, with the reboot left to the operator
# unless HOST_AUTO_REBOOT=1. A reboot stops the slot units, which drain: a
# running job gets STOP_GRACE_SEC to finish before the VM is killed.
setup_unattended() {
	local conf=/etc/apt/apt.conf.d/52gha-vm reboot=false when=""
	if [[ "$HOST_UNATTENDED" != 1 ]]; then
		rm -f "$conf"
		log "HOST_UNATTENDED=0: host packages are not updated automatically"
		return 0
	fi
	command -v unattended-upgrade >/dev/null 2>&1 ||
		apt_get install -y --no-install-recommends unattended-upgrades
	if [[ "$HOST_AUTO_REBOOT" == 1 ]]; then
		reboot=true
		when=" at $HOST_AUTO_REBOOT_TIME"
	fi
	[[ "$HOST_AUTO_REBOOT_TIME" =~ ^[0-2][0-9]:[0-5][0-9]$ ]] ||
		die "HOST_AUTO_REBOOT_TIME must be HH:MM (got '$HOST_AUTO_REBOOT_TIME')"
	cat >"$conf" <<EOF
// Written by gha-vm.sh deps; edit config.env and re-run deps or repair.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "$reboot";
Unattended-Upgrade::Automatic-Reboot-Time "$HOST_AUTO_REBOOT_TIME";
EOF
	systemctl enable --now unattended-upgrades.service >/dev/null 2>&1 ||
		log "WARN: could not enable unattended-upgrades.service"
	log "host security updates: unattended (auto-reboot: $reboot$when)"
}

cmd_deps() {
	[[ $EUID -eq 0 ]] || die "deps must run as root"

	local id_like=""
	# shellcheck disable=SC1091
	[[ -r /etc/os-release ]] && id_like="$(. /etc/os-release && printf '%s %s' "${ID:-}" "${ID_LIKE:-}")"
	[[ "$id_like" == *ubuntu* || "$id_like" == *debian* ]] ||
		die "deps targets Ubuntu (found: ${id_like:-unknown}); install the packages in DEPS_PACKAGES by hand"

	setup_kvm

	local had_dhclient=0
	if command -v dhclient >/dev/null 2>&1; then had_dhclient=1; fi

	export DEBIAN_FRONTEND=noninteractive
	local pkgs=()
	mapfile -t pkgs < <(deps_packages)
	apt_get update
	ensure_apt_components "${pkgs[@]}"
	apt_get install -y --no-install-recommends "${pkgs[@]}"

	# supermin bakes the host's installed packages into a cached appliance under
	# /var/tmp. An appliance built before dhclient existed has no way to bring its
	# NIC up, and every apt fetch inside virt-customize then fails as "Temporary
	# failure resolving" -- so discard it and let the next image build rebuild.
	if ((had_dhclient == 0)) && command -v dhclient >/dev/null 2>&1; then
		log "discarding the cached libguestfs appliance so it picks up dhclient"
		rm -rf /var/tmp/.guestfs-*
	fi

	setup_timesync
	setup_unattended
	systemctl enable nftables.service >/dev/null 2>&1 ||
		log "WARN: could not enable nftables.service; isolation rules will not survive a reboot"

	id -u "$GHA_USER" >/dev/null 2>&1 ||
		useradd -r -m -d "$STATE_DIR" -s /usr/sbin/nologin "$GHA_USER"
	usermod -aG kvm "$GHA_USER"

	install -d -o "$GHA_USER" -g "$GHA_USER" -m 0750 "$STATE_DIR" "$RUN_DIR"
	install -d -o root -g "$GHA_USER" -m 0750 "$(dirname "$CONFIG")" "$IMAGE_HOOK_DIR"

	if [[ ! -e "$CONFIG" && -r "$HERE/config.vm.env.example" ]]; then
		install -o root -g "$GHA_USER" -m 0640 "$HERE/config.vm.env.example" "$CONFIG"
		log "wrote config skeleton: $CONFIG"
	fi

	# Profiles ship in the checkout so one tree serves the whole fleet; each host
	# loads only the one matching its own name or machine-id. local.env is the
	# host's own file and is never touched here.
	install -d -o root -g "$GHA_USER" -m 0750 "$PROFILE_DIR"
	if [[ -d "$HERE/profiles" ]]; then
		local p
		for p in "$HERE"/profiles/*.env; do
			[[ -e "$p" ]] || continue
			[[ "$(basename "$p")" == local.env ]] && continue
			install -o root -g "$GHA_USER" -m 0640 "$p" "$PROFILE_DIR/"
		done
		log "installed profiles: $(find "$PROFILE_DIR" -name '*.env' -printf '%f ' 2>/dev/null)"
	fi
	# Re-resolve now that the files exist; deps sourced the config before this.
	local before="$HOST_PROFILE"
	load_profile
	apply_defaults
	log "this host matches profile '$HOST_PROFILE'${PROFILE_FILE:+ ($PROFILE_FILE)}"
	[[ "$before" == "$HOST_PROFILE" ]] ||
		log "WARN: the profile changed from '$before' during deps; values it set earlier stay until the next command"

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
	local c v pkg=ovmf
	local -a cands=(/usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd)
	if [[ "$RUNNER_ARCH" == arm64 ]]; then
		cands=(/usr/share/AAVMF/AAVMF_CODE.fd)
		pkg=qemu-efi-aarch64
	fi
	for c in "${cands[@]}"; do
		v="${c/CODE/VARS}"
		[[ "$c" == */ovmf/OVMF.fd ]] && v=/usr/share/ovmf/OVMF_VARS.fd
		if [[ -r "$c" && -r "$v" ]]; then
			printf '%s\n%s\n' "$c" "$v"
			return
		fi
	done
	die "no matching UEFI CODE/VARS pair found (apt install $pkg)"
}

# GET against api.github.com for the actions/runner release metadata. The
# fleet's own token is used when it is valid there; on GHES it is not, so the
# request goes out unauthenticated (60/h, plenty for a weekly timer).
public_get() {
	local path="$1"
	if [[ "$GITHUB_API_URL" == "$PUBLIC_API" ]]; then
		api GET "$path" && return 0
		log "public api: authenticated request failed, retrying unauthenticated"
	fi
	curl -fsS "${CURL_OPTS[@]}" --max-time "$API_MAXTIME" --retry "$API_RETRY" --retry-delay 2 \
		-H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: $APIV" "$PUBLIC_API$path"
}

# The release notes carry one machine-readable block per asset:
#   <!-- BEGIN SHA linux-x64 -->hex<!-- END SHA linux-x64 -->
# The loose grep after it covers older notes that only had the hash in prose.
runner_asset_sha() {
	local ver="$1" body sha
	body="$(public_get "/repos/actions/runner/releases/tags/v${ver}" | jq -r '.body')" || return 1
	sha="$(grep -oE "<!-- BEGIN SHA linux-${RUNNER_ARCH} -->[0-9a-fA-F]{64}" <<<"$body" |
		grep -oE '[0-9a-fA-F]{64}' | head -n1)"
	[[ -n "$sha" ]] ||
		sha="$(grep -iA2 "actions-runner-linux-${RUNNER_ARCH}-${ver}\.tar\.gz" <<<"$body" |
			grep -oiE '[0-9a-f]{64}' | head -n1)"
	[[ -n "$sha" ]] || return 1
	printf '%s' "${sha,,}"
}

latest_runner_version() {
	public_get "/repos/actions/runner/releases/latest" | jq -er '.tag_name' | sed 's/^v//'
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

# The cloud image has no working /etc/resolv.conf offline: systemd-resolved owns
# it and creates it at boot, so inside the libguestfs chroot it is either absent
# or a symlink into /run that nothing populates. Apt then resolves nothing, treats
# that as a warning, and falls back to the image's stale main-only indexes --
# so the build dies much later on a universe package with no candidate. Point at
# real resolvers and promote apt's fetch warnings to errors, so a broken resolver
# fails here with the resolver error as the message.
#
# Whatever was there is kept aside for restore_guest_dns; -e is false for a
# dangling symlink, hence the -L companion test. Arguments after the image are
# passed to virt-customize first (the guest proxy, so apt can reach out at all).
fix_guest_dns() {
	local img="$1"
	shift
	virt-customize -a "$img" "$@" \
		--run-command "if [ -e /etc/resolv.conf ] || [ -L /etc/resolv.conf ]; then \
            mv /etc/resolv.conf /etc/resolv.conf.gha-orig; fi \
        && for ns in $GUEST_DNS; do echo \"nameserver \$ns\" >>/etc/resolv.conf; done" \
		--run-command 'apt-get -q update -o APT::Update::Error-Mode=any' \
		>/dev/null && return 0

	# apt only ever says "Temporary failure resolving", which covers both no route
	# out of the appliance and a resolver that never answers. Print enough to tell
	# those apart instead of leaving the next person to guess.
	log "guest name resolution failed; appliance network state follows"
	virt-customize -a "$img" --run-command \
		'echo "--- addresses"; ip -o addr show
echo "--- routes"; ip route show
echo "--- resolv.conf"; cat /etc/resolv.conf' >&2 ||
		log "could not collect the appliance network state"
	die "guest name resolution failed during image build (GUEST_DNS='$GUEST_DNS')"
}

# Own virt-customize run rather than a trailing --run-command in the build: this
# has to land strictly after every network-using operation, and only ordering
# between whole invocations is guaranteed. Leaving the build resolvers in place
# would hardcode them into every runner VM. When the image shipped no
# /etc/resolv.conf at all, the correct restore is to leave none: systemd-resolved
# writes it at boot.
restore_guest_dns() {
	virt-customize -a "$1" \
		--run-command 'rm -f /etc/resolv.conf
if [ -e /etc/resolv.conf.gha-orig ] || [ -L /etc/resolv.conf.gha-orig ]; then
    mv /etc/resolv.conf.gha-orig /etc/resolv.conf
fi' \
		>/dev/null || die "could not restore the guest's original /etc/resolv.conf"
}

# Cloud image cache. SHA256SUMS and its signature are fetched on every build
# (they are tiny), so a cached base that no longer matches -- a corrupted
# download, a moved release directory -- is caught and replaced rather than
# baked into the next golden.
fetch_cloud_image() {
	local work="$1" base="$2" want sums
	sums="$work/SHA256SUMS"
	local f
	for f in SHA256SUMS SHA256SUMS.gpg; do
		curl -fsSL "${CURL_OPTS[@]}" --max-time 120 --retry 3 -o "$work/$f.part" "$CLOUDIMG_BASE/$f" ||
			die "could not download $f from $CLOUDIMG_BASE"
	done
	mv -f "$sums.part" "$sums"
	mv -f "$sums.gpg.part" "$sums.gpg"
	gpgv --keyring /usr/share/keyrings/ubuntu-cloudimage-keyring.gpg "$sums.gpg" "$sums" ||
		die "SHA256SUMS signature check failed"
	want="$(awk -v n="$CLOUDIMG_NAME" '{ f = $2; sub(/^\*/, "", f) } f == n { print $1; exit }' "$sums")"
	[[ -n "$want" ]] || die "$CLOUDIMG_NAME is not listed in $CLOUDIMG_BASE/SHA256SUMS (check CLOUDIMG_NAME)"

	if [[ -f "$base" ]]; then
		if [[ "$(sha256sum "$base" | cut -d' ' -f1)" == "$want" ]]; then
			log "cached cloud image verified: $CLOUDIMG_NAME"
			return 0
		fi
		log "cached $CLOUDIMG_NAME no longer matches SHA256SUMS; downloading it again"
		rm -f "$base"
	fi
	log "downloading $CLOUDIMG_NAME"
	curl -fSL "${CURL_OPTS[@]}" --retry 3 --progress-bar -o "$base.part" "$CLOUDIMG_BASE/$CLOUDIMG_NAME"
	[[ "$(sha256sum "$base.part" | cut -d' ' -f1)" == "$want" ]] || {
		rm -f "$base.part"
		die "cloud image checksum mismatch"
	}
	mv -f "$base.part" "$base"
	log "cloud image signature and checksum OK"
}

# Proxy settings baked into the guest: apt, docker and the runner all read
# /etc/gha-proxy.env, and login shells get /etc/environment. Arguments are
# NUL-separated because the file contents span lines.
guest_proxy_args() {
	[[ -n "$GUEST_HTTP_PROXY" ]] || return 0
	local env
	env="$(printf 'HTTP_PROXY=%s\nHTTPS_PROXY=%s\nNO_PROXY=%s\nhttp_proxy=%s\nhttps_proxy=%s\nno_proxy=%s\n' \
		"$GUEST_HTTP_PROXY" "$GUEST_HTTP_PROXY" "$GUEST_NO_PROXY" \
		"$GUEST_HTTP_PROXY" "$GUEST_HTTP_PROXY" "$GUEST_NO_PROXY")"
	printf '%s\0' \
		--write "/etc/gha-proxy.env:$env" \
		--write "/etc/apt/apt.conf.d/90gha-proxy:Acquire::http::Proxy \"$GUEST_HTTP_PROXY\";
Acquire::https::Proxy \"$GUEST_HTTP_PROXY\";" \
		--run-command "grep -qxF -f /etc/gha-proxy.env /etc/environment 2>/dev/null || cat /etc/gha-proxy.env >>/etc/environment" \
		--mkdir /etc/systemd/system/docker.service.d \
		--write "/etc/systemd/system/docker.service.d/proxy.conf:[Service]
EnvironmentFile=/etc/gha-proxy.env"
}

# Operator hooks: every executable *.sh under IMAGE_HOOK_DIR runs inside the
# image after the packages land, in name order. A non-executable file is
# skipped, which is how a hook is parked without deleting it.
# Each hook is uploaded and run with the guest proxy exported, so a hook that
# fetches something works on a proxy-only network.
image_hook_args() {
	local f n=0 g
	[[ -d "$IMAGE_HOOK_DIR" ]] || return 0
	for f in "$IMAGE_HOOK_DIR"/*.sh; do
		[[ -f "$f" && -x "$f" ]] || continue
		n=$((n + 1))
		g="/tmp/gha-hook-$n.sh"
		printf '%s\0' --upload "$f:$g" \
			--run-command "set -a; [ ! -r /etc/gha-proxy.env ] || . /etc/gha-proxy.env; set +a; chmod 0755 $g && $g && rm -f $g"
	done
}

# Boots the freshly built image once with a self-test seed and requires the
# guest to report back within BOOT_TIMEOUT. An image that cannot start its
# runner is refused here, with the old golden still in place.
image_selftest() {
	local img="$1" d="$STATE_DIR/build/selftest" pair code vars pid started=0 elapsed=0 ok=0
	rm -rf "$d"
	install -d -m 0700 "$d"
	pair="$(ovmf_pair)"
	code="$(sed -n 1p <<<"$pair")"
	vars="$(sed -n 2p <<<"$pair")"

	printf '#cloud-config\nhostname: gha-selftest\nusers: []\ndisable_root: true\nssh_pwauth: false\nwrite_files:\n  - path: /run/gha-selftest\n    permissions: "0600"\n    content: "1\\n"\nruncmd:\n  - [ /usr/local/bin/gha-job.sh ]\n' >"$d/user-data"
	printf 'instance-id: gha-selftest\nlocal-hostname: gha-selftest\n' >"$d/meta-data"
	cloud-localds "$d/seed.img" "$d/user-data" "$d/meta-data"
	qemu-img create -q -f qcow2 -F qcow2 -b "$img" "$d/disk.qcow2" >/dev/null
	cp "$vars" "$d/vars.fd"
	: >"$d/console.log"

	build_qemu_args gha-selftest "$d" "$code" "$(guest_cpu_model)"
	log "selftest: booting the new image (timeout ${BOOT_TIMEOUT}s)"
	"$QEMU_BIN" "${QEMU_ARGS[@]}" 8>&- &
	pid=$!
	started=$(date +%s)
	while kill -0 "$pid" 2>/dev/null; do
		sleep 3
		elapsed=$(($(date +%s) - started))
		if grep -qF 'GHA-VM: selftest ok' "$d/console.log" 2>/dev/null; then
			ok=1
			break
		fi
		((elapsed > BOOT_TIMEOUT)) && break
	done
	if ((ok)); then
		wait_pid "$pid" 60 || kill -KILL "$pid" 2>/dev/null || true
	else
		kill -KILL "$pid" 2>/dev/null || true
	fi
	wait "$pid" 2>/dev/null || true
	if ((ok == 0)); then
		log "selftest: no 'GHA-VM: selftest ok' within ${elapsed}s; last console lines:"
		tail -n 20 "$d/console.log" >&2 || true
		rm -rf "$d"
		die "the new image failed its boot self-test; the current golden was left untouched (IMAGE_SELFTEST=0 skips this)"
	fi
	rm -rf "$d"
	log "selftest: new image booted and started the runner in ${elapsed}s"
}

cmd_image() {
	[[ $EUID -eq 0 ]] || die "image must run as root"
	need qemu-img
	need virt-customize
	need virt-df
	need curl
	need jq
	need gpgv
	if [[ "$IMAGE_SELFTEST" == 1 ]]; then
		need "$QEMU_BIN"
		need cloud-localds
	fi
	[[ -r /usr/share/keyrings/ubuntu-cloudimage-keyring.gpg ]] ||
		die "missing /usr/share/keyrings/ubuntu-cloudimage-keyring.gpg (apt install ubuntu-cloudimage-keyring)"
	# supermin builds the build appliance out of packages installed on THIS host,
	# so a missing dhclient here leaves the appliance with loopback only. Caught up
	# front because the symptom is an unrelated-looking apt resolver error.
	command -v dhclient >/dev/null 2>&1 ||
		die "missing dhclient, which the libguestfs build appliance needs to get an
address (apt install isc-dhcp-client, or re-run: $SELF deps).
Then discard the cached appliance: rm -rf /var/tmp/.guestfs-*"

	local job_src="$HERE/gha-job.sh"
	[[ -r "$job_src" ]] || job_src="$LIBEXEC/gha-job.sh"
	[[ -r "$job_src" ]] || die "gha-job.sh not found next to $SELF or in $LIBEXEC"
	if [[ -n "$GUEST_PRE_JOB_HOOK" ]]; then
		[[ -r "$GUEST_PRE_JOB_HOOK" ]] || die "GUEST_PRE_JOB_HOOK is not readable: $GUEST_PRE_JOB_HOOK"
	fi

	local work base rsha tmp
	work="$STATE_DIR/build"
	base="$work/$CLOUDIMG_NAME"
	tmp="$work/golden.building.qcow2"
	install -d -m 0750 "$work"

	# The weekly timer and a hand-run `image` must not build on top of each
	# other's half-written file.
	exec 8>"$STATE_DIR/.image.lock"
	flock -n 8 || die "another image build is already running (see: systemctl status gha-vm-upgrade.service)"
	# shellcheck disable=SC2064
	trap "rm -f '$tmp' '$base.part'; rm -rf '$work/selftest'" EXIT

	fetch_cloud_image "$work" "$base"

	rsha="${RUNNER_SHA256:-$(runner_asset_sha "$RUNNER_VERSION" || true)}"
	if [[ -z "$rsha" ]]; then
		[[ "$ALLOW_UNVERIFIED_RUNNER" == 1 ]] ||
			die "could not resolve the runner tarball SHA-256 for v$RUNNER_VERSION.
Pin it with RUNNER_SHA256= in $CONFIG (see the release notes at
https://github.com/actions/runner/releases/tag/v$RUNNER_VERSION),
or set ALLOW_UNVERIFIED_RUNNER=1 to install it unverified."
		log "WARN: installing the runner tarball unverified (ALLOW_UNVERIFIED_RUNNER=1)"
	fi

	rm -f "$tmp"
	cp --reflink=auto "$base" "$tmp"
	qemu-img resize "$tmp" "$VM_DISK"

	export LIBGUESTFS_BACKEND=direct

	grow_guest_root "$tmp"
	local -a proxy_args hook_args prejob_args=()
	mapfile -d '' -t proxy_args < <(guest_proxy_args)
	mapfile -d '' -t hook_args < <(image_hook_args)
	fix_guest_dns "$tmp" "${proxy_args[@]}"

	local guest_pkgs="$GUEST_PACKAGES"
	[[ -n "$GUEST_EXTRA_PACKAGES" ]] && guest_pkgs+=",$GUEST_EXTRA_PACKAGES"
	local tarball="actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
	[[ -n "$GUEST_PRE_JOB_HOOK" ]] &&
		prejob_args=(--upload "$GUEST_PRE_JOB_HOOK:/usr/local/bin/gha-pre-job.sh" --chmod '0755:/usr/local/bin/gha-pre-job.sh')

	virt-customize -a "$tmp" \
		"${proxy_args[@]}" \
		--update \
		--install "$guest_pkgs" \
		--run-command 'apt-get purge -y snapd || true' \
		--run-command 'useradd -m -s /bin/bash -G docker runner' \
		--run-command 'install -d -o runner -g runner /opt/actions-runner' \
		--run-command "cd /opt/actions-runner \
        && { [ ! -r /etc/gha-proxy.env ] || { set -a; . /etc/gha-proxy.env; set +a; }; } \
        && curl -fsSL --proto '=https' --retry 5 --retry-delay 3 --retry-all-errors \
             -o r.tgz '${RUNNER_DOWNLOAD_BASE}/v${RUNNER_VERSION}/${tarball}' \
        && { [ -z '${rsha}' ] || echo '${rsha}  r.tgz' | sha256sum -c -; } \
        && tar xzf r.tgz && rm r.tgz && ./bin/installdependencies.sh \
        && mkdir -p _work && chown -R runner:runner /opt/actions-runner" \
		--write '/etc/cloud/cloud.cfg.d/99-nocloud.cfg:datasource_list: [ NoCloud, None ]' \
		--write '/etc/docker/daemon.json:{"log-driver":"local","log-opts":{"max-size":"32m","max-file":"2"}}' \
		--run-command 'systemctl disable --now unattended-upgrades apt-daily.timer apt-daily-upgrade.timer man-db.timer motd-news.timer fstrim.timer systemd-networkd-wait-online.service 2>/dev/null || true' \
		--run-command 'sed -i "s/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/" /etc/default/grub && update-grub' \
		--upload "$job_src:/usr/local/bin/gha-job.sh" \
		--chmod '0755:/usr/local/bin/gha-job.sh' \
		"${prejob_args[@]}" \
		"${hook_args[@]}" \
		--run-command 'systemctl enable docker' \
		--run-command 'apt-get clean && rm -rf /var/lib/apt/lists/* /var/log/journal/*' \
		--truncate /etc/machine-id \
		--delete /var/lib/dbus/machine-id

	restore_guest_dns "$tmp"

	# Overlay reads are served from the host page cache shared by every slot, so a
	# smaller golden directly cuts per-slot memory pressure.
	if [[ "$SPARSIFY" == 1 ]]; then
		log "sparsifying golden image"
		virt-sparsify --in-place "$tmp" || die "virt-sparsify failed (set SPARSIFY=0 to skip)"
	fi

	if [[ "$IMAGE_SELFTEST" == 1 ]]; then
		image_selftest "$tmp"
	else
		log "IMAGE_SELFTEST=0: skipping the boot self-test"
	fi

	if [[ "$GOLDEN_KEEP_PREVIOUS" == 1 && -f "$GOLDEN" ]]; then
		mv -f "$GOLDEN" "$GOLDEN.prev"
	fi
	mv -f "$tmp" "$GOLDEN"
	chown "$GHA_USER":"$GHA_USER" "$GOLDEN"
	chmod 0644 "$GOLDEN"
	log "golden image ready: $GOLDEN ($(du -h "$GOLDEN" | cut -f1), runner $RUNNER_VERSION, ubuntu $UBUNTU_RELEASE, $RUNNER_ARCH)"
	[[ -f "$GOLDEN.prev" ]] && log "previous image kept at $GOLDEN.prev (undo with: $SELF rollback)"
	log "running slots adopt it when their current VM finishes"
}

# Puts the previous golden back. The image being replaced becomes .prev, so a
# second rollback swaps forward again.
cmd_rollback() {
	[[ $EUID -eq 0 ]] || die "rollback must run as root"
	[[ -f "$GOLDEN.prev" ]] || die "no previous image at $GOLDEN.prev"
	exec 8>"$STATE_DIR/.image.lock"
	flock -n 8 || die "an image build is running; wait for it before rolling back"
	if [[ -f "$GOLDEN" ]]; then
		mv -f "$GOLDEN" "$GOLDEN.swap"
		mv -f "$GOLDEN.prev" "$GOLDEN"
		mv -f "$GOLDEN.swap" "$GOLDEN.prev"
	else
		mv -f "$GOLDEN.prev" "$GOLDEN"
	fi
	chown "$GHA_USER":"$GHA_USER" "$GOLDEN"
	chmod 0644 "$GOLDEN"
	log "rolled back: $GOLDEN is the previous image; running slots adopt it when their current VM finishes"
}

# --- config file edits ---
# Values outside the plain set are single-quoted so the file still sources
# cleanly. Writes go through a temp file in the same directory and an atomic
# rename, keeping the owner and mode of the original.
config_quote() {
	local v="$1"
	if [[ "$v" =~ ^[A-Za-z0-9_./:@+=,-]*$ ]]; then
		printf '%s' "$v"
	else
		printf "'%s'" "${v//\'/\'\\\'\'}"
	fi
}

config_edit() { # FILE set|unset KEY [VAL]
	local file="$1" op="$2" key="$3" val="${4:-}" tmp q mode=comment
	[[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "invalid config key: $key"
	[[ -f "$file" ]] || die "config file missing: $file"
	q="$(config_quote "$val")"
	grep -qE "^${key}=" "$file" && mode=active
	tmp="$(mktemp "$file.XXXXXX")" || die "cannot create a temp file next to $file"
	# Only the first matching line is rewritten. In "active" mode that is the
	# first live KEY= line and any further live copies are commented out, so the
	# value written here is the one that sourcing ends up with.
	KEY="$key" VAL="$q" OP="$op" MODE="$mode" awk '
		BEGIN { k = ENVIRON["KEY"]; v = ENVIRON["VAL"]; op = ENVIRON["OP"]; mode = ENVIRON["MODE"]; done = 0 }
		$0 ~ ("^" k "=") {
			if (op == "set" && !done) { print k "=" v; done = 1 }
			else print "#" k "="
			next
		}
		mode == "comment" && !done && $0 ~ ("^#" k "=") {
			if (op == "set") print k "=" v; else print
			done = 1
			next
		}
		{ print }
		END { if (op == "set" && !done) print k "=" v }
	' "$file" >"$tmp" || {
		rm -f "$tmp"
		die "could not rewrite $file"
	}
	if ! chown --reference="$file" "$tmp" || ! chmod --reference="$file" "$tmp"; then
		rm -f "$tmp"
		die "could not preserve owner/mode on $file"
	fi
	mv -f "$tmp" "$file"
	if [[ "$op" == set ]]; then
		grep -qxF "${key}=${q}" "$file" || die "failed to set $key in $file"
	else
		grep -qE "^${key}=" "$file" && die "failed to unset $key in $file"
	fi
	return 0
}

config_set() { config_edit "${3:-$CONFIG}" set "$1" "$2"; }
config_unset() { config_edit "${2:-$CONFIG}" unset "$1"; }

# Where RUNNER_VERSION actually comes from. A pin written to config.env is
# invisible when a profile or local.env sets the same key after it.
runner_version_source() {
	local f
	for f in "$LOCAL_FILE" "$PROFILE_FILE"; do
		[[ -n "$f" && -r "$f" ]] || continue
		if grep -qE '^RUNNER_VERSION=' "$f"; then
			printf '%s' "$f"
			return
		fi
	done
	printf '%s' "$CONFIG"
}

cmd_upgrade() {
	local check=0
	[[ "${1:-}" == --check ]] && check=1
	((check)) || [[ $EUID -eq 0 ]] || die "upgrade must run as root"
	local latest sha src
	latest="$(latest_runner_version)" || latest=""
	[[ -n "$latest" ]] || die "could not resolve the latest runner release"

	src="$(runner_version_source)"
	if ((check)); then
		printf 'current        %s (from %s)\n' "$RUNNER_VERSION" "$src"
		printf 'latest         %s\n' "$latest"
		printf 'golden image   %s\n' "$([[ -f "$GOLDEN" ]] && echo "present, $(stat -c %y "$GOLDEN" | cut -d. -f1)" || echo missing)"
		if [[ "$latest" != "$RUNNER_VERSION" ]]; then
			if [[ "$AUTO_RUNNER_VERSION" == 1 ]]; then
				printf 'action         pin %s and rebuild\n' "$latest"
			else
				printf 'action         rebuild at %s (AUTO_RUNNER_VERSION=0 keeps the pin)\n' "$RUNNER_VERSION"
			fi
		elif [[ "$UPGRADE_REBUILD" == version && -f "$GOLDEN" ]]; then
			printf 'action         nothing (UPGRADE_REBUILD=version and already on %s)\n' "$latest"
		else
			printf 'action         rebuild at %s to pick up guest package updates\n' "$latest"
		fi
		return 0
	fi

	if [[ "$latest" == "$RUNNER_VERSION" && -f "$GOLDEN" ]]; then
		if [[ "$UPGRADE_REBUILD" == version ]]; then
			log "already on runner $latest; UPGRADE_REBUILD=version, nothing to do"
			return 0
		fi
		log "already on runner $latest; rebuilding anyway to pick up guest package updates"
	fi

	if [[ "$AUTO_RUNNER_VERSION" == 1 && "$latest" != "$RUNNER_VERSION" ]]; then
		if [[ "$src" != "$CONFIG" ]]; then
			log "WARN: RUNNER_VERSION is set in $src, which overrides $CONFIG; pinning there"
		fi
		sha="$(runner_asset_sha "$latest" || true)"
		install -m 0640 -o root -g "$GHA_USER" "$src" "$src.bak"
		config_set RUNNER_VERSION "$latest" "$src"
		if [[ -n "$sha" ]]; then
			config_set RUNNER_SHA256 "$sha" "$src"
		else
			# A stale pin from the previous release would fail the new tarball.
			config_unset RUNNER_SHA256 "$src"
			log "WARN: could not resolve the SHA-256 for v$latest; the build verifies nothing unless ALLOW_UNVERIFIED_RUNNER=1"
		fi
		RUNNER_VERSION="$latest"
		RUNNER_SHA256="${sha:-}"
		log "pinned runner $latest in $src (previous file saved as $src.bak)"
	fi

	cmd_image
}

# ------------------------------------------------------------------- net ----

# $1 is 4 or 6: the nameservers of that family the host actually resolves with,
# plus the resolvers pinned into the guests, which leave slirp as the same uid.
# NET_DNS_ADDRS, when set, replaces discovery of the host's own.
host_resolvers() {
	local f
	{
		if [[ -n "$NET_DNS_ADDRS" ]]; then
			tr ' ,' '\n' <<<"$NET_DNS_ADDRS"
		else
			for f in /etc/resolv.conf /run/systemd/resolve/resolv.conf; do
				[[ -r "$f" ]] || continue
				awk '/^nameserver[ \t]/ {print $2}' "$f"
			done
		fi
		[[ -z "$GUEST_RUNTIME_DNS" ]] || tr ' ,' '\n' <<<"$GUEST_RUNTIME_DNS"
	} | sed 's/%.*//' | addr_family "$1"
}

# Keeps the lines that are addresses of family $1 (4 or 6). An empty result is
# normal (a v4-only resolver list, no global IPv6), so grep's no-match exit
# must not reach the callers' pipefail.
addr_family() {
	local pat='^[0-9]+(\.[0-9]+){3}$'
	[[ "$1" == 6 ]] && pat='^[0-9a-fA-F]*:[0-9a-fA-F:]*$'
	{ grep -E "$pat" || :; } | sort -u
}

# $1 is 4 or 6: the host's own globally scoped addresses. A job must not reach
# the host through its public address any more than through loopback.
# NET_HOST_ADDRS, when set, replaces discovery; NET_BLOCK_HOST_ADDRS=0 yields
# nothing.
host_global_addrs() {
	[[ "$NET_BLOCK_HOST_ADDRS" == 1 ]] || return 0
	{
		if [[ -n "$NET_HOST_ADDRS" ]]; then
			tr ' ,' '\n' <<<"$NET_HOST_ADDRS"
		elif command -v ip >/dev/null 2>&1; then
			{ ip -o "-$1" addr show scope global 2>/dev/null || :; } | awk '{print $4}'
		fi
	} | sed 's#/.*##' | addr_family "$1"
}

# Prints "host port" for HOST[:PORT], [V6]:PORT or a bare IPv6 literal; $2 is
# the port when the input names none.
split_hostport() {
	local s="$1" h p=""
	if [[ "$s" == \[* ]]; then
		h="${s#\[}"
		h="${h%%\]*}"
		p="${s##*\]}"
		p="${p#:}"
	elif [[ "$s" == *:*:* ]]; then
		h="$s"
	else
		h="${s%%:*}"
		p="${s#"$h"}"
		p="${p#:}"
	fi
	[[ -n "$h" ]] || return 0
	printf '%s %s\n' "$h" "${p:-$2}"
}

# "host port" for everything the runner side must reach through the filter:
# the GitHub API and web endpoints, the tarball mirror and any proxy,
# host-side or guest-side. The port comes from the URL, else from its scheme
# (443, 80; 1080 for a scheme-less or socks proxy, which is curl's default).
endpoint_hosts() {
	local u h dflt
	for u in "$GITHUB_SERVER_URL" "$GITHUB_API_URL" "$RUNNER_DOWNLOAD_BASE" \
		"${HTTPS_PROXY:-}" "${HTTP_PROXY:-}" "$GUEST_HTTP_PROXY"; do
		[[ -n "$u" ]] || continue
		case "$u" in
		https://*) dflt=443 ;;
		http://*) dflt=80 ;;
		*) dflt=1080 ;;
		esac
		h="${u#*://}"
		h="${h%%/*}"
		h="${h##*@}"
		[[ -n "$h" ]] || continue
		split_hostport "$h" "$dflt"
	done | sort -u
}

# $1 is 4 or 6: "addr . port" elements for the endpoints as they resolve right
# now. These get a port-scoped accept ahead of every drop, so a GitHub
# Enterprise Server or a proxy on the LAN is reachable although its range is
# blocked, while the rest of that range and of the host stay closed.
# NET_ENDPOINT_ADDRS (ADDR[:PORT], [V6]:PORT; port 443 when absent) replaces
# resolution. A guest-side endpoint at the gateway address 10.0.2.2 is the
# host's loopback as the filter sees it. The resolver is bounded so a dead
# nameserver cannot hold a slot start for minutes.
host_endpoint_addrs() {
	local db=ahostsv4 a h p
	[[ "$1" == 6 ]] && db=ahostsv6
	{
		if [[ -n "$NET_ENDPOINT_ADDRS" ]]; then
			for a in ${NET_ENDPOINT_ADDRS//,/ }; do
				split_hostport "$a" 443
			done
		else
			endpoint_hosts
		fi
	} | sed 's/^10\.0\.2\.2 /127.0.0.1 /' | while read -r h p; do
		[[ "$p" =~ ^[0-9]+$ ]] || {
			log "WARN: endpoint '$h' has no usable port ('$p'); no hole for it"
			continue
		}
		# A literal address passes through addr_family as itself; a hostname
		# is dropped there and only its resolved addresses remain.
		{
			printf '%s\n' "$h"
			RES_OPTIONS='timeout:2 attempts:1' timeout 15 getent "$db" "$h" 2>/dev/null | awk '{print $1}' || :
		} | sed 's/%.*//' | addr_family "$1" | sed "s/\$/ . $p/"
	done | sort -u
}

# Splits NET_ALLOW_CIDRS into one family; $1 is 4 or 6.
allow_cidrs() {
	local x
	for x in ${NET_ALLOW_CIDRS//,/ }; do
		if [[ "$1" == 6 && "$x" == *:* ]] || [[ "$1" == 4 && "$x" != *:* ]]; then
			printf '%s\n' "$x"
		fi
	done
}

nft_set_decl() { # name type elements
	if [[ -n "$3" ]]; then
		printf '  set %s { type %s; elements = { %s } }\n' "$1" "$2" "$3"
	else
		printf '  set %s { type %s; }\n' "$1" "$2"
	fi
}

# The ruleset text. Pure: everything host-specific arrives as arguments
# (comma-separated lists), so the output can be diffed in a test.
#   net_render UID DNS4 DNS6 HOST4 HOST6 ALLOW4 ALLOW6 EP4 EP6
#
# QEMU's user-mode network maps the guest's default gateway (10.0.2.2) onto
# the host's loopback, so without the drops every service bound to 127.0.0.1
# is reachable from inside a job. Blocking loopback also blocks the local
# resolver, so the nameservers in use get a hole on port 53, and each GitHub
# or proxy endpoint gets one on its own port so an on-LAN server still works.
# The sets are refreshed from the live host at every slot start
# (net_refresh_sets), so a resolver or address change after `net` ran does
# not strand the guests.
net_render() {
	local uid="$1" dns4="$2" dns6="$3" host4="$4" host6="$5" allow4="$6" allow6="$7" ep4="$8" ep6="$9"
	local drop4='127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16'
	local drop6='::1, fc00::/7, fe80::/10'
	if [[ "$NET_BLOCK_EXTRA" == 1 ]]; then
		drop4+=', 0.0.0.0/8, 100.64.0.0/10, 192.0.0.0/24, 198.18.0.0/15, 224.0.0.0/4, 240.0.0.0/4, 255.255.255.255'
		drop6+=', ff00::/8'
	fi
	printf 'table inet gha\ndelete table inet gha\ntable inet gha {\n'
	nft_set_decl dns4 ipv4_addr "$dns4"
	nft_set_decl dns6 ipv6_addr "$dns6"
	nft_set_decl host4 ipv4_addr "$host4"
	nft_set_decl host6 ipv6_addr "$host6"
	nft_set_decl ep4 'ipv4_addr . inet_service' "$ep4"
	nft_set_decl ep6 'ipv6_addr . inet_service' "$ep6"
	printf '  chain output {\n    type filter hook output priority 0; policy accept;\n'
	[[ -n "$allow4" ]] && printf '    meta skuid %s ip  daddr { %s } counter accept\n' "$uid" "$allow4"
	[[ -n "$allow6" ]] && printf '    meta skuid %s ip6 daddr { %s } counter accept\n' "$uid" "$allow6"
	printf '    meta skuid %s ip  daddr . tcp dport @ep4 counter accept\n' "$uid"
	printf '    meta skuid %s ip6 daddr . tcp dport @ep6 counter accept\n' "$uid"
	local proto
	for proto in udp tcp; do
		printf '    meta skuid %s ip  daddr @dns4 %s dport 53 counter accept\n' "$uid" "$proto"
		printf '    meta skuid %s ip6 daddr @dns6 %s dport 53 counter accept\n' "$uid" "$proto"
	done
	printf '    meta skuid %s ip  daddr @host4 counter drop\n' "$uid"
	printf '    meta skuid %s ip6 daddr @host6 counter drop\n' "$uid"
	printf '    meta skuid %s ip  daddr { %s } counter drop\n' "$uid" "$drop4"
	printf '    meta skuid %s ip6 daddr { %s } counter drop\n' "$uid" "$drop6"
	printf '  }\n}\n'
}

# Numeric uid the rules key on. GHA_UID lets the ruleset be rendered on a
# machine where the user does not exist (a staging tree, the test suite).
gha_uid() {
	if [[ -n "${GHA_UID:-}" ]]; then
		printf '%s' "$GHA_UID"
	else
		id -u "$GHA_USER" 2>/dev/null ||
			die "user $GHA_USER does not exist (run: $SELF deps, or set GHA_UID to render anyway)"
	fi
}

# Renders the ruleset from the live host into $NFT_CONF via a same-directory
# temp file. Checks syntax with nft when it is available; on a host without
# nft the file is still written so `render` works in a staging tree.
net_write() {
	local uid r4 r6 h4 h6 a4 a6 e4 e6 tmp
	uid="$(gha_uid)"
	net_live_sets
	r4="$NET_DNS4" r6="$NET_DNS6" h4="$NET_HOST4" h6="$NET_HOST6" e4="$NET_EP4" e6="$NET_EP6"
	a4="$(allow_cidrs 4 | paste -sd, -)"
	a6="$(allow_cidrs 6 | paste -sd, -)"
	[[ -n "$r4$r6" ]] ||
		log "WARN: no nameserver found in resolv.conf; guest DNS will break once loopback is blocked"

	install -d -m 0750 "$(dirname "$NFT_CONF")"
	tmp="$(mktemp "$NFT_CONF.XXXXXX")"
	net_render "$uid" "$r4" "$r6" "$h4" "$h6" "$a4" "$a6" "$e4" "$e6" >"$tmp"
	if command -v nft >/dev/null 2>&1 && [[ $EUID -eq 0 ]]; then
		nft -c -f "$tmp" || {
			rm -f "$tmp"
			die "generated ruleset is invalid (kept nothing; check NET_ALLOW_CIDRS / NET_DNS_ADDRS / NET_HOST_ADDRS / NET_ENDPOINT_ADDRS)"
		}
	fi
	chmod 0644 "$tmp"
	mv -f "$tmp" "$NFT_CONF"
	NET_SUMMARY="uid $uid; DNS: ${r4:-none} ${r6:-}; host addrs: ${h4:-none} ${h6:-}; endpoints: ${e4:-none} ${e6:-}; allow: ${a4:-none} ${a6:-}"
}

# The set contents as they are on the host right now, comma-joined into
# NET_DNS4/6, NET_HOST4/6 and NET_EP4/6. Endpoints that resolve to nothing are
# reported: until they resolve, a server inside a blocked range is unreachable.
net_live_sets() {
	NET_DNS4="$(host_resolvers 4 | paste -sd, -)"
	NET_DNS6="$(host_resolvers 6 | paste -sd, -)"
	NET_HOST4="$(host_global_addrs 4 | paste -sd, -)"
	NET_HOST6="$(host_global_addrs 6 | paste -sd, -)"
	NET_EP4="$(host_endpoint_addrs 4 | paste -sd, -)"
	NET_EP6="$(host_endpoint_addrs 6 | paste -sd, -)"
	if [[ -z "$NET_EP4$NET_EP6" ]]; then
		if [[ -n "$NET_ENDPOINT_ADDRS" ]]; then
			log "WARN: NET_ENDPOINT_ADDRS='$NET_ENDPOINT_ADDRS' yielded no address; a server on the LAN stays blocked"
		else
			log "WARN: none of the endpoints resolved ($(endpoint_hosts | awk '{print $1":"$2}' | paste -sd' ' -)); a server on the LAN stays blocked until the next slot start refreshes the sets"
		fi
	fi
}

# One transaction: flush and repopulate the sets from the live host. A set
# whose discovery came back empty keeps its previous elements: a resolver
# that is down at slot start must not empty the holes every slot depends on.
# A ruleset from before the current sets existed is reported, not patched.
net_refresh_sets() {
	local batch="" name var val kept=""
	net_sets_current || {
		log "WARN: nftables table inet gha predates the current sets; run: $SELF net"
		return 0
	}
	net_live_sets
	for name in dns4 dns6 host4 host6 ep4 ep6; do
		var="NET_${name^^}"
		val="${!var}"
		# host4/host6 are empty by design under NET_BLOCK_HOST_ADDRS=0.
		if [[ -z "$val" && ("$name" != host* || "$NET_BLOCK_HOST_ADDRS" == 1) ]] && nft_set_populated "$name"; then
			kept+=" $name"
			continue
		fi
		batch+="flush set inet gha $name"$'\n'
		[[ -n "$val" ]] && batch+="add element inet gha $name { $val }"$'\n'
	done
	[[ -z "$kept" ]] || log "WARN: nothing discovered for$kept; keeping the previous elements (run: $SELF net to rebuild from scratch)"
	nft -f - <<<"$batch" ||
		die "could not refresh the nftables sets (DNS: ${NET_DNS4:-none} ${NET_DNS6:-}; host: ${NET_HOST4:-none} ${NET_HOST6:-}; endpoints: ${NET_EP4:-none} ${NET_EP6:-})"
}

# True when the loaded table carries every set the current ruleset uses; the
# port-scoped ep4 is the newest, so its presence implies the rest.
net_sets_current() {
	nft list set inet gha ep4 2>/dev/null | grep -q 'type ipv4_addr \. inet_service'
}

# True when the loaded set $1 holds at least one element.
nft_set_populated() {
	nft list set inet gha "$1" 2>/dev/null | grep -q 'elements'
}

# True when the ruleset file on disk was rendered by this version.
net_conf_current() {
	[[ -r "$NFT_CONF" ]] && grep -q 'set ep4 { type ipv4_addr \. inet_service' "$NFT_CONF"
}

# Adds the include line to the main nftables config so the rules load at boot.
net_persist() {
	local main_ok=1
	if ! grep -qF "$NFT_CONF" "$NFT_MAIN" 2>/dev/null; then
		# A main file without a trailing newline would glue the include onto its
		# last line.
		if [[ -s "$NFT_MAIN" && "$(tail -c1 "$NFT_MAIN")" != "" ]]; then
			printf '\n' >>"$NFT_MAIN"
		fi
		printf 'include "%s"\n' "$NFT_CONF" >>"$NFT_MAIN"
	fi
	nft -c -f "$NFT_MAIN" 2>/dev/null || main_ok=0
	((main_ok)) || log "WARN: $NFT_MAIN does not pass 'nft -c -f'; the isolation rules will not load at boot until it does"
	systemctl enable nftables.service >/dev/null 2>&1 ||
		log "WARN: could not enable nftables.service; isolation rules will not survive a reboot"
}

cmd_net() {
	[[ $EUID -eq 0 ]] || die "net must run as root"
	id -u "$GHA_USER" >/dev/null 2>&1 || die "user $GHA_USER does not exist (run: $SELF deps)"
	need nft

	local NET_SUMMARY=""
	net_write
	chown "root:$GHA_USER" "$NFT_CONF"
	nft -f "$NFT_CONF"
	net_persist

	log "isolation rules loaded: $NET_SUMMARY"
	log "blocked for uid $(gha_uid): host loopback, RFC1918, link-local$([[ "$NET_BLOCK_EXTRA" == 1 ]] && echo ', CGNAT, multicast, reserved')$([[ "$NET_BLOCK_HOST_ADDRS" == 1 ]] && echo ", the host's own addresses")"
	log "NOTE: this also blocks a LAN apt mirror or internal registry; allow one with NET_ALLOW_CIDRS in $CONFIG, then re-run: $SELF net"
}

# ------------------------------------------------------------------- run ----

# Reap only this slot's own stale registrations. A host-wide reap here would
# race a sibling slot whose runner is registered but has not booted yet -- it
# reads as "offline" and deleting it invalidates that slot's live JIT config.
reap_slot() {
	local slot="$1" id runners
	runners="$(list_runners)" || {
		log "slot $slot: WARN could not list runners; reap skipped"
		return 1
	}
	while read -r id; do
		[[ -n "$id" ]] || continue
		log "slot $slot: reaping stale runner id=$id"
		api DELETE "$(runners_path)/$id" >/dev/null ||
			log "slot $slot: WARN could not delete runner id=$id; it will be retried next cycle"
	done < <(jq -r --arg p "${NAME_PREFIX}-${slot}-" \
		'select(.name | ltrimstr($p) | test("^[0-9a-f]{8}$")) | select(.status=="offline") | .id' <<<"$runners")
}

reap_one() {
	local target="$1" id runners
	runners="$(list_runners)" || return 1
	id=$(jq -r --arg n "$target" 'select(.name==$n) | .id' <<<"$runners" | head -n1)
	[[ -n "$id" ]] || return 0
	api DELETE "$(runners_path)/$id" >/dev/null
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
# and the supervisor itself runs unprivileged. When the table is missing but
# the rendered file exists (a reboot where nftables.service lost the race, an
# operator's `nft flush ruleset`), the rules are loaded here rather than
# refusing to start; then the resolver and host-address sets are refreshed.
cmd_netcheck() {
	if [[ "$REQUIRE_ISOLATION" != 1 ]]; then
		log "REQUIRE_ISOLATION=0: starting without verifying host/LAN isolation"
		return 0
	fi
	need nft
	local rules
	# Captured, not piped into grep: under `set -o pipefail` a `grep -q` that
	# matches early makes nft die on SIGPIPE and the pipeline return 141, which
	# would read as "loopback unblocked" and refuse to start every slot.
	if ! rules="$(nft list table inet gha 2>/dev/null)"; then
		[[ -r "$NFT_CONF" ]] ||
			die "nftables table 'inet gha' is not loaded and $NFT_CONF is missing; jobs would reach the host and LAN (run: $SELF net, or set REQUIRE_ISOLATION=0)"
		(
			flock 7
			nft list table inet gha >/dev/null 2>&1 || nft -f "$NFT_CONF"
		) 7>"$NFT_CONF.lock" || die "nftables table 'inet gha' is not loaded and $NFT_CONF failed to load (run: $SELF net)"
		rules="$(nft list table inet gha 2>/dev/null)" ||
			die "nftables table 'inet gha' is still missing after loading $NFT_CONF"
		log "isolation rules were not loaded; loaded them now from $NFT_CONF"
	fi
	[[ "$rules" == *'127.0.0.0/8'* ]] ||
		die "the gha nftables table is loaded but does not block host loopback (re-run: $SELF net)"
	net_refresh_sets
}

# Available GiB on the filesystem holding $1. Empty when df cannot read it;
# every caller reports "unknown" rather than assuming there is room.
free_gb() {
	local out
	out=$(df -BG --output=avail "$1" 2>/dev/null | tail -1) || out=""
	printf '%s' "${out//[!0-9]/}"
}

# Sleeps $1 seconds in a child so a stop signal is handled at once instead of
# after the sleep. The child must not inherit the slot lock on fd 9: a sleep
# outliving the supervisor would hold it against the next one.
nap() {
	sleep "$1" 9>&- &
	wait $! || true
}

# Waits up to $2 seconds for pid $1 to exit. Returns 0 once it has.
wait_pid() {
	local pid="$1" secs="$2" w=0
	while kill -0 "$pid" 2>/dev/null; do
		((w >= secs)) && return 1
		sleep 1
		w=$((w + 1))
	done
	return 0
}

# A GitHub App JWT carries a 10-minute window around the host's clock. Right
# after a reboot the clock may still be at the RTC's idea of the time, so the
# first mint is held until NTP has confirmed it (bounded by CLOCK_SYNC_WAIT).
wait_for_clock() {
	[[ "$AUTH_MODE" == app ]] || return 0
	command -v timedatectl >/dev/null 2>&1 || return 0
	local w=0
	while [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" != yes ]]; do
		if ((w >= CLOCK_SYNC_WAIT)); then
			log "WARN: clock not NTP-synchronized after ${CLOCK_SYNC_WAIT}s; minting the JWT anyway"
			return 0
		fi
		((w == 0)) && log "waiting for NTP synchronization before minting the first JWT"
		sleep 5
		w=$((w + 5))
	done
	return 0
}

# -cpu host with nested virtualization masked off unless NESTED_VIRT=1: exposing
# VMX/SVM to a job widens the KVM attack surface the isolation model rests on.
guest_cpu_model() {
	local cpu="$VM_CPU"
	if [[ "$NESTED_VIRT" != 1 && "$cpu" == host && "$RUNNER_ARCH" == x64 ]]; then
		if grep -qm1 '^flags.*\bvmx\b' /proc/cpuinfo; then
			cpu="host,vmx=off"
		elif grep -qm1 '^flags.*\bsvm\b' /proc/cpuinfo; then cpu="host,svm=off"; fi
	fi
	printf '%s' "$cpu"
}

# QEMU command line for one VM, into QEMU_ARGS. Shared by the slot loop and
# the image self-test so both boot the same way.
#   build_qemu_args NAME DIR UEFI_CODE CPU
# -sandbox confines QEMU itself with seccomp: no spawning, no privilege
# elevation, no obsolete syscalls. -nodefaults/-no-user-config keep the
# device set to exactly what is listed here.
QEMU_ARGS=()
build_qemu_args() {
	local name="$1" dir="$2" code="$3" cpu="$4"
	QEMU_ARGS=(
		-name "$name"
		-nodefaults -no-user-config
		-machine "$QEMU_MACHINE" -cpu "$cpu"
		-smp "$VM_CPUS" -m "$VM_MEM"
		-drive "if=pflash,format=raw,readonly=on,file=$code"
		-drive "if=pflash,format=raw,file=$dir/vars.fd"
		-drive "file=$dir/disk.qcow2,if=virtio,format=qcow2,cache=unsafe,discard=unmap"
		-drive "file=$dir/seed.img,if=virtio,format=raw,readonly=on"
		-netdev "user,id=n0,ipv6=off" -device "virtio-net-pci,netdev=n0"
		-device virtio-rng-pci
		-device "virtio-balloon-pci,free-page-reporting=on"
		-display none -monitor none -serial "file:$dir/console.log"
		-no-reboot -rtc "base=utc"
	)
	if [[ "$QEMU_SANDBOX" == 1 ]]; then
		QEMU_ARGS+=(-sandbox "on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny")
	fi
	if [[ -n "$QEMU_EXTRA_ARGS" ]]; then
		# shellcheck disable=SC2206
		QEMU_ARGS+=($QEMU_EXTRA_ARGS)
	fi
}

# cloud-init network-config v2 that pins the guest's resolvers instead of
# taking the ones slirp hands out. Empty when GUEST_RUNTIME_DNS is unset.
guest_network_config() {
	[[ -n "$GUEST_RUNTIME_DNS" ]] || return 0
	local addrs
	addrs="$(tr ' ,' '\n' <<<"$GUEST_RUNTIME_DNS" | grep -v '^$' | paste -sd, -)"
	printf 'version: 2\nethernets:\n  all:\n    match: { name: "e*" }\n    dhcp4: true\n    dhcp4-overrides: { use-dns: false }\n    nameservers: { addresses: [%s] }\n' "$addrs"
}

drain_flag() { printf '%s/.slot-%s.drain' "$RUN_DIR" "$1"; }

cmd_run() {
	need "$QEMU_BIN"
	need cloud-localds
	need qemu-img
	need flock
	local slot="${1:-1}"
	[[ "$slot" =~ ^[0-9]+$ ]] || die "slot must be a number"

	install -d -m 0750 "$RUN_DIR"

	# Guards against a hand-started supervisor racing the systemd one.
	exec 9>"$RUN_DIR/.slot-$slot.lock"
	flock -n 9 || die "slot $slot already has a supervisor running"

	# Missing golden is a wait, not a failure: the first image build may be in
	# progress, and a restart loop would only add noise to its log.
	local said=0
	while [[ ! -f "$GOLDEN" ]]; do
		((said)) || log "slot $slot: golden image missing: $GOLDEN (run: $SELF image); waiting"
		said=1
		sleep 60 9>&-
	done

	local code vars pair
	pair="$(ovmf_pair)"
	code="$(sed -n 1p <<<"$pair")"
	vars="$(sed -n 2p <<<"$pair")"

	local name="" dir="" vmpid="" tailpid="" fails=0 stopping=0 ready=0 mint_fails=0
	local last_reap=0 self_inode
	local cpu
	cpu="$(guest_cpu_model)"
	self_inode="$(stat -c %i "$SELF" 2>/dev/null || echo 0)"

	# Runs once on every exit path: a `die` mid-cycle, a signal, or the loop
	# ending. Nothing here may fail the function, so every step is guarded.
	local cleaned=0
	cleanup() {
		((cleaned)) && return 0
		cleaned=1
		trap '' INT TERM
		if [[ -n "$vmpid" ]] && kill -0 "$vmpid" 2>/dev/null; then
			log "slot $slot: stopping ${name:-vm}"
			kill -TERM "$vmpid" 2>/dev/null || true
			wait_pid "$vmpid" 30 || kill -KILL "$vmpid" 2>/dev/null || true
			wait "$vmpid" 2>/dev/null || true
		fi
		if [[ -n "$tailpid" ]]; then
			kill -TERM "$tailpid" 2>/dev/null || true
			wait "$tailpid" 2>/dev/null || true
		fi
		if [[ -n "$name" && "$REAP_ON_STOP" == 1 ]]; then
			# Bounded: a stop must not hang on a GitHub outage.
			API_MAXTIME=5 API_RETRY=0 reap_one "$name" ||
				log "slot $slot: WARN could not deregister $name; the startup reap will retry"
		fi
		[[ -n "$dir" ]] && rm -rf "$dir"
		return 0
	}
	trap cleanup EXIT

	# A stop request lets a running job finish, up to STOP_GRACE_SEC. A VM
	# that has not reported ready yet has no job to lose and is stopped at once.
	on_stop() {
		trap '' INT TERM
		stopping=1
		if [[ -n "$vmpid" ]] && kill -0 "$vmpid" 2>/dev/null && ((ready == 1)); then
			log "slot $slot: stop requested; letting $name finish (up to ${STOP_GRACE_SEC}s)"
			wait_pid "$vmpid" "$STOP_GRACE_SEC" ||
				log "slot $slot: $name still running after ${STOP_GRACE_SEC}s; killing it"
		else
			log "slot $slot: stop requested"
		fi
		exit 0
	}
	trap on_stop INT TERM

	reap_slot_dirs "$slot"
	# A GitHub outage here must not stop the slot from serving jobs.
	wait_for_clock
	reap_slot "$slot" || log "slot $slot: WARN startup reap failed; continuing"
	last_reap=$(date +%s)

	while ((stopping == 0)); do
		# An installed update to this script takes effect at the next cycle
		# rather than the next host reboot.
		if [[ "$(stat -c %i "$SELF" 2>/dev/null || echo 0)" != "$self_inode" ]]; then
			log "slot $slot: $SELF changed on disk; re-executing"
			trap - EXIT
			exec 9>&-
			exec "$SELF" run "$slot"
		fi

		if [[ -e "$(drain_flag "$slot")" ]]; then
			log "slot $slot: drained; not taking jobs until: $SELF undrain $slot"
			nap 15
			continue
		fi

		local avail
		avail="$(free_gb "$RUN_DIR")"
		if [[ -z "$avail" ]]; then
			log "slot $slot: WARN cannot read free space under $RUN_DIR; starting anyway"
		elif ((avail < MIN_FREE_GB)); then
			log "slot $slot: only ${avail}G free under $RUN_DIR (need ${MIN_FREE_GB}G); waiting 60s"
			nap 60
			continue
		fi

		if [[ ! -f "$GOLDEN" ]]; then
			log "slot $slot: golden image missing: $GOLDEN; waiting 60s"
			nap 60
			continue
		fi

		name="${NAME_PREFIX}-${slot}-$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')"
		dir="$RUN_DIR/$name"
		install -d -m 0700 "$dir"

		# The group lookup runs here, in the supervisor shell, so its result
		# survives across cycles; inside the mint's subshell it would not.
		local jit
		if ! runner_group_id || ! jit="$(mint_jit "$name")"; then
			mint_fails=$((mint_fails + 1))
			rm -rf "$dir"
			dir=""
			name=""
			# A cached group id may be what failed (group deleted or renamed).
			_RG_ID=""
			# Past this many failures the cause may be the host itself (the
			# nftables sets are stale: a resolver or endpoint moved since the
			# last refresh); exiting lets the unit restart, and its netcheck
			# refresh them again.
			((mint_fails < JIT_FAILS_BEFORE_RESTART)) ||
				die "slot $slot: $mint_fails consecutive jit mint failures; exiting so the unit restarts"
			local backoff=$((30 * mint_fails))
			((backoff > JIT_BACKOFF_MAX)) && backoff=$JIT_BACKOFF_MAX
			log "slot $slot: jit mint failed (#$mint_fails), retry in ${backoff}s"
			nap "$backoff"
			continue
		fi
		mint_fails=0

		printf '#cloud-config\nhostname: %s\nusers: []\ndisable_root: true\nssh_pwauth: false\nwrite_files:\n  - path: /run/gha-jit\n    encoding: b64\n    permissions: "0600"\n    content: %s\n  - path: /run/gha-env\n    permissions: "0600"\n    content: "GHA_DOCKER_WAIT=%s\\n"\nruncmd:\n  - [ /usr/local/bin/gha-job.sh ]\n' \
			"$name" "$(printf '%s' "$jit" | base64 -w0)" "$((BOOT_TIMEOUT < 60 ? BOOT_TIMEOUT : 60))" >"$dir/user-data"
		printf 'instance-id: %s\nlocal-hostname: %s\n' "$name" "$name" >"$dir/meta-data"
		local netcfg=()
		if [[ -n "$GUEST_RUNTIME_DNS" ]]; then
			guest_network_config >"$dir/network-config"
			netcfg=(-N "$dir/network-config")
		fi
		cloud-localds "${netcfg[@]}" "$dir/seed.img" "$dir/user-data" "$dir/meta-data"
		rm -f "$dir/user-data" "$dir/network-config"
		jit=""

		qemu-img create -q -f qcow2 -F qcow2 -b "$GOLDEN" "$dir/disk.qcow2" >/dev/null
		cp "$vars" "$dir/vars.fd"
		: >"$dir/console.log"

		# Console goes to a file so the watchdog can read it; tail relays it to the
		# journal so `journalctl -fu gha-vm@N` still shows a live job.
		# Neither child may inherit the slot lock (fd 9): a VM outliving a
		# killed supervisor would otherwise block the replacement from starting.
		tail -n +1 -F "$dir/console.log" >&2 9>&- &
		tailpid=$!

		local started
		started=$(date +%s)
		build_qemu_args "$name" "$dir" "$code" "$cpu"
		"$QEMU_BIN" "${QEMU_ARGS[@]}" 9>&- &
		vmpid=$!

		local reason="" now elapsed
		ready=0
		while kill -0 "$vmpid" 2>/dev/null; do
			nap 5
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
			wait_pid "$vmpid" 60 || kill -KILL "$vmpid" 2>/dev/null || true
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
		# A normal exit means the runner deregistered itself; one API call per
		# job just to confirm that is what the hourly reap_slot is for. A VM
		# that was killed or never came up is deregistered right away.
		now=$(date +%s)
		if [[ -n "$reason" ]] || ((ready == 0)); then
			reap_one "$name" || log "slot $slot: WARN could not deregister $name; it will be reaped later"
		elif ((now - last_reap >= REAP_INTERVAL)); then
			reap_slot "$slot" || log "slot $slot: WARN periodic reap failed; continuing"
			last_reap=$now
		fi
		log "slot $slot: vm exited rc=$rc after ${elapsed}s${reason:+ ($reason)}"
		name=""

		if ((elapsed < 30 || ready == 0)); then
			fails=$((fails + 1))
			local backoff=$((fails > 6 ? 60 : fails * 10))
			log "slot $slot: unhealthy cycle #$fails, backing off ${backoff}s"
			nap "$backoff"
		else
			fails=0
		fi
		ready=0
	done
}

# Drain: the slot finishes its current job and then idles until undrained.
# A drained slot's unit stays active, so a reboot or `install` restarts it
# normally; the flag lives under RUN_DIR and clears with `undrain`.
slot_list() { # $1 = slot|all -> one slot number per line
	if [[ "${1:-all}" == all ]]; then
		systemctl list-units --no-legend --all 'gha-vm@*.service' 2>/dev/null |
			awk '{print $1}' | sed -E 's/^gha-vm@([0-9]+)\.service$/\1/' | grep -E '^[0-9]+$' | sort -n
	else
		[[ "$1" =~ ^[0-9]+$ ]] || die "slot must be a number or 'all'"
		printf '%s\n' "$1"
	fi
}

cmd_drain() {
	local s
	install -d -m 0750 "$RUN_DIR"
	while read -r s; do
		[[ -n "$s" ]] || continue
		: >"$(drain_flag "$s")"
		chown "$GHA_USER":"$GHA_USER" "$(drain_flag "$s")" 2>/dev/null || true
		log "slot $s: drain requested; it finishes the current job and then idles"
	done < <(slot_list "${1:-all}")
}

cmd_undrain() {
	local s
	while read -r s; do
		[[ -n "$s" ]] || continue
		rm -f "$(drain_flag "$s")"
		log "slot $s: undrained"
	done < <(slot_list "${1:-all}")
}

# Drain, wait for the current job to finish, restart the unit, undrain. Used
# after `install` rewrote the unit, or after this script was updated, without
# losing a running job.
cmd_restart() {
	[[ $EUID -eq 0 ]] || die "restart must run as root"
	local s w
	while read -r s; do
		[[ -n "$s" ]] || continue
		: >"$(drain_flag "$s")"
		w=0
		while [[ -n "$(find "$RUN_DIR" -mindepth 1 -maxdepth 1 -type d -name "${NAME_PREFIX}-${s}-*" 2>/dev/null)" ]]; do
			if ((w >= STOP_GRACE_SEC)); then
				log "slot $s: job still running after ${STOP_GRACE_SEC}s; restarting anyway"
				break
			fi
			((w % 60 == 0)) && log "slot $s: waiting for the current job to finish (${w}s)"
			sleep 5
			w=$((w + 5))
		done
		rm -f "$(drain_flag "$s")"
		systemctl restart "gha-vm@${s}.service" || die "could not restart gha-vm@${s}.service"
		log "slot $s: restarted"
	done < <(slot_list "${1:-all}")
}

# ------------------------------------------------------------- reap/clean ----

# Host-wide reap. Skips names that still have a live run directory, so it is
# safe to run while slots are working. Only names shaped like this host's own
# slot names are considered, so a sibling host sharing a NAME_PREFIX stem
# (gha-box and gha-box2) never reaps the other's runners.
cmd_reap() {
	local id name runners
	runners="$(list_runners)" || die "could not list runners; nothing reaped"
	while read -r id name; do
		[[ -n "$id" ]] || continue
		if [[ -d "$RUN_DIR/$name" ]]; then continue; fi
		log "reaping stale runner $name (id=$id)"
		api DELETE "$(runners_path)/$id" >/dev/null ||
			log "WARN could not delete runner $name (id=$id)"
	done < <(jq -r --arg p "^${NAME_PREFIX}-[0-9]+-" \
		'select(.name|test($p)) | select(.status=="offline") | "\(.id) \(.name)"' <<<"$runners")
}

# Whether a slot supervisor currently holds slot $1's lock.
slot_is_live() {
	local f="$RUN_DIR/.slot-$1.lock"
	[[ -e "$f" ]] || return 1
	! flock -n -x "$f" true 2>/dev/null
}

# Removes leftover run directories, then reaps. A directory whose slot has a
# live supervisor is that slot's running VM and is left alone unless --force.
cmd_clean() {
	local force=0 d slot skipped=0
	[[ "${1:-}" == --force ]] && force=1
	for d in "$RUN_DIR"/*/; do
		[[ -d "$d" ]] || continue
		slot="$(basename "$d")"
		slot="${slot#"${NAME_PREFIX}"-}"
		slot="${slot%%-*}"
		if ((force == 0)) && [[ "$slot" =~ ^[0-9]+$ ]] && slot_is_live "$slot"; then
			log "clean: slot $slot is running; keeping $(basename "$d") (use --force to remove)"
			skipped=$((skipped + 1))
			continue
		fi
		rm -rf "$d"
	done
	((skipped)) && log "clean: $skipped live run dir(s) kept"
	cmd_reap
}

# ---------------------------------------------------------------- doctor ----

cmd_capacity() {
	local ram_mb cores avail per_mb reserve_mb slots_mem slots_cpu slots_disk rec bound
	ram_mb=$(($(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 1024))
	cores=$(nproc)
	avail="$(free_gb "$STATE_DIR")"
	avail="${avail:-0}"
	per_mb="$(mem_to_mb "$VM_MEM")"
	((per_mb > 0)) || die "VM_MEM must be above zero (got '$VM_MEM')"
	local k
	for k in HOST_RESERVE_GB CPU_OVERCOMMIT MAX_SLOTS; do
		[[ "${!k}" =~ ^[0-9]+$ ]] || die "$k must be a whole number (got '${!k}')"
	done
	for k in VM_CPUS DISK_PER_SLOT_GB; do
		[[ "${!k}" =~ ^[1-9][0-9]*$ ]] || die "$k must be a positive integer (got '${!k}')"
	done
	reserve_mb=$((HOST_RESERVE_GB * 1024))

	slots_mem=$(((ram_mb - reserve_mb) / per_mb))
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
		"$cores" "$((ram_mb / 1024))" "$avail" "$STATE_DIR" "$virt"
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
	printf 'arch           %s (runner label %s, %s)\n' "$HOST_ARCH" "$RUNNER_ARCH" "$QEMU_BIN"
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
	[[ -r "$LOCAL_FILE" ]] && printf 'local override %s\n' "$LOCAL_FILE"
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

	if [[ "$RUNNER_ARCH" == x64 ]] && ! kvm_module >/dev/null && cpu_has_virt; then
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
	elif ! net_sets_current || ! net_conf_current; then
		log "repair: isolation rules predate the current sets; re-rendering"
		cmd_net
		fixed=1
	fi

	if [[ "$HOST_UNATTENDED" == 1 && ! -e /etc/apt/apt.conf.d/52gha-vm ]] ||
		[[ "$HOST_UNATTENDED" != 1 && -e /etc/apt/apt.conf.d/52gha-vm ]]; then
		log "repair: applying the host update policy"
		setup_unattended
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

# GitHub's default only gates a contributor's FIRST run, so one merged typo fix
# buys an account unreviewed use of this hardware forever. Printed under the
# public-exposure DANGER because that is the case where it stops being a spend
# control and becomes the only review gate in front of the runners.
fork_approval_advice() {
	local who
	who="${GITHUB_ORG:-${GITHUB_REPO%%/*}}"
	cat <<EOF
  Make sure to switch this setting before enabling slots:
    Org -> Settings -> Actions -> General
    -> "Approval for running fork pull request workflows from contributors"
    -> select "Require approval for all external contributors"
  It covers every repo in the org and overrides the enterprise-level setting.
  Or, with a token holding admin:org (the runner app does not):
    gh api -X PUT /orgs/${who:-<YOUR-ORG>}/actions/permissions/fork-pr-contributor-approval \\
      -f approval_policy=all_external_contributors
  The default (first_time_contributors) only gates a contributor's first run.
EOF
}

# Empty on a host without systemctl; callers treat that as "unknown".
systemd_version() {
	{ systemctl --version 2>/dev/null || :; } | awk 'NR==1 {print $2; exit}' | tr -dc '0-9'
}

# Copies $2 to $3 with mode $1 through a same-directory temp file and a
# rename, so a reader never sees a half-written target.
install_atomic() {
	local mode="$1" src="$2" dst="$3" tmp
	tmp="$(mktemp "$dst.XXXXXX")"
	install -m "$mode" "$src" "$tmp" || {
		rm -f "$tmp"
		die "could not copy $src to $dst"
	}
	mv -f "$tmp" "$dst"
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

	printf 'arch: %s (runner label %s)' "$HOST_ARCH" "$RUNNER_ARCH"
	[[ "$RUNNER_ARCH" == arm64 ]] && printf '  [arm64 is parametrised but has not been exercised end to end]'
	echo

	printf 'tools: '
	local miss=()
	for t in "$QEMU_BIN" qemu-img cloud-localds virt-customize nft jq curl openssl flock gpgv; do
		command -v "$t" >/dev/null 2>&1 || miss+=("$t")
	done
	if ((${#miss[@]})); then
		echo "missing: ${miss[*]}"
		ok=1
	else echo OK; fi

	printf 'firmware: '
	if ovmf_pair >/dev/null 2>&1; then echo "OK ($(ovmf_pair | tr '\n' ' '))"; else
		echo FAIL
		ok=1
	fi

	printf 'systemd: '
	local sdv
	sdv="$(systemd_version)"
	if [[ -n "$sdv" ]] && ((sdv >= 254)); then
		echo "OK ($sdv)"
	else
		echo "${sdv:-unknown}; RestartSteps needs 254+, slot units fall back to a fixed 5s restart delay"
	fi

	printf 'config perms: '
	local mode
	mode="$(stat -c '%a' "$CONFIG" 2>/dev/null || echo 000)"
	if ((8#$mode & 8#0007)); then
		echo "FAIL: $CONFIG is mode $mode; want 0640 root:$GHA_USER"
		ok=1
	elif ! user_can_read "$GHA_USER" "$CONFIG"; then
		echo "FAIL: $GHA_USER cannot read $CONFIG"
		ok=1
	else echo "OK ($mode)"; fi

	if [[ "$AUTH_MODE" == app ]]; then
		printf 'app key: '
		if user_can_read "$GHA_USER" "$GITHUB_APP_KEY"; then
			echo OK
		else
			echo "FAIL: $GHA_USER cannot read $GITHUB_APP_KEY (chown root:$GHA_USER, chmod 0640)"
			ok=1
		fi
	fi

	printf 'kvm module: '
	if [[ "$RUNNER_ARCH" == arm64 ]]; then
		if [[ -c /dev/kvm ]]; then echo "OK (built-in)"; else
			echo "FAIL: no /dev/kvm; the firmware or hypervisor is not exposing virtualization"
			ok=1
		fi
	else
		# kvm_module prints the name, so calling it as the condition leaks that
		# name onto the report line before the verdict is written.
		local kvmmod=""
		kvmmod="$(kvm_module)" || kvmmod=""
		if [[ -n "$kvmmod" ]]; then
			echo "OK ($kvmmod)"
		elif cpu_has_virt; then
			echo "not loaded (run: $SELF repair)"
			ok=1
		else
			echo "FAIL: CPU exposes neither vmx nor svm; enable virtualization in the BIOS"
			ok=1
		fi
	fi

	printf 'apt: '
	apt_holder="$(apt_lock_holder)"
	if [[ -n "$apt_holder" ]]; then
		echo "locked by $apt_holder; deps will wait on it"
		ok=1
	else echo OK; fi

	printf 'host updates: '
	if [[ "$HOST_UNATTENDED" != 1 ]]; then
		echo "manual (HOST_UNATTENDED=0)"
	elif [[ -e /etc/apt/apt.conf.d/52gha-vm ]] && systemctl is-enabled --quiet unattended-upgrades.service 2>/dev/null; then
		echo "OK (unattended, auto-reboot $([[ "$HOST_AUTO_REBOOT" == 1 ]] && echo "at $HOST_AUTO_REBOOT_TIME" || echo off))"
	else
		echo "not configured (run: $SELF repair)"
		ok=1
	fi

	printf 'clock: '
	if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == yes ]]; then echo OK; else
		echo "not NTP-synchronized; GitHub App auth fails on skew"
		ok=1
	fi

	printf 'golden image: '
	if [[ -f "$GOLDEN" ]]; then
		local age_days
		age_days=$((($(date +%s) - $(stat -c %Y "$GOLDEN")) / 86400))
		if ((age_days > GOLDEN_MAX_AGE_DAYS)); then
			echo "WARN: $age_days days old (GOLDEN_MAX_AGE_DAYS=$GOLDEN_MAX_AGE_DAYS); is gha-vm-upgrade.timer running?"
		else
			echo "OK ($GOLDEN, $(du -h "$GOLDEN" | cut -f1), ${age_days}d old$([[ -f "$GOLDEN.prev" ]] && echo ', .prev kept'))"
		fi
	else
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
	# Two things force the command substitution. auth_token dies on failure, and
	# called bare in an `if` it is NOT in a subshell -- its exit would end the whole
	# report, silently skipping every check below. And its message is the single
	# most useful line here (which of 401/404/422, and what to do), so capture
	# stderr and print it rather than discarding it with the token.
	local autherr=""
	if autherr="$(auth_token 2>&1 >/dev/null)"; then echo "OK ($AUTH_MODE)"; else
		echo FAIL
		[[ -n "$autherr" ]] && printf '  %s\n' "$autherr"
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

	if [[ -n "$RUNNER_GROUP" && "$SCOPE" == org ]]; then
		printf 'runner group: '
		local rg_rc=0
		runner_group_id 2>/dev/null || rg_rc=$?
		case "$rg_rc" in
		0) echo "OK ($RUNNER_GROUP = id $_RG_ID)" ;;
		2)
			echo "FAIL: no runner group named '$RUNNER_GROUP' in $GITHUB_ORG"
			ok=1
			;;
		*)
			echo "FAIL: could not list the runner groups of $GITHUB_ORG (API error; check the credential and GITHUB_API_URL)"
			ok=1
			;;
		esac
	fi

	printf 'public repo exposure: '
	# An API failure is reported as such: an unreadable answer is not "private".
	local resp
	if [[ "$SCOPE" == repo ]]; then
		if ! resp="$(api GET "/repos/$GITHUB_REPO" 2>/dev/null)"; then
			echo "UNKNOWN: could not read /repos/$GITHUB_REPO"
			ok=1
		elif [[ "$(jq -r .private <<<"$resp")" == false ]]; then
			echo "DANGER: $GITHUB_REPO is public; fork PRs execute arbitrary code here"
			fork_approval_advice
			ok=1
		else echo OK; fi
	else
		if ! resp="$(api GET "/orgs/$GITHUB_ORG/repos?type=public&per_page=1" 2>/dev/null)"; then
			echo "UNKNOWN: could not list $GITHUB_ORG's public repos"
			ok=1
		elif [[ "$(jq 'length' <<<"$resp")" -gt 0 ]]; then
			echo "DANGER: org has public repos; restrict the runner group to private repos"
			fork_approval_advice
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
	elif ! net_sets_current || ! net_conf_current; then
		echo "stale: sets predate the current ruleset; they cannot self-heal (re-run: $SELF net)"
		ok=1
	elif ! grep -q 'include "'"$NFT_CONF"'"' "$NFT_MAIN" 2>/dev/null; then
		echo "loaded but not included from $NFT_MAIN; netcheck reloads it at slot start (re-run: $SELF net)"
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
	local s
	for s in "$RUN_DIR"/.slot-*.drain; do
		[[ -e "$s" ]] || continue
		s="${s##*/.slot-}"
		echo "slot ${s%.drain}: DRAINED (undrain with: $SELF undrain ${s%.drain})"
	done
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
	local runners rows
	if ! runners="$(list_runners)"; then
		echo "UNAVAILABLE: could not list runners (see the api: line above)"
		return 1
	fi
	rows="$(jq -r --arg p "$NAME_PREFIX" \
		'select(.name|startswith($p)) | "\(.name)\t\(.status)\tbusy=\(.busy)"' <<<"$runners")"
	if command -v column >/dev/null 2>&1; then
		column -t <<<"$rows"
	else
		cat <<<"$rows"
	fi
}

# --------------------------------------------------------------- install ----

# Writes the three unit files from the effective config. Pure file output so
# `render` can produce them into a staging tree for inspection.
unit_render() {
	local mem_mb sdv restart_lines
	mem_mb="$(mem_to_mb "$VM_MEM")"
	sdv="$(systemd_version)"
	# RestartSteps ramps the restart delay from RestartSec to
	# RestartMaxDelaySec so a broken host does not spin every 5s forever.
	if [[ -z "$sdv" ]] || ((sdv >= 254)); then
		restart_lines=$'RestartSec=5\nRestartSteps=8\nRestartMaxDelaySec=300'
	else
		restart_lines='RestartSec=5'
	fi
	install -d -m 0755 "$SYSTEMD_DIR"

	cat >"$UNIT" <<EOF
[Unit]
Description=Ephemeral GitHub Actions runner VM (slot %i)
After=network-online.target nftables.service time-sync.target
Wants=network-online.target nftables.service
StartLimitIntervalSec=0

[Service]
Type=simple
User=${GHA_USER}
Group=${GHA_USER}
SupplementaryGroups=kvm
Environment=GHA_CONFIG=${CONFIG}
EnvironmentFile=-$(dirname "$CONFIG")/env
ExecStartPre=+${LIBEXEC}/gha-vm.sh netcheck
ExecStart=${LIBEXEC}/gha-vm.sh run %i
Restart=always
${restart_lines}
# netcheck resolves every endpoint with a bounded resolver; this covers the
# worst case of all of them timing out.
TimeoutStartSec=300
# The supervisor lets a running job finish for STOP_GRACE_SEC before killing
# the VM; the unit gives it that plus a margin for cleanup.
TimeoutStopSec=$((STOP_GRACE_SEC + 120))
KillSignal=SIGTERM
KillMode=mixed
SyslogIdentifier=gha-vm
LogRateLimitIntervalSec=30
LogRateLimitBurst=20000
UMask=0077

# One runaway slot must not take the host down with it.
MemoryMax=$((mem_mb + 2048))M
CPUWeight=50
IOWeight=50

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${STATE_DIR}
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
ProtectProc=invisible
RestrictSUIDSGID=true
RestrictNamespaces=true
RestrictRealtime=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
SystemCallArchitectures=native
LockPersonality=true
RemoveIPC=true
CapabilityBoundingSet=
MemoryDenyWriteExecute=false
DevicePolicy=closed
DeviceAllow=/dev/kvm rw

[Install]
WantedBy=multi-user.target
EOF

	cat >"$UPGRADE_UNIT" <<EOF
[Unit]
Description=Rebuild the gha-vm golden image on the latest runner release
After=network-online.target
Wants=network-online.target
ConditionPathExists=${CONFIG}

[Service]
Type=oneshot
Environment=GHA_CONFIG=${CONFIG}
EnvironmentFile=-$(dirname "$CONFIG")/env
ExecStart=${LIBEXEC}/gha-vm.sh upgrade
TimeoutStartSec=3h
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
PrivateTmp=true
EOF

	cat >"$UPGRADE_TIMER" <<EOF
[Unit]
Description=Weekly gha-vm golden image rebuild

[Timer]
OnCalendar=Sun 03:00
RandomizedDelaySec=1h
FixedRandomDelay=true
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

# Units and the ruleset, written to wherever GHA_SYSTEMD_DIR and GHA_NFT_CONF
# point, with no systemctl or nft call. This is what the test suite diffs.
cmd_render() {
	validate_sizing
	unit_render
	net_write
	log "rendered $UNIT $UPGRADE_UNIT $UPGRADE_TIMER $NFT_CONF"
}

cmd_install() {
	local count="${1:-}"
	[[ $EUID -eq 0 ]] || die "install must run as root"
	# Without a count an installed fleet keeps its size; only a first install
	# falls back to two slots.
	if [[ -z "$count" ]]; then
		count="$(systemctl list-unit-files 'gha-vm@*.service' --state=enabled --no-legend 2>/dev/null | grep -c '^gha-vm@[0-9]' || :)"
		((count > 0)) || count=2
	fi
	[[ "$count" =~ ^[0-9]+$ && "$count" -ge 1 ]] || die "install needs a slot count >= 1"

	# An explicit count from the operator wins over the profile, but going past
	# what the profile reserved this machine for is worth saying out loud.
	if ((MAX_SLOTS > 0)) && ((count > MAX_SLOTS)); then
		log "WARN: installing $count slots, above MAX_SLOTS=$MAX_SLOTS from profile '$HOST_PROFILE'"
		log "WARN: this host was profiled for other work too; check '$SELF capacity'"
	fi

	# The unit must not depend on a git checkout that can move or change under a
	# running fleet. The example config and profiles ride along so deps and
	# upgrade work from the installed copy alone.
	install -d -m 0755 "$LIBEXEC"
	# Running from the installed copy (gha-vm install after an upgrade) has
	# nothing to copy. Each file lands by rename: a supervisor re-executing
	# itself mid-copy must see either the old script or the new one, whole.
	if ! [[ "$HERE/gha-vm.sh" -ef "$LIBEXEC/gha-vm.sh" ]]; then
		install_atomic 0755 "$HERE/gha-vm.sh" "$LIBEXEC/gha-vm.sh"
		install_atomic 0755 "$HERE/gha-job.sh" "$LIBEXEC/gha-job.sh"
		[[ -r "$HERE/config.vm.env.example" ]] &&
			install_atomic 0644 "$HERE/config.vm.env.example" "$LIBEXEC/config.vm.env.example"
		if [[ -d "$HERE/profiles" ]]; then
			rm -rf "$LIBEXEC/profiles.new"
			cp -r "$HERE/profiles" "$LIBEXEC/profiles.new" || die "could not copy $HERE/profiles to $LIBEXEC"
			rm -rf "$LIBEXEC/profiles"
			mv "$LIBEXEC/profiles.new" "$LIBEXEC/profiles"
		fi
	fi
	ln -sfn "$LIBEXEC/gha-vm.sh" /usr/local/bin/gha-vm

	unit_render

	# Only what the supervisor writes to; the golden and .prev stay readable
	# for it without handing it the whole tree.
	install -d -o "$GHA_USER" -g "$GHA_USER" -m 0750 "$STATE_DIR" "$RUN_DIR"
	local f
	for f in "$GOLDEN" "$GOLDEN.prev"; do
		[[ -e "$f" ]] && chown "$GHA_USER":"$GHA_USER" "$f"
	done
	systemctl daemon-reload

	# Rules from before the current sets existed cannot self-heal at slot
	# start; re-render them once. The file on disk is what boot loads, so it
	# is checked too.
	if { nft list table inet gha >/dev/null 2>&1 && ! net_sets_current; } ||
		{ [[ -r "$NFT_CONF" ]] && ! net_conf_current; }; then
		log "isolation rules predate the current sets; re-rendering"
		cmd_net
	fi

	# Shrinking the fleet must actually shrink it.
	local u i
	while read -r u; do
		i="${u##*@}"
		i="${i%.service}"
		if [[ "$i" =~ ^[0-9]+$ ]] && ((i > count)); then
			log "removing surplus slot $i"
			systemctl disable --now "gha-vm@${i}.service" >/dev/null 2>&1 ||
				log "WARN: could not disable gha-vm@${i}.service"
		fi
	done < <(systemctl list-unit-files --no-legend 'gha-vm@*.service' 2>/dev/null | awk '{print $1}')

	local was_active=0
	for i in $(seq 1 "$count"); do
		systemctl is-active --quiet "gha-vm@${i}.service" 2>/dev/null && was_active=$((was_active + 1))
		systemctl enable --now "gha-vm@${i}.service"
	done
	systemctl enable --now gha-vm-upgrade.timer >/dev/null 2>&1 ||
		log "WARN: could not enable gha-vm-upgrade.timer; the golden image will not refresh itself"

	log "installed $count slots; logs: journalctl -fu 'gha-vm@*'"
	if ((was_active)); then
		log "$was_active slot(s) were already running and keep the old unit/script until restarted: $SELF restart all"
	fi
	cmd_capacity
}

cmd_uninstall() {
	[[ $EUID -eq 0 ]] || die "uninstall must run as root"
	local u
	while read -r u; do
		[[ -n "$u" ]] || continue
		systemctl disable --now "$u" >/dev/null 2>&1 ||
			log "WARN: could not disable $u"
	done < <(systemctl list-units --no-legend --all 'gha-vm@*.service' 2>/dev/null | awk '{print $1}')
	systemctl disable --now gha-vm-upgrade.timer >/dev/null 2>&1 ||
		log "WARN: could not disable gha-vm-upgrade.timer"
	rm -f "$UNIT" "$UPGRADE_UNIT" "$UPGRADE_TIMER" "$RUN_DIR"/.slot-*.drain
	systemctl daemon-reload
	cmd_clean --force
	log "units removed; $STATE_DIR, $CONFIG and the nftables rules were left in place"
}

# ---------------------------------------------------------------- config ----

# The knobs apply_defaults resolves, in the order it resolves them. Kept as
# one list so `config` and the docs agree on what exists.
CONFIG_KEYS=(
	HOST_ARCH RUNNER_ARCH CLOUDIMG_ARCH QEMU_BIN QEMU_MACHINE QEMU_PACKAGE QEMU_SANDBOX QEMU_EXTRA_ARGS
	UBUNTU_RELEASE CLOUDIMG_BASE CLOUDIMG_NAME
	GITHUB_SERVER_URL GITHUB_API_URL RUNNER_DOWNLOAD_BASE
	HTTP_PROXY HTTPS_PROXY NO_PROXY GUEST_HTTP_PROXY GUEST_NO_PROXY
	API_MAXTIME API_RETRY GUEST_DNS
	STATE_DIR GOLDEN RUN_DIR GHA_USER
	VM_CPUS VM_MEM VM_DISK VM_CPU NESTED_VIRT
	MAX_LIFETIME BOOT_TIMEOUT MIN_FREE_GB
	STOP_GRACE_SEC REAP_ON_STOP REAP_INTERVAL JIT_BACKOFF_MAX CLOCK_SYNC_WAIT
	HOST_RESERVE_GB CPU_OVERCOMMIT DISK_PER_SLOT_GB
	RUNNER_VERSION RUNNER_SHA256 RUNNER_LABELS RUNNER_LABELS_APPEND_HOST RUNNER_GROUP_ID RUNNER_GROUP NAME_PREFIX
	ALLOW_UNVERIFIED_RUNNER AUTO_RUNNER_VERSION UPGRADE_REBUILD SPARSIFY
	APT_LOCK_WAIT APT_LOCK_TRIES REQUIRE_ISOLATION
	NET_ALLOW_CIDRS NET_BLOCK_EXTRA NET_BLOCK_HOST_ADDRS NET_DNS_ADDRS NET_HOST_ADDRS NET_ENDPOINT_ADDRS
	GUEST_PACKAGES GUEST_EXTRA_PACKAGES IMAGE_HOOK_DIR GUEST_PRE_JOB_HOOK GUEST_RUNTIME_DNS
	IMAGE_SELFTEST GOLDEN_KEEP_PREVIOUS GOLDEN_MAX_AGE_DAYS
	HOST_UNATTENDED HOST_AUTO_REBOOT HOST_AUTO_REBOOT_TIME
	MAX_SLOTS AUTOTUNE AUTOTUNE_HEADROOM_GB HOST_PROFILE PROFILE_FILE LOCAL_FILE
	SCOPE GITHUB_ORG GITHUB_REPO AUTH_MODE GITHUB_APP_ID GITHUB_APP_KEY GITHUB_PAT
)

# Effective configuration after config.env, profile, local.env and defaults.
# One KEY prints the bare value (for scripts); no key prints every KEY=VALUE.
# The PAT is masked in the listing and only printed when asked for by name.
cmd_config() {
	local key="${1:-}" k v
	if [[ -n "$key" ]]; then
		[[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "config: KEY must be an upper-case identifier"
		printf '%s\n' "${!key:-}"
		return 0
	fi
	for k in "${CONFIG_KEYS[@]}"; do
		v="${!k:-}"
		[[ "$k" == GITHUB_PAT && -n "$v" ]] && v="<set>"
		printf '%s=%s\n' "$k" "$v"
	done
}

# ------------------------------------------------------------------ main ----

usage() { sed -n '3,/^# --- end usage ---$/{/^# --- end usage ---$/!p}' "$SELF" | sed 's/^# \{0,1\}//'; }

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
	config)
		load_config_optional
		cmd_config "$@"
		;;
	render)
		load_config_optional
		cmd_render
		;;
	config-set)
		# VALUE of - reads the value from stdin, keeping a secret off argv.
		[[ $# -ge 2 ]] || die "usage: $SELF config-set KEY VALUE|- [FILE]"
		local val="$2"
		if [[ "$val" == - ]]; then
			IFS= read -r val || [[ -n "$val" ]] || die "config-set $1: empty value on stdin"
		fi
		config_set "$1" "$val" "${3:-$CONFIG}"
		;;
	config-unset)
		[[ $# -ge 1 ]] || die "usage: $SELF config-unset KEY [FILE]"
		config_unset "$1" "${2:-$CONFIG}"
		;;
	image)
		load_config
		cmd_image
		;;
	rollback)
		load_config
		cmd_rollback
		;;
	upgrade)
		load_config
		cmd_upgrade "$@"
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
	drain)
		load_config
		cmd_drain "$@"
		;;
	undrain)
		load_config
		cmd_undrain "$@"
		;;
	restart)
		load_config
		cmd_restart "$@"
		;;
	reap)
		load_config
		cmd_reap
		;;
	clean)
		load_config
		cmd_clean "$@"
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
		usage
		exit 1
		;;
	esac
}

main "$@"
