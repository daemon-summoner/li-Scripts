#!/usr/bin/env bash
#
# gha-vm.sh - ephemeral GitHub Actions runners in throwaway KVM microVMs.
# Host: Ubuntu 26.04 LTS (Resolute Raccoon).
#
#   gha-vm.sh deps              install host packages
#   gha-vm.sh image             build the golden qcow2 (download + customize)
#   gha-vm.sh net               install nftables rules isolating VMs from the LAN
#   gha-vm.sh doctor            preflight checks
#   gha-vm.sh install <count>   systemd units for <count> concurrency slots
#   gha-vm.sh run <slot>        supervisor loop for one slot
#   gha-vm.sh reap | clean      cleanup
#
# Isolation model: the boundary is the VM, not a namespace. Inside the guest the
# runner can be root, use docker, run privileged containers, whatever. An escape
# from the job lands in a disk image we delete 5 seconds later.
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

log()  { printf '[%(%Y-%m-%dT%H:%M:%S%z)T] %s\n' -1 "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1 (try: $SELF deps)"; }

# ---------------------------------------------------------------- config ----

load_config() {
  [[ -r "$CONFIG" ]] || die "config not readable: $CONFIG"
  # shellcheck disable=SC1090
  source "$CONFIG"

  : "${SCOPE:?set SCOPE=org|repo}"
  : "${AUTH_MODE:?set AUTH_MODE=app|pat}"
  : "${RUNNER_VERSION:?}"

  UBUNTU_RELEASE="${UBUNTU_RELEASE:-26.04}"
  CLOUDIMG_BASE="${CLOUDIMG_BASE:-https://cloud-images.ubuntu.com/releases/${UBUNTU_RELEASE}/release}"
  CLOUDIMG_NAME="${CLOUDIMG_NAME:-ubuntu-${UBUNTU_RELEASE}-server-cloudimg-amd64.img}"

  STATE_DIR="${STATE_DIR:-/var/lib/gha-vm}"
  GOLDEN="${GOLDEN:-$STATE_DIR/golden.qcow2}"
  RUN_DIR="${RUN_DIR:-$STATE_DIR/run}"

  VM_CPUS="${VM_CPUS:-4}"
  VM_MEM="${VM_MEM:-8G}"
  VM_DISK="${VM_DISK:-80G}"
  MAX_LIFETIME="${MAX_LIFETIME:-21600}"

  RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,x64,vm,ephemeral,docker}"
  RUNNER_GROUP_ID="${RUNNER_GROUP_ID:-1}"
  NAME_PREFIX="${NAME_PREFIX:-gha-$(hostname -s)}"
  GHA_USER="${GHA_USER:-gha}"

  case "$SCOPE" in
    org)  : "${GITHUB_ORG:?set GITHUB_ORG when SCOPE=org}" ;;
    repo) : "${GITHUB_REPO:?set GITHUB_REPO=owner/name when SCOPE=repo}" ;;
    *)    die "SCOPE must be org or repo" ;;
  esac
}

# ------------------------------------------------------------------ auth ----
# Identical to the container variant: GitHub App preferred, PAT tolerated.

_b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

_app_jwt() {
  local now hdr pl unsigned sig
  now=$(date +%s)
  hdr=$(printf '{"alg":"RS256","typ":"JWT"}' | _b64url)
  pl=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now-60))" "$((now+540))" "$GITHUB_APP_ID" | _b64url)
  unsigned="${hdr}.${pl}"
  sig=$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$GITHUB_APP_KEY" -binary | _b64url)
  printf '%s.%s' "$unsigned" "$sig"
}

_TOKEN=""; _TOKEN_EXP=0

auth_token() {
  if [[ "$AUTH_MODE" == pat ]]; then : "${GITHUB_PAT:?}"; printf '%s' "$GITHUB_PAT"; return; fi

  local now; now=$(date +%s)
  if [[ -n "$_TOKEN" && $now -lt $((_TOKEN_EXP - 300)) ]]; then printf '%s' "$_TOKEN"; return; fi

  : "${GITHUB_APP_ID:?}" "${GITHUB_APP_KEY:?}"
  [[ -r "$GITHUB_APP_KEY" ]] || die "cannot read app key: $GITHUB_APP_KEY"

  local jwt inst_url inst_id resp
  jwt="$(_app_jwt)"
  if [[ "$SCOPE" == org ]]; then inst_url="$API/orgs/$GITHUB_ORG/installation"
  else inst_url="$API/repos/$GITHUB_REPO/installation"; fi

  inst_id=$(curl -fsS -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" \
                 -H "X-GitHub-Api-Version: $APIV" "$inst_url" | jq -r '.id')
  [[ -n "$inst_id" && "$inst_id" != null ]] || die "app not installed on that org/repo"

  resp=$(curl -fsS -X POST -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" \
              -H "X-GitHub-Api-Version: $APIV" -d '{"permissions":{"administration":"write"}}' \
              "$API/app/installations/$inst_id/access_tokens")
  _TOKEN=$(jq -r '.token' <<<"$resp")
  _TOKEN_EXP=$(date -d "$(jq -r '.expires_at' <<<"$resp")" +%s)
  [[ -n "$_TOKEN" && "$_TOKEN" != null ]] || die "failed to mint installation token"
  printf '%s' "$_TOKEN"
}

api() {
  local method="$1" path="$2" body="${3:-}" tok; tok="$(auth_token)"
  if [[ -n "$body" ]]; then
    curl -fsS -X "$method" -H "Authorization: Bearer $tok" -H "Accept: application/vnd.github+json" \
         -H "X-GitHub-Api-Version: $APIV" -d "$body" "$API$path"
  else
    curl -fsS -X "$method" -H "Authorization: Bearer $tok" -H "Accept: application/vnd.github+json" \
         -H "X-GitHub-Api-Version: $APIV" "$API$path"
  fi
}

runners_path() {
  if [[ "$SCOPE" == org ]]; then printf '/orgs/%s/actions/runners' "$GITHUB_ORG"
  else printf '/repos/%s/actions/runners' "$GITHUB_REPO"; fi
}

mint_jit() {
  local name="$1" body
  body=$(jq -nc --arg n "$name" --arg l "$RUNNER_LABELS" --argjson g "$RUNNER_GROUP_ID" \
    '{name:$n, runner_group_id:$g, labels:($l|split(",")), work_folder:"_work"}')
  api POST "$(runners_path)/generate-jitconfig" "$body" | jq -er '.encoded_jit_config'
}

# ------------------------------------------------------------------ deps ----

cmd_deps() {
  [[ $EUID -eq 0 ]] || die "deps must run as root"
  apt-get update
  apt-get install -y --no-install-recommends \
    qemu-system-x86 qemu-utils ovmf \
    cloud-image-utils libguestfs-tools \
    nftables curl jq openssl ca-certificates
  id -u "$GHA_USER" >/dev/null 2>&1 || useradd -r -m -d /var/lib/gha-vm -s /usr/sbin/nologin "$GHA_USER"
  usermod -aG kvm "$GHA_USER"
  install -d -o "$GHA_USER" -g "$GHA_USER" -m 0750 "$STATE_DIR" "$RUN_DIR"
  log "deps installed; $GHA_USER is in the kvm group"
}

# ----------------------------------------------------------------- image ----

ovmf_code() {
  local c
  for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
    [[ -r "$c" ]] && { printf '%s' "$c"; return; }
  done
  die "no OVMF firmware found (apt install ovmf)"
}
ovmf_vars() {
  local v
  for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do
    [[ -r "$v" ]] && { printf '%s' "$v"; return; }
  done
  die "no OVMF vars template found"
}

fetch_runner_sha() {
  local ver="$1"
  curl -fsS "$API/repos/actions/runner/releases/tags/v${ver}" | jq -r '.body' \
    | grep -iA2 "actions-runner-linux-x64-${ver}\.tar\.gz" \
    | grep -oiE '[0-9a-f]{64}' | head -n1 || true
}

cmd_image() {
  need qemu-img; need virt-customize; need curl; need jq
  [[ $EUID -eq 0 ]] || die "image must run as root"

  local work="$STATE_DIR/build" base="$work/$CLOUDIMG_NAME" rsha
  install -d -m 0750 "$work"

  if [[ ! -f "$base" ]]; then
    log "downloading $CLOUDIMG_NAME"
    curl -fSL --progress-bar -o "$base" "$CLOUDIMG_BASE/$CLOUDIMG_NAME"
    curl -fsSL -o "$work/SHA256SUMS" "$CLOUDIMG_BASE/SHA256SUMS"
    curl -fsSL -o "$work/SHA256SUMS.gpg" "$CLOUDIMG_BASE/SHA256SUMS.gpg" || true
    if [[ -s "$work/SHA256SUMS.gpg" && -r /usr/share/keyrings/ubuntu-cloudimage-keyring.gpg ]]; then
      gpgv --keyring /usr/share/keyrings/ubuntu-cloudimage-keyring.gpg \
           "$work/SHA256SUMS.gpg" "$work/SHA256SUMS" \
        || die "SHA256SUMS signature check failed"
      log "SHA256SUMS signature OK"
    else
      log "WARN: could not verify SHA256SUMS signature"
    fi
    ( cd "$work" && grep " [ *]\?${CLOUDIMG_NAME}\$" SHA256SUMS | sha256sum -c - ) \
      || die "cloud image checksum mismatch"
  fi

  rsha="${RUNNER_SHA256:-$(fetch_runner_sha "$RUNNER_VERSION")}"
  [[ -n "$rsha" ]] || log "WARN: could not resolve runner tarball SHA-256; installing unverified"

  local tmp="$work/golden.building.qcow2"
  rm -f "$tmp"
  cp --reflink=auto "$base" "$tmp"
  qemu-img resize "$tmp" "$VM_DISK"

  export LIBGUESTFS_BACKEND=direct

  virt-customize -a "$tmp" \
    --update \
    --install docker.io,git,jq,curl,unzip,zip,ca-certificates,build-essential,rsync,gnupg \
    --run-command 'apt-get purge -y snapd || true' \
    --run-command 'useradd -m -s /bin/bash -G docker runner' \
    --run-command "install -d -o runner -g runner /opt/actions-runner" \
    --run-command "cd /opt/actions-runner \
        && curl -fsSLo r.tgz https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz \
        && { [ -z '${rsha}' ] || echo '${rsha}  r.tgz' | sha256sum -c -; } \
        && tar xzf r.tgz && rm r.tgz && ./bin/installdependencies.sh \
        && mkdir -p _work && chown -R runner:runner /opt/actions-runner" \
    --write '/etc/cloud/cloud.cfg.d/99-nocloud.cfg:datasource_list: [ NoCloud, None ]' \
    --run-command 'systemctl disable --now unattended-upgrades apt-daily.timer apt-daily-upgrade.timer systemd-networkd-wait-online.service 2>/dev/null || true' \
    --upload "$HERE/gha-job.sh:/usr/local/bin/gha-job.sh" \
    --chmod '0755:/usr/local/bin/gha-job.sh' \
    --run-command 'systemctl enable docker' \
    --truncate /etc/machine-id \
    --delete /var/lib/dbus/machine-id

  mv -f "$tmp" "$GOLDEN"
  chown "$GHA_USER":"$GHA_USER" "$GOLDEN"
  chmod 0640 "$GOLDEN"
  log "golden image ready: $GOLDEN (runner $RUNNER_VERSION, ubuntu $UBUNTU_RELEASE)"
}

# ------------------------------------------------------------------- net ----

cmd_net() {
  [[ $EUID -eq 0 ]] || die "net must run as root"
  local uid; uid="$(id -u "$GHA_USER")"
  cat >/etc/nftables.d-gha.conf <<EOF
table inet gha
delete table inet gha
table inet gha {
  chain output {
    type filter hook output priority 0; policy accept;
    meta skuid $uid ip  daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } counter drop
    meta skuid $uid ip6 daddr { fc00::/7, fe80::/10 } counter drop
  }
}
EOF
  nft -f /etc/nftables.d-gha.conf
  grep -q 'nftables.d-gha.conf' /etc/nftables.conf 2>/dev/null \
    || echo 'include "/etc/nftables.d-gha.conf"' >>/etc/nftables.conf
  systemctl enable nftables >/dev/null 2>&1 || true
  log "VM egress to RFC1918 / link-local blocked for uid $uid"
  log "NOTE: this also blocks a LAN apt mirror or internal registry. Punch holes above the drop rules if you need one."
}

# ------------------------------------------------------------------- run ----

cmd_run() {
  need qemu-system-x86_64; need cloud-localds; need qemu-img
  local slot="${1:-1}" name dir jit rc started elapsed fails=0
  local code vars; code="$(ovmf_code)"; vars="$(ovmf_vars)"

  cleanup() { log "slot $slot: stopping"; [[ -n "${dir:-}" ]] && rm -rf "$dir"; exit 0; }
  trap cleanup INT TERM

  cmd_reap || true

  while :; do
    name="${NAME_PREFIX}-${slot}-$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')"
    dir="$RUN_DIR/$name"
    install -d -m 0700 "$dir"

    if ! jit="$(mint_jit "$name")"; then
      log "slot $slot: jit mint failed, retry in 30s"; rm -rf "$dir"; sleep 30; continue
    fi

    printf '#cloud-config\nhostname: %s\nusers: []\ndisable_root: true\nssh_pwauth: false\nwrite_files:\n  - path: /run/gha-jit\n    encoding: b64\n    permissions: "0600"\n    content: %s\nruncmd:\n  - [ /usr/local/bin/gha-job.sh ]\n' \
      "$name" "$(printf '%s' "$jit" | base64 -w0)" >"$dir/user-data"
    printf 'instance-id: %s\nlocal-hostname: %s\n' "$name" "$name" >"$dir/meta-data"
    cloud-localds "$dir/seed.img" "$dir/user-data" "$dir/meta-data"
    rm -f "$dir/user-data"
    jit=""

    qemu-img create -q -f qcow2 -F qcow2 -b "$GOLDEN" "$dir/disk.qcow2" >/dev/null
    cp "$vars" "$dir/vars.fd"

    started=$(date +%s)
    set +e
    timeout --signal=TERM --kill-after=60 "$MAX_LIFETIME" \
    qemu-system-x86_64 \
      -name "$name" \
      -machine q35,accel=kvm -cpu host \
      -smp "$VM_CPUS" -m "$VM_MEM" \
      -drive "if=pflash,format=raw,readonly=on,file=$code" \
      -drive "if=pflash,format=raw,file=$dir/vars.fd" \
      -drive "file=$dir/disk.qcow2,if=virtio,format=qcow2,cache=unsafe,discard=unmap" \
      -drive "file=$dir/seed.img,if=virtio,format=raw,readonly=on" \
      -netdev user,id=n0,ipv6=off -device virtio-net-pci,netdev=n0 \
      -device virtio-rng-pci \
      -display none -monitor none -serial stdio \
      -rtc base=utc
    rc=$?
    set -e

    elapsed=$(( $(date +%s) - started ))
    rm -rf "$dir"
    reap_one "$name" || true
    log "slot $slot: vm exited rc=$rc after ${elapsed}s"

    if (( elapsed < 30 )); then
      fails=$(( fails + 1 ))
      local backoff=$(( fails > 6 ? 60 : fails * 10 ))
      log "slot $slot: fast exit #$fails, backing off ${backoff}s"
      sleep "$backoff"
    else
      fails=0
    fi
  done
}

# ------------------------------------------------------------- reap/clean ----

reap_one() {
  local target="$1" id
  id=$(api GET "$(runners_path)?per_page=100" | jq -r --arg n "$target" \
       '.runners[] | select(.name==$n) | .id' | head -n1)
  [[ -n "$id" ]] && api DELETE "$(runners_path)/$id" >/dev/null
}

cmd_reap() {
  local ids
  ids=$(api GET "$(runners_path)?per_page=100" | jq -r --arg p "$NAME_PREFIX" \
        '.runners[] | select(.name|startswith($p)) | select(.status=="offline") | .id')
  for id in $ids; do log "reaping stale runner id=$id"; api DELETE "$(runners_path)/$id" >/dev/null || true; done
}

cmd_clean() { rm -rf "${RUN_DIR:?}"/*; cmd_reap; }

# ---------------------------------------------------------------- doctor ----

cmd_doctor() {
  local ok=0
  printf 'kvm: '
  if [[ -c /dev/kvm ]] && sudo -u "$GHA_USER" test -r /dev/kvm 2>/dev/null; then echo OK
  elif [[ -c /dev/kvm ]]; then echo "present but $GHA_USER cannot open it (add to kvm group)"; ok=1
  else echo "FAIL: no /dev/kvm (virtualization off in BIOS?)"; ok=1; fi

  printf 'tools: '
  local miss=()
  for t in qemu-system-x86_64 qemu-img cloud-localds virt-customize nft jq curl openssl; do
    command -v "$t" >/dev/null 2>&1 || miss+=("$t")
  done
  if ((${#miss[@]})); then echo "missing: ${miss[*]}"; ok=1; else echo OK; fi

  printf 'ovmf: '; if ovmf_code >/dev/null 2>&1; then echo "OK ($(ovmf_code))"; else echo FAIL; ok=1; fi
  printf 'golden image: '; if [[ -f "$GOLDEN" ]]; then echo "OK ($GOLDEN)"; else echo "missing (run: $SELF image)"; ok=1; fi

  printf 'runner version: %s ' "$RUNNER_VERSION"
  if [[ "$(printf '%s\n%s\n' "$MIN_RUNNER_VERSION" "$RUNNER_VERSION" | sort -V | head -1)" == "$MIN_RUNNER_VERSION" ]]
  then echo "OK (>= $MIN_RUNNER_VERSION)"; else echo "FAIL: below enforced minimum"; ok=1; fi

  printf 'auth: '; if auth_token >/dev/null 2>&1; then echo "OK ($AUTH_MODE)"; else echo FAIL; ok=1; fi
  printf 'runner admin access: '; if api GET "$(runners_path)" >/dev/null 2>&1; then echo OK; else echo "FAIL (need Administration: write)"; ok=1; fi

  printf 'public repo exposure: '
  if [[ "$SCOPE" == repo ]]; then
    if [[ "$(api GET "/repos/$GITHUB_REPO" | jq -r .private)" == false ]]; then
      echo "DANGER: $GITHUB_REPO is public; fork PRs execute arbitrary code here"; ok=1
    else echo OK; fi
  else
    if [[ "$(api GET "/orgs/$GITHUB_ORG/repos?type=public&per_page=1" | jq 'length')" -gt 0 ]]; then
      echo "DANGER: org has public repos; restrict the runner group to private repos"; ok=1
    else echo OK; fi
  fi

  printf 'lan isolation: '
  if nft list table inet gha >/dev/null 2>&1; then echo OK; else echo "not installed (run: $SELF net)"; fi

  return "$ok"
}

# --------------------------------------------------------------- install ----

cmd_install() {
  local count="${1:-2}" unit=/etc/systemd/system/gha-vm@.service
  [[ $EUID -eq 0 ]] || die "install must run as root"

  cat >"$unit" <<EOF
[Unit]
Description=Ephemeral GitHub Actions runner VM (slot %i)
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=simple
User=${GHA_USER}
Group=${GHA_USER}
SupplementaryGroups=kvm
Environment=GHA_CONFIG=${CONFIG}
ExecStart=${SELF} run %i
Restart=always
RestartSec=5
TimeoutStopSec=300
KillSignal=SIGTERM

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${STATE_DIR}
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=false
DeviceAllow=/dev/kvm rw

[Install]
WantedBy=multi-user.target
EOF

  chown -R "$GHA_USER":"$GHA_USER" "$STATE_DIR"
  systemctl daemon-reload
  for i in $(seq 1 "$count"); do systemctl enable --now "gha-vm@${i}.service"; done
  log "installed $count slots; logs: journalctl -fu 'gha-vm@*'"
}

# ------------------------------------------------------------------ main ----

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    deps)    load_config; cmd_deps ;;
    image)   load_config; cmd_image ;;
    net)     load_config; cmd_net ;;
    run)     load_config; cmd_run "$@" ;;
    reap)    load_config; cmd_reap ;;
    clean)   load_config; cmd_clean ;;
    doctor)  load_config; cmd_doctor ;;
    install) load_config; cmd_install "$@" ;;
    *) sed -n '2,20p' "$SELF"; exit 1 ;;
  esac
}

main "$@"
