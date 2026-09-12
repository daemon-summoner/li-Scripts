#!/usr/bin/env bash
# Runs inside the guest, launched by cloud-init runcmd. Takes exactly one job,
# then powers the VM off. The disk is a throwaway qcow2 overlay that the host
# deletes immediately afterwards. Console output is the host's only view in,
# so every exit path says why on stdout.
set -uo pipefail

# The host watchdog greps the serial console for these. Changing one means
# changing the matching string in gha-vm.sh.
READY_MARKER='GHA-VM: runner starting'
SELFTEST_MARKER='GHA-VM: selftest ok'

say() { printf 'GHA-VM: %s\n' "$*"; }
fail() {
	printf 'GHA-VM: FATAL %s\n' "$*"
	exit 1
}

poweroff_now() {
	local rc=$?
	say "job finished rc=$rc, powering off"
	sync
	systemctl poweroff -i || poweroff -f
}
trap poweroff_now EXIT

# Per-boot knobs from the host's seed; absent on a self-test boot.
GHA_DOCKER_WAIT=60
if [[ -r /run/gha-env ]]; then
	# shellcheck disable=SC1091
	source /run/gha-env
fi
[[ "$GHA_DOCKER_WAIT" =~ ^[0-9]+$ ]] || GHA_DOCKER_WAIT=60

# Proxy baked in by the image build, if any: the runner and its job steps
# inherit it through the environment below.
if [[ -r /etc/gha-proxy.env ]]; then
	set -a
	# shellcheck disable=SC1091
	source /etc/gha-proxy.env
	set +a
fi

# Jobs that use containers need dockerd up before step 1, and a job that starts
# without it fails in a way that looks like a workflow bug rather than a host
# one -- so this is a hard gate, not a best-effort wait.
for _ in $(seq 1 "$GHA_DOCKER_WAIT"); do
	docker info >/dev/null 2>&1 && break
	sleep 1
done
docker info >/dev/null 2>&1 || fail "dockerd did not come up within ${GHA_DOCKER_WAIT}s"
say "docker ready"

cd /opt/actions-runner || fail "/opt/actions-runner missing from the golden image"

# Self-test boot (gha-vm.sh image): prove the image can start its runner
# binary, report, and power off. No JIT config exists on this boot.
if [[ -e /run/gha-selftest ]]; then
	[[ -x ./bin/Runner.Listener ]] || fail "selftest: bin/Runner.Listener missing"
	ver="$(runuser -u runner -- ./bin/Runner.Listener --version 2>&1)" ||
		fail "selftest: Runner.Listener --version failed: $ver"
	say "selftest: runner $ver"
	if [[ -x /usr/local/bin/gha-pre-job.sh ]]; then
		/usr/local/bin/gha-pre-job.sh || fail "selftest: pre-job hook exited $?"
		say "selftest: pre-job hook ok"
	fi
	printf '%s\n' "$SELFTEST_MARKER"
	exit 0
fi

[[ -r /run/gha-jit ]] || fail "no /run/gha-jit; cloud-init seed did not land"
jit="$(cat /run/gha-jit)"
rm -f /run/gha-jit
[[ -n "$jit" ]] || fail "/run/gha-jit was empty"

# Operator hook baked in from GUEST_PRE_JOB_HOOK. Runs as root before the
# runner starts; a failure here refuses the job rather than running it on a
# half-prepared guest.
if [[ -x /usr/local/bin/gha-pre-job.sh ]]; then
	/usr/local/bin/gha-pre-job.sh || fail "pre-job hook exited $?"
	say "pre-job hook ok"
fi

printf '%s\n' "$READY_MARKER"
runuser -u runner -- env HOME=/home/runner RUNNER_ALLOW_RUNASROOT=0 \
	./run.sh --jitconfig "$jit"
