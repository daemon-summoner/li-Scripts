#!/usr/bin/env bash
# Runs inside the guest, launched by cloud-init runcmd on every boot.
# Takes exactly one job, then powers the VM off. The disk is a throwaway
# qcow2 overlay that the host deletes immediately afterwards.
set -uo pipefail

poweroff_now() { sync; systemctl poweroff -i || poweroff -f; }
trap poweroff_now EXIT

[[ -r /run/gha-jit ]] || { echo "no /run/gha-jit; nothing to do" >&2; exit 1; }
jit="$(cat /run/gha-jit)"
rm -f /run/gha-jit

# Wait for docker; jobs that use containers will need it up before step 1.
for _ in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 1; done

cd /opt/actions-runner
runuser -u runner -- env HOME=/home/runner RUNNER_ALLOW_RUNASROOT=0 \
  ./run.sh --jitconfig "$jit"
