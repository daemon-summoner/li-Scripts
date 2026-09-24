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
	for f in gha-vm@.service ghavm.slice gha-vm@1.service.d/50-gha-vm-size.conf gha-vm-upgrade.service gha-vm-upgrade.timer nftables.conf; do
		[[ -s "$out/$f" ]] || fail "render produced no $f"
		if ((update)); then
			install -D -m 0644 "$out/$f" "/tests/expected/$f"
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
	cp -r "$out"/gha-vm@.service "$out"/ghavm.slice "$out"/gha-vm@1.service.d "$out"/gha-vm-upgrade.service "$out"/gha-vm-upgrade.timer "$v/"
	local verify_out
	verify_out="$(systemd-analyze verify --recursive-errors=no "$v/gha-vm@1.service" "$v/ghavm.slice" "$v/gha-vm-upgrade.service" "$v/gha-vm-upgrade.timer" 2>&1)" ||
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

	# --- fleet memory ----------------------------------------------------------
	grep -qx 'Slice=ghavm.slice' "$out/gha-vm@.service" || fail "slot unit does not run in ghavm.slice"
	grep -qx 'OOMPolicy=continue' "$out/gha-vm@.service" || fail "an OOM-killed VM would stop the slot unit"
	grep -qx 'MemoryHigh=24576M' "$out/ghavm.slice" || fail "slice MemoryHigh is not FLEET_MEM"
	grep -qx 'MemoryMax=26624M' "$out/ghavm.slice" || fail "slice MemoryMax is not FLEET_MEM plus the 2G minimum margin"
	grep -qx 'MemoryMax=18432M' "$out/gha-vm@1.service.d/50-gha-vm-size.conf" || fail "slot 1 drop-in is not VM_MEM_1+2048M"
	[[ ! -e "$out/gha-vm@2.service.d" ]] || fail "slot 2 has no override but got a drop-in"
	pass "fleet slice and per-slot drop-in carry the shared and per-slot limits"

	local fl=/tmp/fleet
	install -d "$fl"
	fleet_env() { # extra config lines on stdin
		{
			grep -Ev '^(FLEET_MEM|VM_MEM_1|RUNNER_LABELS_EXTRA_1)=' /tests/config.test.env
			cat
		} >"$fl/cfg.env"
	}
	fleet_env <<<'FLEET_MEM=off'
	GHA_CONFIG=$fl/cfg.env GHA_SYSTEMD_DIR=$fl/off GHA_NFT_CONF=$fl/off/n.conf "$gha" render 2>/dev/null ||
		fail "render failed with FLEET_MEM=off"
	grep -qx 'MemoryAccounting=yes' "$fl/off/ghavm.slice" || fail "FLEET_MEM=off lost the slice"
	! grep -q '^Memory\(High\|Max\)=' "$fl/off/ghavm.slice" || fail "FLEET_MEM=off still limits the slice"
	pass "FLEET_MEM=off renders a slice without limits"

	fleet_env <<<$'FLEET_MEM=24G\nVM_MEM_3=16'
	GHA_CONFIG=$fl/cfg.env GHA_SYSTEMD_DIR=$fl/stale GHA_NFT_CONF=$fl/stale/n.conf "$gha" render 2>/dev/null ||
		fail "render failed with a bare VM_MEM_3"
	grep -qx 'MemoryMax=18432M' "$fl/stale/gha-vm@3.service.d/50-gha-vm-size.conf" || fail "bare VM_MEM_3=16 was not read as 16G"
	[[ "$(GHA_CONFIG=$fl/cfg.env "$gha" config | grep '^VM_MEM_3=')" == VM_MEM_3=16 ]] || fail "config listing omits the per-slot key"
	touch "$fl/stale/gha-vm@3.service.d/90-operator.conf"
	fleet_env <<<'FLEET_MEM=24G'
	GHA_CONFIG=$fl/cfg.env GHA_SYSTEMD_DIR=$fl/stale GHA_NFT_CONF=$fl/stale/n.conf "$gha" render 2>/dev/null ||
		fail "re-render failed after dropping VM_MEM_3"
	[[ ! -e "$fl/stale/gha-vm@3.service.d/50-gha-vm-size.conf" ]] || fail "drop-in outlived the VM_MEM_3 it came from"
	[[ -e "$fl/stale/gha-vm@3.service.d/90-operator.conf" ]] || fail "re-render removed a drop-in it did not write"
	rm "$fl/stale/gha-vm@3.service.d/90-operator.conf"
	fleet_env <<<$'FLEET_MEM=24G\nVM_MEM_3=16G'
	GHA_CONFIG=$fl/cfg.env GHA_SYSTEMD_DIR=$fl/stale GHA_NFT_CONF=$fl/stale/n.conf "$gha" render 2>/dev/null
	fleet_env <<<'FLEET_MEM=24G'
	GHA_CONFIG=$fl/cfg.env GHA_SYSTEMD_DIR=$fl/stale GHA_NFT_CONF=$fl/stale/n.conf "$gha" render 2>/dev/null
	[[ ! -e "$fl/stale/gha-vm@3.service.d" ]] || fail "empty drop-in directory left behind"
	pass "per-slot drop-ins follow VM_MEM_<n>, sparing the operator's own"

	local bad
	for bad in 'FLEET_MEM=lots' 'FLEET_MEM=0G' 'VM_MEM_1=lots' 'VM_MEM_0=8G' 'VM_CPUS_2=0' 'MEM_OVERCOMMIT_PCT=0' 'HOST_ZRAM=2' 'HOST_ZRAM_SIZE="ram; x"'; do
		fleet_env <<<"$bad"
		if GHA_CONFIG=$fl/cfg.env GHA_SYSTEMD_DIR=$fl/bad GHA_NFT_CONF=$fl/bad/n.conf "$gha" render 2>/dev/null; then
			fail "render accepted $bad"
		fi
	done
	pass "invalid fleet and per-slot settings refused"

	# Slots count at their own sizes: 16G + 8G fills a 24G budget; at 200%
	# the pool is 48G, which holds 16G + 4 x 8G.
	local cap
	fleet_env <<<$'FLEET_MEM=24G\nVM_MEM_1=16G\nCPU_OVERCOMMIT=100\nDISK_PER_SLOT_GB=1'
	cap="$(GHA_CONFIG=$fl/cfg.env "$gha" capacity)"
	grep -q '^memory limit   2 slots' <<<"$cap" || fail "capacity did not count 16G + 8G into 24G: $cap"
	grep -q '^slot 1 ' <<<"$cap" || fail "capacity does not list the slot 1 override"
	fleet_env <<<$'FLEET_MEM=24G\nVM_MEM_1=16G\nMEM_OVERCOMMIT_PCT=200\nCPU_OVERCOMMIT=100\nDISK_PER_SLOT_GB=1'
	cap="$(GHA_CONFIG=$fl/cfg.env "$gha" capacity)"
	grep -q '^memory limit   5 slots' <<<"$cap" || fail "capacity did not fit 16G + 4 x 8G into 200% of 24G: $cap"
	grep -q '^recommended    [0-9]* slots' <<<"$cap" || fail "capacity lost the recommended line setup.sh parses"
	fleet_env <<<$'FLEET_MEM=12G\nVM_MEM_1=16G\nMEM_OVERCOMMIT_PCT=400'
	cap="$(GHA_CONFIG=$fl/cfg.env "$gha" capacity)"
	grep -q '^memory limit   0 slots' <<<"$cap" || fail "capacity counted a slot bigger than the budget: $cap"
	pass "capacity sums per-slot sizes against the overcommitted budget"

	# Fleet accounting from a fixture cgroup tree: page cache is not load,
	# swap is; a live earlier waiter goes first, a dead one does not; a VM
	# admitted moments ago still counts at its full size.
	local cg=$fl/cg run=$fl/run now
	now=$(date +%s)
	install -d "$cg/ghavm.slice/gha-vm@1.service" "$cg/ghavm.slice/gha-vm@2.service" "$run/gha-test-1-abcd" "$run/gha-test-2-ef01"
	printf 'GHA-VM: runner starting\n2026-01-01 00:00:00Z: Running job: build\n' >"$run/gha-test-1-abcd/console.log"
	printf 'GHA-VM: runner starting\n2026-01-01 00:00:00Z: Listening for Jobs\n' >"$run/gha-test-2-ef01/console.log"
	: >"$cg/cgroup.controllers"
	echo $((24576 * 1048576)) >"$cg/ghavm.slice/memory.high"
	echo $((6144 * 1048576)) >"$cg/ghavm.slice/gha-vm@1.service/memory.current"
	printf 'anon 1\nfile %s\nshmem %s\n' $((2048 * 1048576)) $((1024 * 1048576)) >"$cg/ghavm.slice/gha-vm@1.service/memory.stat"
	echo $((512 * 1048576)) >"$cg/ghavm.slice/gha-vm@1.service/memory.swap.current"
	echo $((3072 * 1048576)) >"$cg/ghavm.slice/gha-vm@2.service/memory.current"
	printf 'file 0\nshmem 0\n' >"$cg/ghavm.slice/gha-vm@2.service/memory.stat"
	local l
	for l in 1 2 3 5; do : >"$run/.slot-$l.lock"; done
	local holders=()
	for l in 1 2 3 5; do
		flock "$run/.slot-$l.lock" sleep 120 &
		holders+=($!)
	done
	sleep 1
	echo $((now - 30)) >"$run/.slot-4.wait"
	echo $((now - 20)) >"$run/.slot-3.wait"
	echo $((now - 10)) >"$run/.slot-5.wait"
	fleet_env <<<$'FLEET_MEM=24G\nVM_MEM_1=16G\nVM_MEM_2=16G\nRUN_DIR='"$run"
	local fo
	fo="$(GHA_CONFIG=$fl/cfg.env GHA_CGROUP_ROOT=$cg "$gha" fleet)" || fail "fleet exited non-zero"
	grep -q '^budget     24576M  (ghavm.slice MemoryHigh)' <<<"$fo" || fail "fleet budget not read from the slice: $fo"
	grep -q '^in use     8704M  (8192M resident + 512M swapped' <<<"$fo" || fail "fleet use should drop page cache, keep shmem and swap: $fo"
	grep -Eq '^1 +16384M +5632M +busy gha-test-1-abcd$' <<<"$fo" || fail "slot 1 has a job and should read busy: $fo"
	grep -Eq '^2 +16384M +3072M +idle gha-test-2-ef01$' <<<"$fo" || fail "slot 2 is registered with no job and should read idle: $fo"
	grep -Eq '^3 +8192M +0M +waiting 2[0-9]s$' <<<"$fo" || fail "slot 3 fits beside 8704M in use and should be clear to start: $fo"
	echo "$now 16384" >"$run/.slot-2.claim"
	fo="$(GHA_CONFIG=$fl/cfg.env GHA_CGROUP_ROOT=$cg "$gha" fleet)" || fail "fleet exited non-zero"
	grep -q '^claimed    13312M' <<<"$fo" || fail "slot 2 claim should count 16384M - 3072M in use: $fo"
	grep -Eq '^3 +8192M +0M +waiting 2[0-9]s: fleet holds 22016M of 24576M; this slot needs 8192M free$' <<<"$fo" ||
		fail "slot 3 should wait on memory, ahead of the dead slot 4 waiter: $fo"
	grep -Eq '^5 +8192M +0M +waiting 1[0-9]s: queued behind slot 3$' <<<"$fo" || fail "slot 5 should queue behind slot 3: $fo"
	echo "$((now - 600)) 16384" >"$run/.slot-2.claim"
	fo="$(GHA_CONFIG=$fl/cfg.env GHA_CGROUP_ROOT=$cg "$gha" fleet)" || fail "fleet exited non-zero"
	grep -Eq '^3 +8192M +0M +waiting 2[0-9]s$' <<<"$fo" || fail "an expired claim still blocks slot 3: $fo"
	fleet_env <<<'FLEET_MEM=off'
	fo="$(GHA_CONFIG=$fl/cfg.env GHA_CGROUP_ROOT=$cg "$gha" fleet)" || fail "fleet exited non-zero with FLEET_MEM=off"
	grep -q '^budget     off' <<<"$fo" || fail "FLEET_MEM=off not reported: $fo"
	kill "${holders[@]}"
	wait "${holders[@]}" || :
	pass "fleet accounting, claims and FIFO admission order"

	# restart: an idle runner is not a running job. Slots 2 (idle) and 3 (a
	# job's run dir left by a killed supervisor) restart at once, slot 1 once
	# its job finishes, and a failed restart of slot 4 is reported without
	# leaving any slot drained. Slot 5's supervisor is live with an idle VM
	# (a stand-in process in its unit's cgroup): restart stops that VM itself,
	# so a supervisor from an older script never waits out its grace period.
	local rs=$fl/restart rrun=$fl/restart/run
	install -d "$rs/bin" "$rrun/gha-test-1-aaaa" "$rrun/gha-test-2-bbbb" "$rrun/gha-test-3-cccc"
	printf 'GHA-VM: runner starting\n2026-01-01 00:00:00Z: Running job: build\n' >"$rrun/gha-test-1-aaaa/console.log"
	printf 'GHA-VM: runner starting\n2026-01-01 00:00:00Z: Running job: build\n' >"$rrun/gha-test-3-cccc/console.log"
	: >"$rrun/.slot-1.lock"
	flock "$rrun/.slot-1.lock" sleep 60 &
	local sup1=$!
	sleep 1
	printf 'GHA-VM: runner starting\n2026-01-01 00:00:00Z: Listening for Jobs\n' >"$rrun/gha-test-2-bbbb/console.log"
	install -d "$rrun/gha-test-5-eeee" "$rs/cg/u/gha-vm@5.service"
	cp "$rrun/gha-test-2-bbbb/console.log" "$rrun/gha-test-5-eeee/console.log"
	: >"$rrun/.slot-5.lock"
	flock "$rrun/.slot-5.lock" sleep 60 &
	local sup5=$!
	perl -e 'sleep 60' -- -name gha-test-5-eeee &
	local vm5=$!
	echo "$vm5" >"$rs/cg/u/gha-vm@5.service/cgroup.procs"
	cat >"$rs/bin/systemctl" <<SH
#!/bin/bash
case "\$1" in
list-units) printf 'gha-vm@%s.service loaded active running x\\n' 1 2 3 4 5 ;;
show) echo "/u/\$5" ;;
restart)
	echo "\$2" >>"$rs/log"
	[[ "\$2" != gha-vm@4.service ]]
	;;
esac
SH
	chmod +x "$rs/bin/systemctl"
	fleet_env <<<"RUN_DIR=$rrun"
	(sleep 3 && rm -rf "$rrun/gha-test-1-aaaa") &
	local finisher=$! rout rrc=0 t0
	t0=$(date +%s)
	rout="$(PATH="$rs/bin:$PATH" GHA_CONFIG=$fl/cfg.env GHA_CGROUP_ROOT=$rs/cg "$gha" restart all 2>&1)" || rrc=$?
	wait "$finisher"
	kill "$sup1" "$sup5"
	wait "$sup1" "$sup5" || :
	if kill -0 "$vm5" 2>/dev/null; then
		kill "$vm5"
		fail "restart left slot 5's idle VM running: $rout"
	fi
	wait "$vm5" || :
	grep -q 'slot 5: gha-test-5-eeee has no job; stopping it' <<<"$rout" || fail "restart did not stop slot 5's idle VM: $rout"
	((rrc != 0)) || fail "restart succeeded although slot 4 failed: $rout"
	grep -q 'slot 4: ERROR could not restart' <<<"$rout" || fail "restart did not report slot 4: $rout"
	[[ "$(sed -n 1,4p "$rs/log" | sort | tr '\n' ' ')" == "gha-vm@2.service gha-vm@3.service gha-vm@4.service gha-vm@5.service " ]] ||
		fail "idle slots did not restart ahead of the busy one: $(cat "$rs/log")"
	[[ "$(sed -n 5p "$rs/log")" == gha-vm@1.service ]] || fail "busy slot 1 not restarted after its job: $(cat "$rs/log")"
	grep -q 'slot 1: waiting for the current job to finish (0s)' <<<"$rout" || fail "restart did not wait on slot 1's job: $rout"
	! grep -q 'slot [235]: waiting' <<<"$rout" || fail "restart waited on an idle or dead slot: $rout"
	(($(date +%s) - t0 < 30)) || fail "restart took too long"
	! compgen -G "$rrun/.slot-*.drain" >/dev/null || fail "restart left drain flags behind: $(ls -a "$rrun")"
	pass "restart skips idle runners, waits for jobs, reports failures"

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
	grep -q '^GITHUB_PAT=$' <<<"$("$gha" config)" || fail "config listing should show an empty GITHUB_PAT"
	pass "config prints effective values"

	local alt=/tmp/alt.env
	{
		cat /tests/config.test.env
		printf 'HOST_ARCH=aarch64\nGITHUB_SERVER_URL=https://ghe.example.com/\nGITHUB_PAT=secret\nRUNNER_LABELS=" a , b,,a "\n'
	} >"$alt"
	[[ "$(GHA_CONFIG=$alt "$gha" config QEMU_BIN)" == qemu-system-aarch64 ]] || fail "aarch64 did not select qemu-system-aarch64"
	[[ "$(GHA_CONFIG=$alt "$gha" config RUNNER_ARCH)" == arm64 ]] || fail "aarch64 did not map to runner arch arm64"
	[[ "$(GHA_CONFIG=$alt "$gha" config GITHUB_API_URL)" == "https://ghe.example.com/api/v3" ]] || fail "GHES API URL not derived from GITHUB_SERVER_URL"
	grep -q '^GITHUB_PAT=<set>$' <<<"$(GHA_CONFIG=$alt "$gha" config)" || fail "config listing must mask the PAT"
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
