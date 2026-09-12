#!/usr/bin/env bash
# Test suite for gha-vm.sh. Lints on the host, then renders the systemd units
# and the nftables ruleset from tests/config.test.env inside ubuntu:24.04 and
# diffs them against tests/expected, checks them with systemd-analyze and nft,
# and exercises the atomic config editor.
#   tests/run.sh            run everything (docker needed for the render part)
#   tests/run.sh --update   rewrite tests/expected from the current render
set -Eeuo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ROOT="$(dirname "$HERE")"
IMAGE="${GHA_TEST_IMAGE:-ubuntu:24.04}"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}
pass() { printf 'ok   %s\n' "$*"; }

# ----------------------------------------------------------- inside docker ----

# Runs as root in the container with the repo at /src and this directory at
# /tests (read-write when updating expectations).
inside() {
	local update="$1" out=/out rc=0
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq >/dev/null
	apt-get install -y -qq --no-install-recommends systemd nftables >/dev/null
	groupadd -f kvm
	id -u gha >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin -u 999 gha
	install -d -m 0750 -g gha /etc/gha-vm
	install -m 0640 -g gha /tests/config.test.env /etc/gha-vm/config.env
	: >/etc/gha-vm/app.pem
	install -d /usr/local/lib/gha-vm
	install -m 0755 /src/gha-vm.sh /src/gha-job.sh /usr/local/lib/gha-vm/
	local gha=/usr/local/lib/gha-vm/gha-vm.sh
	install -d "$out"

	# --- render + diff -------------------------------------------------------
	GHA_SYSTEMD_DIR="$out" GHA_NFT_CONF="$out/nftables.conf" "$gha" render 2>/dev/null ||
		fail "render exited non-zero"
	local f
	for f in gha-vm@.service gha-vm-upgrade.service gha-vm-upgrade.timer nftables.conf; do
		[[ -s "$out/$f" ]] || fail "render produced no $f"
		if ((update)); then
			cp "$out/$f" "/tests/expected/$f"
			pass "updated expected/$f"
		elif diff -u "/tests/expected/$f" "$out/$f"; then
			pass "render $f matches expected"
		else
			rc=1
		fi
	done
	((rc == 0)) || fail "rendered output differs from tests/expected (run tests/run.sh --update if intended)"

	# --- the units load in systemd -------------------------------------------
	local v=/tmp/verify
	install -d "$v"
	cp "$out"/gha-vm@.service "$out"/gha-vm-upgrade.service "$out"/gha-vm-upgrade.timer "$v/"
	local verify_out
	verify_out="$(systemd-analyze verify --recursive-errors=no "$v/gha-vm@1.service" "$v/gha-vm-upgrade.service" "$v/gha-vm-upgrade.timer" 2>&1)" ||
		fail "systemd-analyze verify failed:
$verify_out"
	if grep -Eiq 'unknown|failed|invalid|ignoring' <<<"$verify_out"; then
		fail "systemd-analyze verify reported a problem:
$verify_out"
	fi
	pass "systemd-analyze verify accepts the units"
	grep -q '^RestartSteps=8$' "$out/gha-vm@.service" || fail "slot unit lacks RestartSteps on systemd $(systemctl --version | head -1)"
	grep -q '^TimeoutStopSec=1020$' "$out/gha-vm@.service" || fail "TimeoutStopSec is not STOP_GRACE_SEC+120"
	grep -q '^TimeoutStartSec=300$' "$out/gha-vm@.service" || fail "slot unit lacks the start timeout that bounds netcheck"
	grep -q '^MemoryMax=10240M$' "$out/gha-vm@.service" || fail "MemoryMax is not VM_MEM+2048M"
	pass "slot unit derives restart, stop and memory limits from config"

	# --- the ruleset parses -------------------------------------------------
	local nft_out
	if nft_out="$(nft -c -f "$out/nftables.conf" 2>&1)"; then
		pass "nft -c accepts the ruleset"
	elif grep -q 'Operation not permitted' <<<"$nft_out"; then
		echo "NFT: PARTIAL -- nft -c needs CAP_NET_ADMIN in the container (run with --cap-add NET_ADMIN)"
	else
		fail "nft -c rejected the ruleset:
$nft_out"
	fi
	grep -q '127.0.0.0/8' "$out/nftables.conf" || fail "ruleset lost the loopback marker netcheck looks for"
	grep -q 'set dns4 { type ipv4_addr; elements = { 10.0.0.53 } }' "$out/nftables.conf" || fail "dns4 set not populated from NET_DNS_ADDRS"
	grep -q 'set host6 { type ipv6_addr; elements = { 2001:db8::10 } }' "$out/nftables.conf" || fail "host6 set not populated from NET_HOST_ADDRS"
	grep -q 'meta skuid 999 ip  daddr { 192.168.50.0/24 } counter accept' "$out/nftables.conf" || fail "NET_ALLOW_CIDRS v4 accept missing"
	grep -q '100.64.0.0/10' "$out/nftables.conf" || fail "NET_BLOCK_EXTRA default did not add CGNAT to the drops"
	grep -q 'set ep4 { type ipv4_addr . inet_service; elements = { 10.10.0.4 . 443 } }' "$out/nftables.conf" || fail "ep4 set not populated from NET_ENDPOINT_ADDRS with the default port"
	grep -q 'set ep6 { type ipv6_addr . inet_service; elements = { fd00:10::4 . 8443 } }' "$out/nftables.conf" || fail "ep6 set did not keep the [addr]:port from NET_ENDPOINT_ADDRS"
	# The endpoint accept is port-scoped and must precede every drop, or a GHES
	# on the LAN is cut off.
	local accept_at drop_at
	accept_at="$(grep -n 'ip  daddr \. tcp dport @ep4 counter accept' "$out/nftables.conf" | cut -d: -f1)"
	drop_at="$(grep -n 'counter drop' "$out/nftables.conf" | head -n1 | cut -d: -f1)"
	[[ -n "$accept_at" ]] || fail "port-scoped endpoint accept missing from the ruleset"
	[[ -n "$drop_at" ]] || fail "ruleset has no drop rule"
	((accept_at < drop_at)) || fail "endpoint accept is not ahead of the drops"
	pass "ruleset carries sets, allow list, endpoint accepts and extra drops"

	# A host with IPv4-only resolvers, no global IPv6 and a v4-only endpoint
	# leaves the v6 sets empty; the render must still succeed.
	local v4=/tmp/v4.env
	{
		grep -Ev '^NET_(DNS|HOST|ENDPOINT)_ADDRS=' /tests/config.test.env
		printf 'NET_DNS_ADDRS=10.0.0.53\nNET_HOST_ADDRS=203.0.113.10\nNET_ENDPOINT_ADDRS=10.10.0.4\n'
	} >"$v4"
	GHA_CONFIG=$v4 GHA_SYSTEMD_DIR=/tmp/v4 GHA_NFT_CONF=/tmp/v4/nftables.conf "$gha" render 2>/dev/null ||
		fail "render failed on a v4-only host (empty v6 sets)"
	grep -q 'set dns6 { type ipv6_addr; }' /tmp/v4/nftables.conf || fail "v4-only host did not render an empty dns6 set"
	grep -q 'set ep6 { type ipv6_addr . inet_service; }' /tmp/v4/nftables.conf || fail "v4-only host did not render an empty ep6 set"
	pass "render survives empty v6 sets"

	# Without pins the sets come from the host: this container has an
	# /etc/resolv.conf and no /run/systemd/resolve/resolv.conf, so discovery
	# must cope with a missing candidate file and with `ip` being absent.
	local disc=/tmp/disc.env
	grep -Ev '^NET_(DNS|HOST|ENDPOINT)_ADDRS=' /tests/config.test.env >"$disc"
	[[ ! -e /run/systemd/resolve/resolv.conf ]] || fail "test premise: the container has a systemd-resolved stub file"
	GHA_CONFIG=$disc GHA_SYSTEMD_DIR=/tmp/disc GHA_NFT_CONF=/tmp/disc/nftables.conf "$gha" render 2>/dev/null ||
		fail "render failed when discovering resolvers and addresses from the host"
	grep -q 'set dns4 { type ipv4_addr; elements = {' /tmp/disc/nftables.conf || fail "no resolver discovered from /etc/resolv.conf"
	pass "render discovers the resolvers from the host"

	# Endpoint hosts and ports are parsed out of the URLs: userinfo and the path
	# are stripped, bracketed IPv6 keeps its port, a scheme supplies the default
	# port, address literals resolve to themselves, and a guest-side proxy at
	# the gateway address is the host's loopback.
	local ep=/tmp/ep.env
	{
		grep -Ev '^NET_ENDPOINT_ADDRS=' /tests/config.test.env
		printf 'GITHUB_SERVER_URL=https://svc@[fd00::9]:8443/ghes\nHTTPS_PROXY=http://10.10.0.9:3128\nGUEST_HTTP_PROXY=http://10.0.2.2:3129\nRUNNER_DOWNLOAD_BASE=https://198.51.100.7/runner\n'
	} >"$ep"
	GHA_CONFIG=$ep GHA_SYSTEMD_DIR=/tmp/ep GHA_NFT_CONF=/tmp/ep/nftables.conf "$gha" render 2>/dev/null ||
		fail "render failed with literal endpoint addresses"
	local ep6_line ep4_line
	ep6_line="$(grep 'set ep6 {' /tmp/ep/nftables.conf)"
	ep4_line="$(grep 'set ep4 {' /tmp/ep/nftables.conf)"
	[[ "$ep6_line" == *'fd00::9 . 8443'* ]] || fail "bracketed IPv6 GHES host:port missing from ep6: $ep6_line"
	[[ "$ep4_line" == *'10.10.0.9 . 3128'* ]] || fail "proxy host:port missing from ep4: $ep4_line"
	[[ "$ep4_line" == *'127.0.0.1 . 3129'* ]] || fail "guest proxy at 10.0.2.2 was not mapped to loopback: $ep4_line"
	[[ "$ep4_line" == *'198.51.100.7 . 443'* ]] || fail "https scheme did not supply port 443: $ep4_line"
	[[ "$ep4_line" != *'10.10.0.9 . 443'* ]] || fail "proxy gained a port it was not given: $ep4_line"
	pass "endpoint hosts and ports parsed from URLs"

	# --- effective config -----------------------------------------------------
	[[ "$("$gha" config RUNNER_LABELS)" == "self-hosted,linux,x64,vm,ephemeral,docker" ]] || fail "x64 default labels wrong: $("$gha" config RUNNER_LABELS)"
	[[ "$("$gha" config GITHUB_API_URL)" == "https://api.github.com" ]] || fail "default API URL wrong"
	"$gha" config | grep -q '^GITHUB_PAT=$' || fail "config listing should show an empty GITHUB_PAT"
	pass "config prints effective values"

	local alt=/tmp/alt.env
	{
		cat /tests/config.test.env
		printf 'HOST_ARCH=aarch64\nGITHUB_SERVER_URL=https://ghe.example.com/\nGITHUB_PAT=secret\nRUNNER_LABELS=" a , b,,a "\n'
	} >"$alt"
	[[ "$(GHA_CONFIG=$alt "$gha" config QEMU_BIN)" == qemu-system-aarch64 ]] || fail "aarch64 did not select qemu-system-aarch64"
	[[ "$(GHA_CONFIG=$alt "$gha" config RUNNER_ARCH)" == arm64 ]] || fail "aarch64 did not map to runner arch arm64"
	[[ "$(GHA_CONFIG=$alt "$gha" config GITHUB_API_URL)" == "https://ghe.example.com/api/v3" ]] || fail "GHES API URL not derived from GITHUB_SERVER_URL"
	GHA_CONFIG=$alt "$gha" config | grep -q '^GITHUB_PAT=<set>$' || fail "config listing must mask the PAT"
	[[ "$(GHA_CONFIG=$alt "$gha" config GITHUB_PAT)" == secret ]] || fail "config KEY must print the raw value"
	pass "arch, GHES and PAT masking"

	printf 'SCOPE=org\nGITHUB_ORG=x\nAUTH_MODE=app\nRUNNER_VERSION=2.336.0\nGHA_UID=999\nAUTOTUNE=0\nVM_MEM=lots\n' >/tmp/bad.env
	if GHA_CONFIG=/tmp/bad.env GHA_SYSTEMD_DIR=/tmp/bad GHA_NFT_CONF=/tmp/bad/n.conf "$gha" render 2>/dev/null; then
		fail "render accepted VM_MEM=lots"
	fi
	pass "render refuses an invalid VM_MEM"
	printf 'SCOPE=org\nGITHUB_ORG=x\nAUTH_MODE=app\nRUNNER_VERSION=2.336.0\nGHA_UID=999\nAUTOTUNE=0\nVM_MEM=8\n' >/tmp/bare.env
	[[ "$(GHA_CONFIG=/tmp/bare.env "$gha" config VM_MEM)" == 8G ]] || fail "bare VM_MEM=8 was not normalized to 8G"
	printf 'SCOPE=org\nGITHUB_ORG=x\nAUTH_MODE=app\nRUNNER_VERSION=2.336.0\nGHA_UID=999\nAUTOTUNE=0\nRUNNER_GROUP_ID=default\n' >/tmp/rg.env
	if GHA_CONFIG=/tmp/rg.env GHA_SYSTEMD_DIR=/tmp/rg GHA_NFT_CONF=/tmp/rg/n.conf "$gha" render 2>/dev/null; then
		fail "render accepted a non-numeric RUNNER_GROUP_ID"
	fi
	pass "bare VM_MEM normalized; non-numeric RUNNER_GROUP_ID refused"

	# --- atomic config editor ------------------------------------------------
	local c=/tmp/edit.env
	printf '# header\n#RUNNER_SHA256=\nRUNNER_VERSION=2.330.0\nDUP=1\nDUP=2\n' >"$c"
	chown gha:gha "$c"
	chmod 0640 "$c"
	"$gha" config-set RUNNER_VERSION 2.336.0 "$c"
	[[ "$(grep -c '^RUNNER_VERSION=' "$c")" == 1 ]] || fail "config-set left more than one live RUNNER_VERSION"
	grep -qx 'RUNNER_VERSION=2.336.0' "$c" || fail "config-set did not replace the live key"
	"$gha" config-set RUNNER_SHA256 abc123 "$c"
	grep -qx 'RUNNER_SHA256=abc123' "$c" || fail "config-set did not fill the #KEY= placeholder"
	[[ "$(grep -c 'RUNNER_SHA256=' "$c")" == 1 ]] || fail "config-set left the placeholder next to the live key"
	"$gha" config-set DUP 3 "$c"
	[[ "$(grep -c '^DUP=' "$c")" == 1 ]] || fail "config-set left duplicate live keys"
	grep -qx 'DUP=3' "$c" || fail "config-set wrote the wrong DUP value"
	grep -qx '#DUP=' "$c" || fail "config-set did not comment out the duplicate live key"
	"$gha" config-set NOTE "two words" "$c"
	grep -qx "NOTE='two words'" "$c" || fail "config-set did not quote a value with spaces"
	"$gha" config-set NEWKEY v "$c"
	grep -qx 'NEWKEY=v' "$c" || fail "config-set did not append a new key"
	"$gha" config-set GITHUB_PAT - "$c" <<<"ghp_fromstdin"
	grep -qx 'GITHUB_PAT=ghp_fromstdin' "$c" || fail "config-set did not read the value from stdin"
	if "$gha" config-set GITHUB_PAT - "$c" </dev/null 2>/dev/null; then
		fail "config-set accepted an empty stdin value"
	fi
	"$gha" config-unset RUNNER_SHA256 "$c"
	grep -qx '#RUNNER_SHA256=' "$c" || fail "config-unset did not comment the key out"
	! grep -q '^RUNNER_SHA256=' "$c" || fail "config-unset left the key live"
	[[ "$(stat -c '%U:%G %a' "$c")" == "gha:gha 640" ]] || fail "config edits did not preserve owner/mode"
	head -n1 "$c" | grep -qx '# header' || fail "config edits disturbed unrelated lines"
	if "$gha" config-set 'bad key' v "$c" 2>/dev/null; then
		fail "config-set accepted an invalid key"
	fi
	pass "config-set/config-unset are atomic, quoted and idempotent"

	# --- usage ---------------------------------------------------------------
	local u
	u="$("$gha" no-such-command 2>&1)" && fail "unknown command must exit non-zero"
	grep -q 'drain|undrain' <<<"$u" || fail "usage text is not printed for an unknown command"
	pass "usage on unknown command"

	echo "ALL RENDER TESTS PASSED"
}

# ---------------------------------------------------------------- host side ----

if [[ "${1:-}" == --inside ]]; then
	inside "${2:-0}"
	exit 0
fi

UPDATE=0
[[ "${1:-}" == --update ]] && UPDATE=1

cd "$ROOT"
for f in gha-vm.sh setup.sh gha-job.sh tests/run.sh; do
	bash -n "$f" || fail "bash -n $f"
done
pass "bash -n"

if command -v shellcheck >/dev/null 2>&1; then
	# SC1091: /etc/os-release is sourced at runtime and is not on every dev box.
	shellcheck -x -e SC1091 gha-vm.sh setup.sh gha-job.sh tests/run.sh || fail "shellcheck"
	pass "shellcheck"
else
	echo "SHELLCHECK: N/A -- shellcheck not installed"
fi

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
	echo "RENDER TESTS: PARTIAL -- docker not available; only lint ran"
	exit 0
fi

mount_mode=ro
((UPDATE)) && mount_mode=rw
docker run --rm --cap-add NET_ADMIN \
	-v "$ROOT:/src:ro" -v "$HERE:/tests:$mount_mode" \
	"$IMAGE" bash /tests/run.sh --inside "$UPDATE"
