#!/usr/bin/env bash
# Runs inside the guest, launched by cloud-init runcmd. Takes exactly one job,
# then powers the VM off. The disk is a throwaway qcow2 overlay that the host
# deletes immediately afterwards. Console output is the host's only view in,
# so every exit path says why on stdout.
set -uo pipefail

# The host watchdog greps the serial console for this. Changing it means
# changing READY_MARKER in gha-vm.sh.
READY_MARKER='GHA-VM: runner starting'

say() { printf 'GHA-VM: %s\n' "$*"; }
fail() {
	printf 'GHA-VM: FATAL %s\n' "$*" >&2
	exit 1
}

poweroff_now() {
	local rc=$?
	say "job finished rc=$rc, powering off"
	sync
	systemctl poweroff -i || poweroff -f
}
trap poweroff_now EXIT

[[ -r /run/gha-jit ]] || fail "no /run/gha-jit; cloud-init seed did not land"
jit="$(cat /run/gha-jit)"
rm -f /run/gha-jit
[[ -n "$jit" ]] || fail "/run/gha-jit was empty"

# Jobs that use containers need dockerd up before step 1, and a job that starts
# without it fails in a way that looks like a workflow bug rather than a host
# one -- so this is a hard gate, not a best-effort wait.
for _ in $(seq 1 60); do
	docker info >/dev/null 2>&1 && break
	sleep 1
done
docker info >/dev/null 2>&1 || fail "dockerd did not come up within 60s"
say "docker ready"

cd /opt/actions-runner || fail "/opt/actions-runner missing from the golden image"

printf '%s\n' "$READY_MARKER"
runuser -u runner -- env HOME=/home/runner RUNNER_ALLOW_RUNASROOT=0 \
	./run.sh --jitconfig "$jit"
