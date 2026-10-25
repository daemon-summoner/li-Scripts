#!/usr/bin/env bash
# Detect the NVIDIA GPUs, then set each up as it needs: gpu-unlock for Ampere cards, the P2P-patched driver
# for identical pairs, and a power cap applied at every boot. Steps already done are skipped.
# Usage: ./unlock_gpu.sh [--targets ...] [--src DIR] [--power-limit W|MODEL=W,...] [--p2p auto|yes|no]
#        ./unlock_gpu.sh p2p-check|p2p-uninstall|p2p-host <vmid>   (see --help)
set -euo pipefail

REPO_URL=https://github.com/Zagitta/gpu-unlock
WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KVER="$(uname -r)"
TARGETS=all
TARGETS_GIVEN=0
SRC_DIR=""
# 5090s stay at their stock 575W; the entry pins it so a lowered limit does not survive a reboot.
POWER_LIMIT=3090=325,5090=575
POWER_UNIT=/etc/systemd/system/nvidia-power-limit.service
P2P=auto
REBOOT_NEEDED=0

P2P_VERSION=595.99.02
SRC_URL="https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/$P2P_VERSION.tar.gz"
SRC_SHA256=b8891cb617683e28ef1e4c3add8dbc30e648b8cd6429a3d521f20dde44633262
MODULES=(nvidia nvidia-modeset nvidia-drm nvidia-uvm nvidia-peermem)
INSTALL_SUBDIR=updates/nvidia-p2p
INSTALL_DIR="/lib/modules/$KVER/$INSTALL_SUBDIR"
DEPMOD_CONF=/etc/depmod.d/nvidia-p2p.conf
BUILD_DIR="$WORK_DIR/build"
PYTHON_CMD=python3
BACKUP_DIR=/root/enable_p2p-backups

SUDO=sudo
[[ $EUID -ne 0 ]] || SUDO=""

log() { echo "unlock_gpu: $*"; }
die() { echo "unlock_gpu: error: $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $0 [--targets all|<pci>[,<pci>...]] [--src DIR] [--power-limit W|MODEL=W[,MODEL=W...]] [--p2p auto|yes|no]
       $0 p2p-check [--python "CMD"]
       $0 p2p-uninstall
       $0 p2p-host <vmid> [--clique N] [--undo]

With no subcommand it sets up this machine for the NVIDIA GPUs it finds:
  gpu-unlock     Only when an Ampere card (GA102/GA103/GA104/GA106) is present.
  P2P driver     Only when two identical cards are present and the stock open driver
                 is $P2P_VERSION on Debian/Ubuntu, inside the VM (not the Proxmox host).
  power cap      Every card, through a systemd unit that runs before Docker at each boot.

  --targets      Cards to unlock, as gpu_unlock.targets takes them (default: all, which
                 covers only the Ampere cards). PCI addresses as 'lspci -D' prints them.
  --src          An existing gpu-unlock checkout to install from. Without it the repo
                 is cloned into $WORK_DIR/gpu-unlock when the module is missing.
  --power-limit  Watts for every card, or per model (default: $POWER_LIMIT); a model
                 matches any card whose name contains it. Cards no entry matches keep
                 their default limit.
  --p2p          auto (default) installs the P2P driver only when it applies, yes fails
                 when it cannot, no skips it.

  p2p-check      Show whether the cards can reach each other and verify a copy between
                 them. --python "CMD" runs the copy test with another Python that has
                 torch, e.g. --python "docker exec <container> python3".
  p2p-uninstall  Go back to the stock driver for the running kernel.
  p2p-host       On the Proxmox host, as root, with the VM stopped: give each NVIDIA GPU
                 of the VM its own hostpci entry and add x-nv-gpudirect-clique to it.
                 --clique N sets the clique ID (default 0). --undo restores the config
                 saved before the last change. Only needed if p2p-check fails in the VM.
EOF
}

# ---------------------------------------------------------------- detection

GPU_ADDRS=()
GPU_IDS=()
GPU_NAMES=()

detect_gpus() {
    local addr id name
    while read -r addr id name; do
        GPU_ADDRS+=("$addr")
        GPU_IDS+=("$id")
        GPU_NAMES+=("$name")
    done < <(lspci -D -nn -d 10de: \
        | sed -nE 's/^([^ ]+) .*\[030[02]\]: NVIDIA Corporation (.*) \[10de:([0-9a-f]{4})\].*$/\1 \3 \2/p')
    [[ ${#GPU_ADDRS[@]} -gt 0 ]] || die "lspci shows no NVIDIA GPU"
    log "found ${#GPU_ADDRS[@]} NVIDIA GPU(s):"
    local i
    for i in "${!GPU_ADDRS[@]}"; do
        echo "  ${GPU_ADDRS[i]}  ${GPU_NAMES[i]}"
    done
}

# gpu-unlock supports the consumer GA102/GA103/GA104/GA106 chips; pci.ids names the chip first.
has_ampere() {
    local name
    for name in "${GPU_NAMES[@]}"; do
        [[ $name =~ ^GA10[2346][[:space:]] ]] && return 0
    done
    return 1
}

# P2P only links cards of the same model, so it needs at least one PCI device ID twice.
has_identical_pair() {
    [[ -n "$(printf '%s\n' "${GPU_IDS[@]}" | sort | uniq -d)" ]]
}

# ---------------------------------------------------------------- gpu-unlock

module_installed() {
    modinfo -k "$KVER" gpu_unlock >/dev/null 2>&1 \
        && compgen -G "/usr/lib/firmware/gpu-unlock/*/gsp_ga10x.bin" >/dev/null
}

install_module() {
    if module_installed; then
        log "gpu_unlock module and firmware already installed for kernel $KVER"
        return
    fi
    if [[ -z $SRC_DIR ]]; then
        SRC_DIR="$WORK_DIR/gpu-unlock"
        if [[ ! -d $SRC_DIR/.git ]]; then
            log "cloning $REPO_URL into $SRC_DIR"
            git clone "$REPO_URL" "$SRC_DIR"
        fi
    fi
    [[ -f $SRC_DIR/Makefile ]] || die "$SRC_DIR is not a gpu-unlock checkout (no Makefile)"
    log "building and installing gpu-unlock from $SRC_DIR"
    make -C "$SRC_DIR" install
    module_installed || die "make install finished, but gpu_unlock or its firmware is still missing for kernel $KVER"
    REBOOT_NEEDED=1
}

bootloader() {
    if command -v grubby >/dev/null && [[ -f /etc/redhat-release ]]; then
        echo grubby
    elif [[ -f /etc/kernel/cmdline ]]; then
        echo kernel-cmdline
    elif [[ -f /etc/default/grub ]]; then
        echo grub
    else
        die "no supported boot config found (GRUB, grubby or /etc/kernel/cmdline); add $FLAG to your kernel command line by hand"
    fi
}

grub_files() {
    local files=(/etc/default/grub)
    shopt -s nullglob
    files+=(/etc/default/grub.d/*.cfg)
    shopt -u nullglob
    printf '%s\n' "${files[@]}"
}

# Prints the gpu_unlock.targets=... entry the boot config already carries, if any.
configured_flag() {
    case "$1" in
        grub)
            local f
            while read -r f; do
                grep -v '^[[:space:]]*#' "$f" || true
            done < <(grub_files) | grep -o 'gpu_unlock\.targets=[^"'"'"' ]*' | tail -n1 || true
            ;;
        grubby) sudo grubby --info=ALL | grep -o 'gpu_unlock\.targets=[^"'"'"' ]*' | sort -u | tail -n1 || true ;;
        kernel-cmdline) grep -o 'gpu_unlock\.targets=[^ ]*' /etc/kernel/cmdline | tail -n1 || true ;;
    esac
}

regenerate_grub() {
    if command -v update-grub >/dev/null; then
        sudo update-grub
    elif command -v grub-mkconfig >/dev/null; then
        sudo grub-mkconfig -o /boot/grub/grub.cfg
    elif command -v grub2-mkconfig >/dev/null; then
        sudo grub2-mkconfig -o /boot/grub2/grub.cfg
    else
        die "added $FLAG to the GRUB defaults, but found no update-grub or grub-mkconfig to regenerate grub.cfg"
    fi
}

add_flag() {
    local method="$1"
    case "$method" in
        grub)
            # Debian's update-grub reads /etc/default/grub.d; upstream grub-mkconfig only reads /etc/default/grub.
            if command -v update-grub >/dev/null && [[ -d /etc/default/grub.d ]]; then
                log "writing /etc/default/grub.d/99-gpu-unlock.cfg"
                echo "GRUB_CMDLINE_LINUX_DEFAULT=\"\$GRUB_CMDLINE_LINUX_DEFAULT $FLAG\"" \
                    | sudo tee /etc/default/grub.d/99-gpu-unlock.cfg >/dev/null
            elif grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
                log "appending $FLAG to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub"
                sudo sed -i -E "s/^(GRUB_CMDLINE_LINUX_DEFAULT=)([\"']?)(.*)\2[[:space:]]*\$/\1\"\3 $FLAG\"/" /etc/default/grub
            else
                log "adding GRUB_CMDLINE_LINUX_DEFAULT to /etc/default/grub"
                echo "GRUB_CMDLINE_LINUX_DEFAULT=\"$FLAG\"" | sudo tee -a /etc/default/grub >/dev/null
            fi
            [[ "$(configured_flag grub)" == "$FLAG" ]] || die "wrote the GRUB config, but $FLAG is not visible in it; check /etc/default/grub"
            regenerate_grub
            ;;
        grubby)
            log "adding $FLAG to every kernel with grubby"
            sudo grubby --update-kernel=ALL --args="$FLAG"
            ;;
        kernel-cmdline)
            log "appending $FLAG to /etc/kernel/cmdline"
            sudo sed -i "1s/[[:space:]]*\$/ $FLAG/" /etc/kernel/cmdline
            if command -v mkinitcpio >/dev/null; then
                sudo mkinitcpio -P
            else
                die "added $FLAG to /etc/kernel/cmdline, but only mkinitcpio regeneration is automated; rebuild your boot images yourself"
            fi
            ;;
    esac
    REBOOT_NEEDED=1
}

ensure_flag() {
    local method current
    method="$(bootloader)"
    current="$(configured_flag "$method")"
    if [[ -z $current ]]; then
        add_flag "$method"
    elif [[ $current == "$FLAG" ]]; then
        log "kernel command line already has $FLAG ($method)"
    elif [[ $TARGETS_GIVEN -eq 1 ]]; then
        die "boot config already has $current; remove it before setting $FLAG"
    else
        log "kernel command line already has $current ($method); leaving it as is"
        FLAG="$current"
    fi
}

report_unlock() {
    if ! grep -qw -- "$FLAG" /proc/cmdline; then
        REBOOT_NEEDED=1
        log "$FLAG is not on the running kernel's command line yet"
        return
    fi
    local kernel_log unlocked
    kernel_log="$(journalctl -k -b --no-pager)" || die "could not read the kernel log with journalctl"
    unlocked="$(grep -c 'gpu_unlock: unlocked' <<<"$kernel_log" || true)"
    log "this boot: $unlocked card(s) unlocked"
    # -114 (EALREADY) means the card was not cold: a VM restart without a host power cycle keeps the earlier unlock.
    grep -E 'gpu_unlock: (unlocked|.*(skip|refus|fail|error))' <<<"$kernel_log" \
        | grep -v 'module verification failed' \
        | sed -e 's/^/  /' -e 's/(-114)$/(-114: card not cold, still unlocked from an earlier boot)/' || true
}

# ---------------------------------------------------------------- P2P driver

# The kernel modules and the CUDA userspace must be the same driver release, so
# the packages that make up this release are held while the patched modules are in place.
driver_packages() {
    dpkg-query -W -f '${Package} ${Version}\n' | awk -v v="$P2P_VERSION" 'index($2, v) == 1 { print $1 }'
}

loaded_module_path() {
    modinfo -k "$KVER" -n "$1" 2>/dev/null || true
}

p2p_installed() {
    local m
    for m in "${MODULES[@]}"; do
        [[ "$(loaded_module_path "${m//-/_}")" == "$INSTALL_DIR/$m.ko" ]] || return 1
    done
}

guest_preflight() {
    [[ ! -d /etc/pve ]] || die "this looks like the Proxmox host; the driver steps run inside the VM"
    if ! command -v dpkg-query >/dev/null || ! command -v update-initramfs >/dev/null; then
        die "the P2P driver supports Debian/Ubuntu only (needs dpkg-query and update-initramfs)"
    fi
}

# Prints why the P2P driver cannot be installed here, or nothing when it can.
p2p_blocker() {
    if [[ -d /etc/pve ]]; then
        echo "this is the Proxmox host; run the setup inside the VM, and '$0 p2p-host <vmid>' here only if p2p-check fails"
    elif ! command -v dpkg-query >/dev/null || ! command -v update-initramfs >/dev/null; then
        echo "the P2P driver supports Debian/Ubuntu only (needs dpkg-query and update-initramfs)"
    elif ! has_identical_pair; then
        echo "no two identical NVIDIA cards, and P2P only links cards of the same model"
    elif [[ ! -d /lib/modules/$KVER/build ]]; then
        echo "kernel headers for $KVER are missing (install linux-headers-$KVER)"
    else
        local version license
        version="$(modinfo -k "$KVER" -F version nvidia 2>/dev/null || true)"
        license="$(modinfo -k "$KVER" -F license nvidia 2>/dev/null || true)"
        if [[ -z $version ]]; then
            echo "no nvidia module found for kernel $KVER; install the stock nvidia-driver-${P2P_VERSION%%.*}-open first"
        elif [[ $version != "$P2P_VERSION" ]]; then
            echo "installed driver is $version, but the P2P patch here is for $P2P_VERSION"
        elif [[ $license != "Dual MIT/GPL" ]]; then
            echo "installed driver is the proprietary flavour; the P2P patch needs the open kernel modules (nvidia-driver-${P2P_VERSION%%.*}-open)"
        fi
    fi
}

guest_install() {
    local userspace
    userspace="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1)" \
        || die "nvidia-smi failed; is the stock driver working?"
    [[ $userspace == "$P2P_VERSION" ]] \
        || die "CUDA userspace is $userspace, kernel module is $P2P_VERSION; reboot onto a consistent driver first"

    # The build tree is about a gigabyte and only needed until the modules are installed,
    # so it goes away on success and failure alike; a rerun downloads it again.
    local tarball="$BUILD_DIR/open-gpu-kernel-modules-$P2P_VERSION.tar.gz"
    local src="$BUILD_DIR/open-gpu-kernel-modules-$P2P_VERSION"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    trap 'rm -rf "$BUILD_DIR"' EXIT
    log "downloading $SRC_URL"
    curl -fL --retry 3 -o "$tarball" "$SRC_URL"
    sha256sum --status -c <<<"$SRC_SHA256  $tarball" || die "SHA-256 mismatch for $tarball"

    tar -xzf "$tarball" -C "$BUILD_DIR"
    log "applying the P2P patch for $P2P_VERSION"
    p2p_patch | patch -d "$src" -p1 --forward --no-backup-if-mismatch -s

    # Same flags Ubuntu's DKMS package builds this driver with.
    log "building kernel modules for $KVER (several minutes)"
    make -C "$src" -j"$(nproc)" modules \
        SYSSRC="/lib/modules/$KVER/build" IGNORE_XEN_PRESENCE=1 IGNORE_CC_MISMATCH=1 \
        LD=/usr/bin/ld.bfd CONFIG_X86_KERNEL_IBT=

    local m
    for m in "${MODULES[@]}"; do
        $SUDO install -D -m 0644 "$src/kernel-open/$m.ko" "$INSTALL_DIR/$m.ko"
    done

    # depmod would otherwise pick between these and the DKMS copies in updates/dkms by search order alone.
    local tmp
    tmp="$(mktemp)"
    { [[ -f $DEPMOD_CONF ]] && grep -v " $KVER $INSTALL_SUBDIR\$" "$DEPMOD_CONF" || true; } > "$tmp"
    for m in "${MODULES[@]}"; do
        echo "override ${m//-/_} $KVER $INSTALL_SUBDIR" >> "$tmp"
    done
    $SUDO install -m 0644 "$tmp" "$DEPMOD_CONF"
    rm -f "$tmp"
    $SUDO depmod -a "$KVER"
    p2p_installed || die "installed the modules, but depmod still resolves nvidia to $(loaded_module_path nvidia); check $DEPMOD_CONF"

    $SUDO update-initramfs -u -k "$KVER"

    local pkgs
    mapfile -t pkgs < <(driver_packages)
    [[ ${#pkgs[@]} -gt 0 ]] || die "found no installed packages at version $P2P_VERSION to hold"
    $SUDO apt-mark hold "${pkgs[@]}" >/dev/null
    log "held ${#pkgs[@]} driver packages at $P2P_VERSION so an upgrade cannot mismatch them with the patched modules"
    log "P2P driver installed. After the reboot, run: $0 p2p-check"
    REBOOT_NEEDED=1
}

ensure_p2p() {
    if [[ $P2P == no ]]; then
        log "P2P: skipped (--p2p no)"
        return
    fi
    if p2p_installed; then
        log "patched P2P driver already installed for kernel $KVER"
        guest_status
        return
    fi
    local why
    why="$(p2p_blocker)"
    if [[ -n $why ]]; then
        [[ $P2P == auto ]] || die "P2P: $why"
        log "P2P: skipped, $why"
        return
    fi
    guest_install
}

guest_uninstall() {
    guest_preflight
    local m
    for m in "${MODULES[@]}"; do
        $SUDO rm -f "$INSTALL_DIR/$m.ko"
    done
    [[ ! -d $INSTALL_DIR ]] || $SUDO rmdir "$INSTALL_DIR"
    if [[ -f $DEPMOD_CONF ]]; then
        local tmp
        tmp="$(mktemp)"
        grep -v " $KVER $INSTALL_SUBDIR\$" "$DEPMOD_CONF" > "$tmp" || true
        if [[ -s $tmp ]]; then
            $SUDO install -m 0644 "$tmp" "$DEPMOD_CONF"
        else
            $SUDO rm -f "$DEPMOD_CONF"
        fi
        rm -f "$tmp"
    fi
    $SUDO depmod -a "$KVER"
    $SUDO update-initramfs -u -k "$KVER"
    if [[ ! -f $DEPMOD_CONF ]]; then
        local pkgs
        mapfile -t pkgs < <(driver_packages)
        [[ ${#pkgs[@]} -eq 0 ]] || $SUDO apt-mark unhold "${pkgs[@]}" >/dev/null
        log "released the hold on the $P2P_VERSION driver packages"
    else
        log "other kernels still use the patched driver ($DEPMOD_CONF); driver packages stay held"
    fi
    log "stock driver restored for kernel $KVER. Reboot to load it."
}

guest_status() {
    local loaded=""
    [[ -r /sys/module/nvidia/version ]] && loaded="$(</sys/module/nvidia/version)"
    log "kernel $KVER resolves nvidia to: $(loaded_module_path nvidia)"
    log "loaded nvidia module version: ${loaded:-not loaded}"
}

# Copies a buffer between every pair of cards with peer access and compares it to the
# original: the PCIe fabric can drop peer writes silently instead of failing.
P2P_TEST_PY='
import itertools, torch
n = torch.cuda.device_count()
assert n >= 2, f"need 2 GPUs, found {n}"
pairs = []
for a, b in itertools.permutations(range(n), 2):
    ok = torch.cuda.can_device_access_peer(a, b)
    print(f"cuda:{a} ({torch.cuda.get_device_name(a)}) -> cuda:{b} peer access: {ok}")
    if ok and a < b:
        pairs.append((a, b))
assert pairs, "no pair of cards has peer access"
for a, b in pairs:
    src = torch.randint(0, 2**31 - 1, (64 * 1024 * 1024,), dtype=torch.int32, device=f"cuda:{a}")
    back = src.to(f"cuda:{b}").to(f"cuda:{a}")
    torch.cuda.synchronize(a); torch.cuda.synchronize(b)
    assert torch.equal(src, back), f"data changed crossing between cuda:{a} and cuda:{b}"
    x = torch.empty(256 * 1024 * 1024, dtype=torch.uint8, device=f"cuda:{a}")
    y = torch.empty_like(x, device=f"cuda:{b}")
    for _ in range(3):
        y.copy_(x)
    torch.cuda.synchronize(b)
    start, end = torch.cuda.Event(enable_timing=True), torch.cuda.Event(enable_timing=True)
    start.record(torch.cuda.current_stream(a))
    for _ in range(10):
        y.copy_(x)
    end.record(torch.cuda.current_stream(a))
    torch.cuda.synchronize(a); torch.cuda.synchronize(b)
    print(f"copy cuda:{a} -> cuda:{b}: {10 * x.numel() / (start.elapsed_time(end) / 1e3) / 1e9:.1f} GB/s, data verified")
'

guest_check() {
    guest_status
    local mode matrix status=0
    for mode in r w; do
        # Only the matrix, which ends at the first blank line; the legend below it also names NS.
        matrix="$(nvidia-smi topo -p2p "$mode" | sed '/^[[:space:]]*$/q' | sed '/^[[:space:]]*$/d')" \
            || die "nvidia-smi topo -p2p $mode failed"
        echo "$matrix"
        if grep -qE '(^|[[:space:]])(NS|CNS|TNS)([[:space:]]|$)' <<<"$matrix"; then
            # Cards of different models never peer, so NS between them is expected on a mixed box.
            log "P2P $mode: not supported between some cards"
            status=1
        fi
    done
    if [[ $status -ne 0 ]] && ! has_identical_pair; then
        log "P2P is off, and no two cards are the same model"
        return 1
    fi
    [[ $status -eq 0 ]] || log "some pairs show no P2P; identical cards should still peer, the copy test below checks them"
    log "running a copy test with: $PYTHON_CMD"
    # shellcheck disable=SC2086 # PYTHON_CMD may carry a prefix such as "docker exec <container>"
    $PYTHON_CMD -c "$P2P_TEST_PY" \
        || die "copy test failed. If the patched driver is loaded, try the host step: $0 p2p-host <vmid>"
}

host_main() {
    local vmid="" clique=0 undo=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --clique) [[ $# -ge 2 && $2 =~ ^[0-9]+$ && $2 -le 15 ]] || die "--clique needs a number from 0 to 15"; clique="$2"; shift 2 ;;
            --undo) undo=1; shift ;;
            -*) die "unknown p2p-host option: $1" ;;
            *) [[ -z $vmid ]] || die "only one VM ID"; vmid="$1"; shift ;;
        esac
    done
    [[ $vmid =~ ^[0-9]+$ ]] || die "p2p-host needs the VM ID, e.g. $0 p2p-host 101"
    if [[ ! -d /etc/pve ]] || ! command -v qm >/dev/null; then
        die "run p2p-host on the Proxmox host"
    fi
    [[ $EUID -eq 0 ]] || die "run p2p-host as root"

    local conf="/etc/pve/qemu-server/$vmid.conf"
    [[ -f $conf ]] || die "VM $vmid has no config at $conf (is it on another cluster node?)"
    [[ "$(qm status "$vmid")" == "status: stopped" ]] || die "stop VM $vmid first; hostpci changes only apply at a fresh start"

    if [[ $undo -eq 1 ]]; then
        local last
        last="$(find "$BACKUP_DIR" -maxdepth 1 -name "$vmid.conf.*" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2- || true)"
        [[ -n $last ]] || die "no saved config for VM $vmid in $BACKUP_DIR"
        cp "$last" "$conf"
        log "restored $conf from $last"
        return
    fi

    mkdir -p "$BACKUP_DIR"
    local backup
    backup="$BACKUP_DIR/$vmid.conf.$(date +%Y%m%d-%H%M%S)"
    cp "$conf" "$backup"

    local cfg machine
    cfg="$(qm config "$vmid" --current)"
    machine="$(awk -F': ' '$1 == "machine" { print $2 }' <<<"$cfg")"
    [[ $machine == *q35* ]] || die "VM $vmid uses machine '${machine:-i440fx}'; GPU P2P needs q35 with PCIe passthrough"

    local -A used=()
    local key val
    while IFS=': ' read -r key val; do
        [[ $key =~ ^hostpci[0-9]+$ ]] && used[$key]=1
    done <<<"$cfg"

    local -a set_args=() gpu_ids=()
    local args
    args="$(awk -F': ' '$1 == "args" { sub(/^args: /, ""); print }' <<<"$cfg")"

    local line idx addr opts func class
    while read -r line; do
        [[ $line =~ ^(hostpci[0-9]+):\ (.*)$ ]] || continue
        idx="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        addr="${val%%,*}"
        opts=""
        [[ $val == *,* ]] && opts=",${val#*,}"
        addr="${addr#host=}"
        [[ $addr != mapping=* ]] || die "$idx uses a resource mapping; give it a host PCI address for this script"
        [[ $addr != *\;* ]] || die "$idx passes several devices in one entry; split it first"
        [[ $addr == ????:* ]] || addr="0000:$addr"

        if [[ $addr =~ \.[0-7]$ ]]; then
            class="$(lspci -n -s "$addr" | awk '{ print $2 $3 }')"
            [[ $class =~ ^030[02]:10de: ]] || continue
        else
            # An entry without a function passes every function and QEMU names them
            # hostpciN.F; '-set device.<id>' cannot address an id containing a dot.
            local gpu_func=""
            local -a others=()
            while read -r func class; do
                if [[ $class =~ ^030[02]:10de: ]]; then
                    gpu_func="$func"
                else
                    others+=("$func")
                fi
            done < <(lspci -D -n -s "$addr" | awk '{ print $1, $2 $3 }')
            [[ -n $gpu_func ]] || continue
            log "$idx: splitting $addr into the GPU ($gpu_func) and its other functions"
            qm set "$vmid" "--$idx" "$gpu_func$opts" >/dev/null
            local other n pcie_opt=""
            [[ $opts == *pcie=1* ]] && pcie_opt=",pcie=1"
            for other in "${others[@]}"; do
                for n in $(seq 0 15); do [[ -z ${used[hostpci$n]:-} ]] && break; done
                [[ -z ${used[hostpci$n]:-} ]] || die "no free hostpci slot for $other"
                used[hostpci$n]=1
                qm set "$vmid" "--hostpci$n" "$other$pcie_opt" >/dev/null
                log "hostpci$n: $other"
            done
            addr="$gpu_func"
        fi
        gpu_ids+=("$idx")
        [[ $args == *"device.$idx.x-nv-gpudirect-clique="* ]] \
            || set_args+=("-set device.$idx.x-nv-gpudirect-clique=$clique")
    done <<<"$cfg"

    [[ ${#gpu_ids[@]} -ge 2 ]] || die "VM $vmid passes through ${#gpu_ids[@]} NVIDIA GPU(s); P2P needs at least 2; restore with $0 p2p-host $vmid --undo if anything was split"
    if [[ ${#set_args[@]} -eq 0 ]]; then
        rm -f "$backup"
        log "all GPUs (${gpu_ids[*]}) already carry x-nv-gpudirect-clique"
        return
    fi

    log "saved the previous config to $backup"
    qm set "$vmid" --args "${args:+$args }${set_args[*]}" >/dev/null

    local cmd id
    cmd="$(qm showcmd "$vmid")" || die "qm showcmd rejects the new config; restore it with $0 p2p-host $vmid --undo"
    for id in "${gpu_ids[@]}"; do
        grep -q -- "id=${id}[,' ]" <<<"$cmd" || die "QEMU command has no device with id=$id; restore with $0 p2p-host $vmid --undo"
    done
    log "GPUs ${gpu_ids[*]} get clique $clique. Start the VM, then inside it run: $0 p2p-check"
}

# ---------------------------------------------------------------- power cap

POWER_CMDS=()

# Prints the watts --power-limit gives a card with this name, or nothing when no entry matches.
watts_for() {
    local name="$1" entry
    if [[ $POWER_LIMIT =~ ^[1-9][0-9]*$ ]]; then
        echo "$POWER_LIMIT"
        return
    fi
    local -a entries
    IFS=, read -ra entries <<<"$POWER_LIMIT"
    for entry in "${entries[@]}"; do
        if [[ $name == *"${entry%=*}"* ]]; then
            echo "${entry##*=}"
            return
        fi
    done
}

# Each model has its own allowed range (a 5090 starts well above a 3090's 325W),
# so every card gets its own command, checked against that range now rather than at boot.
plan_power_limits() {
    local cards
    cards="$(nvidia-smi --query-gpu=pci.bus_id,name,power.min_limit,power.max_limit --format=csv,noheader,nounits)" || true
    local count
    count="$(grep -c . <<<"$cards" || true)"
    [[ $count -eq ${#GPU_ADDRS[@]} ]] \
        || die "nvidia-smi reaches $count of the ${#GPU_ADDRS[@]} cards lspci lists; a card off the bus needs a reboot before power caps can be set"

    local bus name min max watts
    while IFS=, read -r bus name min max; do
        name="${name# }"; min="${min# }"; max="${max# }"
        watts="$(watts_for "$name")"
        if [[ -z $watts ]]; then
            log "$bus $name: no --power-limit entry matches, keeping its default limit"
            continue
        fi
        awk -v w="$watts" -v lo="$min" -v hi="$max" 'BEGIN { exit !(w >= lo && w <= hi) }' \
            || die "$name ($bus) accepts ${min%.*}-${max%.*}W, not ${watts}W; set it per model, e.g. --power-limit \"3090=325,5090=450\""
        POWER_CMDS+=("$bus $watts")
    done <<<"$cards"
}

power_unit_text() {
    cat <<EOF
[Unit]
Description=Cap NVIDIA GPU power limits
After=nvidia-persistenced.service
Before=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/nvidia-smi -pm 1
EOF
    local entry
    for entry in "${POWER_CMDS[@]}"; do
        echo "ExecStart=/usr/bin/nvidia-smi -i ${entry% *} -pl ${entry#* }"
    done
    cat <<EOF
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

# The cap resets on every boot, so a unit reapplies it. Ordered before Docker so
# containers with a restart policy never start on uncapped cards.
ensure_power_limit() {
    plan_power_limits
    if [[ ${#POWER_CMDS[@]} -eq 0 ]]; then
        log "no card gets a power cap"
        return
    fi
    if [[ -f $POWER_UNIT ]] && diff -q <(power_unit_text) "$POWER_UNIT" >/dev/null; then
        log "power-limit unit already up to date"
    else
        log "writing $POWER_UNIT"
        power_unit_text | sudo tee "$POWER_UNIT" >/dev/null
        sudo systemctl daemon-reload
    fi
    systemctl is-enabled --quiet nvidia-power-limit.service || sudo systemctl enable nvidia-power-limit.service
    sudo systemctl restart nvidia-power-limit.service \
        || die "could not apply the power caps now (see: journalctl -u nvidia-power-limit); the unit is enabled and runs at next boot"
    log "power limits now:"
    nvidia-smi --query-gpu=index,name,power.limit --format=csv,noheader | sed 's/^/  GPU /'
}

# ---------------------------------------------------------------- main

setup_main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --targets) [[ $# -ge 2 ]] || die "--targets needs a value"; TARGETS="$2"; TARGETS_GIVEN=1; shift 2 ;;
            --src) [[ $# -ge 2 ]] || die "--src needs a directory"; SRC_DIR="$2"; shift 2 ;;
            --power-limit) [[ $# -ge 2 ]] || die "--power-limit needs a value in watts"; POWER_LIMIT="$2"; shift 2 ;;
            --p2p) [[ $# -ge 2 && $2 =~ ^(auto|yes|no)$ ]] || die "--p2p needs auto, yes or no"; P2P="$2"; shift 2 ;;
            *) usage >&2; die "unknown argument: $1" ;;
        esac
    done

    [[ $EUID -ne 0 ]] || die "run as your normal user: package builders such as makepkg refuse root, and sudo is used where needed"

    local pci_re='[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]'
    [[ $TARGETS == all || $TARGETS =~ ^$pci_re(,$pci_re)*$ ]] \
        || die "--targets must be 'all' or comma-separated PCI addresses like 0000:01:00.0, got '$TARGETS'"
    FLAG="gpu_unlock.targets=$TARGETS"
    local model_re='[^=,]+=[1-9][0-9]*'
    [[ $POWER_LIMIT =~ ^[1-9][0-9]*$ || $POWER_LIMIT =~ ^$model_re(,$model_re)*$ ]] \
        || die "--power-limit must be whole watts or MODEL=WATTS pairs like 3090=325,5090=450, got '$POWER_LIMIT'"

    detect_gpus
    if has_ampere; then
        install_module
        ensure_flag
    elif [[ $TARGETS_GIVEN -eq 1 ]]; then
        die "--targets given, but no Ampere card is present for gpu-unlock"
    else
        log "gpu-unlock: skipped, it only supports Ampere cards (GA102/GA103/GA104/GA106)"
    fi
    ensure_p2p
    ensure_power_limit
    if has_ampere; then
        report_unlock
    fi
    if [[ $REBOOT_NEEDED -eq 1 ]]; then
        log "reboot to apply"
    else
        log "nothing to do"
    fi
}

main() {
    case "${1:-}" in
        -h|--help) usage ;;
        p2p-check)
            shift
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --python) [[ $# -ge 2 ]] || die "--python needs a command"; PYTHON_CMD="$2"; shift 2 ;;
                    *) die "unknown p2p-check option: $1" ;;
                esac
            done
            detect_gpus
            guest_check
            ;;
        p2p-uninstall) shift; [[ $# -eq 0 ]] || die "p2p-uninstall takes no options"; guest_uninstall ;;
        p2p-host) shift; host_main "$@" ;;
        *) setup_main "$@" ;;
    esac
}

# P2P patch for NVIDIA's open kernel modules at P2P_VERSION (tinygrad/aikitoria lineage): forces BAR1 P2P on GeForce cards.
p2p_patch() {
    cat <<'__P2P_PATCH__'
diff -ruN a/kernel-open/common/inc/nv.h b/kernel-open/common/inc/nv.h
--- a/kernel-open/common/inc/nv.h
+++ b/kernel-open/common/inc/nv.h
@@ -963,6 +963,8 @@
 
 NV_STATUS  NV_API_CALL  nv_register_user_pages   (nv_state_t *, NvU64, NvU64 *, void *, void **, NvBool);
 void       NV_API_CALL  nv_unregister_user_pages (nv_state_t *, NvU64, void **, void **);
+NvU32      NV_API_CALL  nv_get_compound_order    (void *);
+NvU32      NV_API_CALL  nv_get_page_array_compound_order(void *);
 
 NV_STATUS NV_API_CALL   nv_register_peer_io_mem  (nv_state_t *, NvU64 *, NvU64, void **);
 void      NV_API_CALL   nv_unregister_peer_io_mem(nv_state_t *, void *);
diff -ruN a/kernel-open/common/inc/nv-linux.h b/kernel-open/common/inc/nv-linux.h
--- a/kernel-open/common/inc/nv-linux.h
+++ b/kernel-open/common/inc/nv-linux.h
@@ -943,6 +943,7 @@
     unsigned int   cache_type;
     unsigned int   num_pages;
     unsigned int   order;
+    unsigned int   compound_order;      /* 0 = normal 4K pages, >0 = hugepage compound order */
     unsigned int   size;
     nvidia_pte_t  *page_table;          /* array of physical pages allocated */
     unsigned int   pid;
@@ -1076,6 +1077,7 @@
     NvBool contiguous;
     NvU32 cache_type;
     NvBool bReadOnlyDeviceMap;
+    NvU64 page_granularity;             /* PAGE_SIZE for normal, hugepage_size for compound pages */
     struct sg_table *import_sgt;
 
     union
diff -ruN a/kernel-open/nvidia/nv.c b/kernel-open/nvidia/nv.c
--- a/kernel-open/nvidia/nv.c
+++ b/kernel-open/nvidia/nv.c
@@ -3474,12 +3474,22 @@
     NvU64 i;
     struct page **user_pages;
     nv_linux_state_t *nvl;
+    NvU32 compound_order;
+    NvU64 effective_count;
 
     nv_printf(NV_DBG_MEMINFO, "NVRM: VM: nv_register_user_pages: 0x%" NvU64_fmtx"\n", page_count);
     user_pages = *priv_data;
     nvl = NV_GET_NVL_FROM_NV_STATE(nv);
 
-    at = nvos_create_alloc(nvl->dev, page_count);
+    /* Read compound_order from os_lock_user_pages() hidden header. */
+    compound_order = nv_get_page_array_compound_order(user_pages);
+
+    if (compound_order > 0)
+        effective_count = page_count >> compound_order;
+    else
+        effective_count = page_count;
+
+    at = nvos_create_alloc(nvl->dev, effective_count);
 
     if (at == NULL)
     {
@@ -3500,9 +3510,10 @@
     if (unencrypted)
         at->flags.unencrypted = NV_TRUE;
 
+    at->compound_order = compound_order;
     at->order = get_order(at->num_pages * PAGE_SIZE);
 
-    for (i = 0; i < page_count; i++)
+    for (i = 0; i < effective_count; i++)
     {
         /*
          * We only assign the physical address and not the DMA address, since
@@ -3527,6 +3538,29 @@
     return NV_OK;
 }
 
+NvU32 NV_API_CALL nv_get_compound_order(
+    void *priv_data
+)
+{
+    nv_alloc_t *at = priv_data;
+    return at->compound_order;
+}
+
+/*
+ * Read compound_order from the hidden header prepended to a page array
+ * by os_lock_user_pages().
+ *
+ * Layout: [num_entries:NvU64][compound_order:NvU64][struct page * array...]
+ *                                                   ^ page_array points here
+ */
+NvU32 NV_API_CALL nv_get_page_array_compound_order(
+    void *page_array
+)
+{
+    NvU64 *header = (NvU64 *)((NvU8 *)page_array - 2 * sizeof(NvU64));
+    return (NvU32)header[1];
+}
+
 void NV_API_CALL nv_unregister_user_pages(
     nv_state_t *nv,
     NvU64       page_count,
diff -ruN a/kernel-open/nvidia/nv-dma.c b/kernel-open/nvidia/nv-dma.c
--- a/kernel-open/nvidia/nv-dma.c
+++ b/kernel-open/nvidia/nv-dma.c
@@ -81,9 +81,10 @@
 )
 {
     enum dma_data_direction direction = nv_dma_get_direction(dma_map);
+    NvU64 mapping_size = dma_map->page_count * dma_map->page_granularity;
 
     *va = dma_map_page_attrs(dma_map->dev, dma_map->pages[0], 0,
-                             dma_map->page_count * PAGE_SIZE,
+                             mapping_size,
                              direction,
                              (dma_map->cache_type == NV_MEMORY_UNCACHED) ?
                               DMA_ATTR_SKIP_CPU_SYNC : 0);
@@ -94,12 +95,12 @@
 
     dma_map->mapping.contig.dma_addr = *va;
 
-    if (!nv_dma_is_addressable(dma_dev, *va, dma_map->page_count * PAGE_SIZE))
+    if (!nv_dma_is_addressable(dma_dev, *va, mapping_size))
     {
         NV_DMA_DEV_PRINTF(NV_DBG_ERRORS, dma_dev,
                 "DMA address not in addressable range of device "
                 "(0x%llx-0x%llx, 0x%llx-0x%llx)\n",
-                *va, *va + (dma_map->page_count * PAGE_SIZE - 1),
+                *va, *va + (mapping_size - 1),
                 dma_dev->addressable_range.start,
                 dma_dev->addressable_range.limit);
         nv_dma_unmap_contig(dma_map);
@@ -112,9 +113,10 @@
 static void nv_dma_unmap_contig(nv_dma_map_t *dma_map)
 {
     enum dma_data_direction direction = nv_dma_get_direction(dma_map);
+    NvU64 mapping_size = dma_map->page_count * dma_map->page_granularity;
 
     dma_unmap_page_attrs(dma_map->dev, dma_map->mapping.contig.dma_addr,
-                         dma_map->page_count * PAGE_SIZE,
+                         mapping_size,
                          direction,
                          (dma_map->cache_type == NV_MEMORY_UNCACHED) ?
                           DMA_ATTR_SKIP_CPU_SYNC : 0);
@@ -147,85 +149,128 @@
 
 NV_STATUS nv_create_dma_map_scatterlist(nv_dma_map_t *dma_map)
 {
-    /*
-     * We need to split our mapping into at most 4GB - PAGE_SIZE chunks.
-     * The Linux kernel stores the length (and offset) of a scatter-gather
-     * segment as an unsigned int, so it will overflow if we try to do
-     * anything larger.
-     */
     NV_STATUS status;
     nv_dma_submap_t *submap;
     NvU32 i;
-    NvU64 allocated_size = 0;
-    NvU64 num_submaps = dma_map->page_count + NV_DMA_SUBMAP_MAX_PAGES - 1;
-    NvU64 total_size = dma_map->page_count << PAGE_SHIFT;
 
     /*
-     * This turns into 64-bit division, which the ARMv7 kernel doesn't provide
-     * implicitly. Instead, we need to use the platform's do_div() to perform
-     * the division.
+     * Hugepage fast path: when page_granularity > PAGE_SIZE, each page array
+     * entry covers one hugepage. Create a single submap with manually
+     * constructed SG entries instead of using sg_alloc_table_from_pages which
+     * operates at PAGE_SIZE granularity.
      */
-    do_div(num_submaps, NV_DMA_SUBMAP_MAX_PAGES);
+    if (dma_map->page_granularity > PAGE_SIZE)
+    {
+        int ret;
 
-    WARN_ON(NvU64_HI32(num_submaps) != 0);
+        dma_map->mapping.discontig.submap_count = 1;
 
-    if (dma_map->import_sgt && (num_submaps != 1))
-    {
-        return -EINVAL;
-    }
+        status = os_alloc_mem((void **)&dma_map->mapping.discontig.submaps,
+            sizeof(nv_dma_submap_t));
+        if (status != NV_OK)
+            return status;
 
-    dma_map->mapping.discontig.submap_count = NvU64_LO32(num_submaps);
+        os_mem_set(dma_map->mapping.discontig.submaps, 0, sizeof(nv_dma_submap_t));
 
-    status = os_alloc_mem((void **)&dma_map->mapping.discontig.submaps,
-        sizeof(nv_dma_submap_t) * dma_map->mapping.discontig.submap_count);
-    if (status != NV_OK)
-    {
-        return status;
-    }
+        submap = &dma_map->mapping.discontig.submaps[0];
+        submap->page_count = dma_map->page_count;
 
-    os_mem_set((void *)dma_map->mapping.discontig.submaps, 0,
-        sizeof(nv_dma_submap_t) * dma_map->mapping.discontig.submap_count);
+        ret = sg_alloc_table(&submap->sgt, submap->page_count, NV_GFP_KERNEL);
+        if (ret != 0)
+        {
+            os_free_mem(dma_map->mapping.discontig.submaps);
+            return NV_ERR_OPERATING_SYSTEM;
+        }
 
-    /* If we have an imported SGT, just use that directly. */
-    if (dma_map->import_sgt)
-    {
-        dma_map->mapping.discontig.submaps[0].page_count = dma_map->page_count;
-        dma_map->mapping.discontig.submaps[0].sgt = *dma_map->import_sgt;
-        dma_map->mapping.discontig.submaps[0].imported = NV_TRUE;
+        {
+            struct scatterlist *sg;
+            unsigned int j;
 
-        return status;
+            for_each_sg(submap->sgt.sgl, sg, submap->page_count, j)
+                sg_set_page(sg, dma_map->pages[j], dma_map->page_granularity, 0);
+        }
+
+        return NV_OK;
     }
 
-    NV_FOR_EACH_DMA_SUBMAP(dma_map, submap, i)
+    /*
+     * Normal path: split into at most 4GB - PAGE_SIZE chunks.
+     * The Linux kernel stores the length (and offset) of a scatter-gather
+     * segment as an unsigned int, so it will overflow if we try to do
+     * anything larger.
+     */
     {
-        NvU64 submap_size = NV_MIN(NV_DMA_SUBMAP_MAX_PAGES << PAGE_SHIFT,
-                                   total_size - allocated_size);
+        NvU64 allocated_size = 0;
+        NvU64 num_submaps = dma_map->page_count + NV_DMA_SUBMAP_MAX_PAGES - 1;
+        NvU64 total_size = dma_map->page_count << PAGE_SHIFT;
 
-        submap->page_count = (NvU32)(submap_size >> PAGE_SHIFT);
+        /*
+         * This turns into 64-bit division, which the ARMv7 kernel doesn't provide
+         * implicitly. Instead, we need to use the platform's do_div() to perform
+         * the division.
+         */
+        do_div(num_submaps, NV_DMA_SUBMAP_MAX_PAGES);
 
-        status = NV_ALLOC_DMA_SUBMAP_SCATTERLIST(dma_map, submap, i);
+        WARN_ON(NvU64_HI32(num_submaps) != 0);
+
+        if (dma_map->import_sgt && (num_submaps != 1))
+        {
+            return -EINVAL;
+        }
+
+        dma_map->mapping.discontig.submap_count = NvU64_LO32(num_submaps);
+
+        status = os_alloc_mem((void **)&dma_map->mapping.discontig.submaps,
+            sizeof(nv_dma_submap_t) * dma_map->mapping.discontig.submap_count);
         if (status != NV_OK)
         {
-            submap->page_count = 0;
-            break;
+            return status;
         }
 
-#if defined(NV_DOM0_KERNEL_PRESENT)
+        os_mem_set((void *)dma_map->mapping.discontig.submaps, 0,
+            sizeof(nv_dma_submap_t) * dma_map->mapping.discontig.submap_count);
+
+        /* If we have an imported SGT, just use that directly. */
+        if (dma_map->import_sgt)
         {
-            NvU64 page_idx = NV_DMA_SUBMAP_IDX_TO_PAGE_IDX(i);
-            nv_fill_scatterlist(submap->sgt.sgl,
-                &dma_map->pages[page_idx], submap->page_count);
+            dma_map->mapping.discontig.submaps[0].page_count = dma_map->page_count;
+            dma_map->mapping.discontig.submaps[0].sgt = *dma_map->import_sgt;
+            dma_map->mapping.discontig.submaps[0].imported = NV_TRUE;
+
+            return status;
         }
+
+        NV_FOR_EACH_DMA_SUBMAP(dma_map, submap, i)
+        {
+            NvU64 submap_size = NV_MIN(NV_DMA_SUBMAP_MAX_PAGES << PAGE_SHIFT,
+                                       total_size - allocated_size);
+
+            submap->page_count = (NvU32)(submap_size >> PAGE_SHIFT);
+
+            status = NV_ALLOC_DMA_SUBMAP_SCATTERLIST(dma_map, submap, i);
+            if (status != NV_OK)
+            {
+                submap->page_count = 0;
+                break;
+            }
+
+#if defined(NV_DOM0_KERNEL_PRESENT)
+            {
+                NvU64 page_idx = NV_DMA_SUBMAP_IDX_TO_PAGE_IDX(i);
+                nv_fill_scatterlist(submap->sgt.sgl,
+                    &dma_map->pages[page_idx], submap->page_count);
+            }
 #endif
 
-        allocated_size += submap_size;
-    }
+            allocated_size += submap_size;
+        }
 
-    WARN_ON(allocated_size != total_size);
+        WARN_ON(allocated_size != total_size);
 
-    if (status != NV_OK)
-    {
-        nv_destroy_dma_map_scatterlist(dma_map);
+        if (status != NV_OK)
+        {
+            nv_destroy_dma_map_scatterlist(dma_map);
+        }
     }
 
     return status;
@@ -313,12 +358,29 @@
     unsigned int i, j;
     struct scatterlist *sg;
     nv_dma_submap_t *submap;
-    NvU64 sg_addr, sg_off, sg_len, k, l = 0;
+    NvU64 l = 0;
+
+    /*
+     * Hugepage fast path: one va_array entry per SG entry (one per hugepage).
+     * No need to split SG entries into PAGE_SIZE chunks.
+     */
+    if (dma_map->page_granularity > PAGE_SIZE)
+    {
+        NV_FOR_EACH_DMA_SUBMAP(dma_map, submap, i)
+        {
+            for_each_sg(submap->sgt.sgl, sg, submap->sg_map_count, j)
+                va_array[l++] = sg_dma_address(sg);
+        }
+        return;
+    }
 
+    /* Normal path */
     NV_FOR_EACH_DMA_SUBMAP(dma_map, submap, i)
     {
         for_each_sg(submap->sgt.sgl, sg, submap->sg_map_count, j)
         {
+            NvU64 sg_addr, sg_off, sg_len, k;
+
             /*
              * It is possible for pci_map_sg() to merge scatterlist entries, so
              * make sure we account for that here.
@@ -364,7 +426,7 @@
 
     for (i = 0; i < dma_map->page_count; i++)
     {
-        if (!nv_dma_is_addressable(dma_dev, va_array[i], PAGE_SIZE))
+        if (!nv_dma_is_addressable(dma_dev, va_array[i], dma_map->page_granularity))
         {
             NV_DMA_DEV_PRINTF(NV_DBG_ERRORS, dma_dev,
                     "DMA address not in addressable range of device "
@@ -424,6 +486,7 @@
     dma_map->contiguous = NV_FALSE;
     dma_map->cache_type = cache_type;
     dma_map->bReadOnlyDeviceMap = bReadOnlyDeviceMap;
+    dma_map->page_granularity = PAGE_SIZE;
 
     dma_map->mapping.discontig.submap_count = 0;
     status = nv_dma_map_scatterlist(dma_dev, dma_map, va_array);
@@ -470,6 +533,7 @@
     NvBool           contig,
     NvU32            cache_type,
     NvBool           bReadOnlyDeviceMap,
+    NvU64            page_granularity,
     void           **priv
 )
 {
@@ -507,6 +571,7 @@
     dma_map->contiguous = contig;
     dma_map->cache_type = cache_type;
     dma_map->bReadOnlyDeviceMap = bReadOnlyDeviceMap;
+    dma_map->page_granularity = page_granularity;
 
     if (dma_map->page_count > 1 && !dma_map->contiguous)
     {
@@ -671,8 +736,17 @@
     }
 
     *priv = pages;
-    status = nv_dma_map_pages(dma_dev, page_count, va_array, contig, cache_type,
-                              bReadOnlyDeviceMap, priv);
+
+    {
+        NvU64 page_granularity = PAGE_SIZE;
+
+        if (at != NULL && at->compound_order > 0)
+            page_granularity = (NvU64)PAGE_SIZE << at->compound_order;
+
+        status = nv_dma_map_pages(dma_dev, page_count, va_array, contig,
+                                  cache_type, bReadOnlyDeviceMap,
+                                  page_granularity, priv);
+    }
     if (status != NV_OK)
     {
         *priv = at;
@@ -898,7 +972,7 @@
     {
         dma_sync_single_for_device(dma_dev->dev,
                                    dma_map->mapping.contig.dma_addr,
-                                   (size_t) PAGE_SIZE * dma_map->page_count,
+                                   (size_t) dma_map->page_granularity * dma_map->page_count,
                                    DMA_FROM_DEVICE);
     }
     else
diff -ruN a/kernel-open/nvidia/nv-reg.h b/kernel-open/nvidia/nv-reg.h
--- a/kernel-open/nvidia/nv-reg.h
+++ b/kernel-open/nvidia/nv-reg.h
@@ -1046,7 +1046,7 @@
 NV_DEFINE_REG_ENTRY_GLOBAL(__NV_ENABLE_PCIE_RELAXED_ORDERING_MODE, 0);
 NV_DEFINE_REG_ENTRY_GLOBAL(__NV_REGISTER_PCI_DRIVER, 1);
 NV_DEFINE_REG_ENTRY_GLOBAL(__NV_REGISTER_PLATFORM_DEVICE_DRIVER, 1);
-NV_DEFINE_REG_ENTRY_GLOBAL(__NV_ENABLE_RESIZABLE_BAR, 0);
+NV_DEFINE_REG_ENTRY_GLOBAL(__NV_ENABLE_RESIZABLE_BAR, 1);
 NV_DEFINE_REG_ENTRY_GLOBAL(__NV_ENABLE_DBG_BREAKPOINT, 0);
 NV_DEFINE_REG_ENTRY_GLOBAL(__NV_TEGRA_GPU_PG_MASK, ~0);
 NV_DEFINE_REG_ENTRY_GLOBAL(__NV_ENABLE_NONBLOCKING_OPEN, 1);
diff -ruN a/kernel-open/nvidia/os-mlock.c b/kernel-open/nvidia/os-mlock.c
--- a/kernel-open/nvidia/os-mlock.c
+++ b/kernel-open/nvidia/os-mlock.c
@@ -25,6 +25,7 @@
 
 #include "os-interface.h"
 #include "nv-linux.h"
+#include <linux/hugetlb.h>
 
 #if defined(NVCPU_FAMILY_X86) && defined(NV_FOLL_LONGTERM_PRESENT) && \
     (defined(NV_PIN_USER_PAGES_HAS_ARGS_VMAS) ||                      \
@@ -213,6 +214,56 @@
     return rmStatus;
 }
 
+/*
+ * Hidden header prepended to every page array returned by os_lock_user_pages().
+ * Stores metadata that travels with the page array through opaque void* layers.
+ *
+ * Memory layout: [nv_page_array_header_t][struct page * array[num_entries]]
+ *
+ * The caller receives a pointer to the struct page * array (past the header).
+ * nv_register_user_pages() and os_unlock_user_pages() read the header at a
+ * negative offset to recover num_entries and compound_order.
+ */
+typedef struct {
+    NvU64 num_entries;
+    NvU64 compound_order;
+} nv_page_array_header_t;
+
+#define NV_PAGE_ARRAY_HEADER_SIZE sizeof(nv_page_array_header_t)
+
+static inline nv_page_array_header_t *nv_page_array_header(struct page **pages)
+{
+    return (nv_page_array_header_t *)((NvU8 *)pages - NV_PAGE_ARRAY_HEADER_SIZE);
+}
+
+static NV_STATUS nv_alloc_page_array(
+    NvU64 num_entries,
+    NvU32 compound_order,
+    struct page ***out_pages
+)
+{
+    NV_STATUS status;
+    NvU8 *raw;
+    nv_page_array_header_t *header;
+
+    status = os_alloc_mem((void **)&raw,
+            NV_PAGE_ARRAY_HEADER_SIZE + num_entries * sizeof(struct page *));
+    if (status != NV_OK)
+        return status;
+
+    header = (nv_page_array_header_t *)raw;
+    header->num_entries = num_entries;
+    header->compound_order = compound_order;
+
+    *out_pages = (struct page **)(raw + NV_PAGE_ARRAY_HEADER_SIZE);
+    return NV_OK;
+}
+
+static void nv_free_page_array(struct page **pages)
+{
+    os_free_mem((NvU8 *)pages - NV_PAGE_ARRAY_HEADER_SIZE);
+}
+
 NV_STATUS NV_API_CALL os_lock_user_pages(
     void   *address,
     NvU64   page_count,
@@ -223,8 +274,7 @@
     NV_STATUS rmStatus;
     struct mm_struct *mm = current->mm;
     struct page **user_pages;
-    NvU64 i;
-    NvU64 npages = page_count;
+    NvU64 i, j;
     NvU64 pinned = 0;
     unsigned int gup_flags = DRF_VAL(_LOCK_USER_PAGES, _FLAGS, _WRITE, flags) ? FOLL_WRITE : 0;
     long ret;
@@ -240,18 +290,75 @@
         return NV_ERR_NOT_SUPPORTED;
     }
 
-    rmStatus = os_alloc_mem((void **)&user_pages,
-            (page_count * sizeof(*user_pages)));
+    nv_mmap_read_lock(mm);
+
+    /*
+     * Hugetlb fast path: detect hugetlb VMAs and pin one page per hugepage.
+     * Pinning any sub-page of a compound page pins the entire folio via its
+     * refcount, so we only need one pin per hugepage. This reduces the page
+     * array from millions of entries to tens of entries for large mappings.
+     *
+     * Pages must be faulted before this call (caller should first-touch the
+     * entire mapping). pin_user_pages can fault on demand but is slow for
+     * unfaulted 1GB hugepages (~37ms per fault).
+     */
+    {
+        struct vm_area_struct *vma = vma_lookup(mm, (unsigned long)address);
+
+        if (vma && is_vm_hugetlb_page(vma))
+        {
+            unsigned long hpage_size = vma_kernel_pagesize(vma);
+            unsigned int order = ilog2(hpage_size / PAGE_SIZE);
+            NvU64 pages_per_hp = 1ULL << order;
+
+            if ((page_count & (pages_per_hp - 1)) == 0)
+            {
+                NvU64 num_hugepages = page_count >> order;
+
+                rmStatus = nv_alloc_page_array(num_hugepages, order, &user_pages);
+                if (rmStatus != NV_OK)
+                {
+                    nv_mmap_read_unlock(mm);
+                    nv_printf(NV_DBG_ERRORS,
+                            "NVRM: failed to allocate hugepage table!\n");
+                    return rmStatus;
+                }
+
+                for (i = 0; i < num_hugepages; i++)
+                {
+                    ret = NV_PIN_USER_PAGES(
+                        (unsigned long)address + i * hpage_size,
+                        1, gup_flags, &user_pages[i]);
+                    if (ret != 1)
+                    {
+                        for (j = 0; j < i; j++)
+                            NV_UNPIN_USER_PAGE(user_pages[j]);
+                        nv_free_page_array(user_pages);
+                        nv_mmap_read_unlock(mm);
+                        return NV_ERR_INVALID_ADDRESS;
+                    }
+                }
+
+                nv_mmap_read_unlock(mm);
+
+                *page_array = user_pages;
+                return NV_OK;
+            }
+        }
+    }
+
+    /* Normal path: pin all pages at 4K granularity */
+    rmStatus = nv_alloc_page_array(page_count, 0, &user_pages);
     if (rmStatus != NV_OK)
     {
+        nv_mmap_read_unlock(mm);
         nv_printf(NV_DBG_ERRORS,
                 "NVRM: failed to allocate page table!\n");
         return rmStatus;
     }
 
-    nv_mmap_read_lock(mm);
     ret = NV_PIN_USER_PAGES((unsigned long)address,
-                            npages, gup_flags, user_pages);
+                            page_count, gup_flags, user_pages);
     if (ret > 0)
     {
         pinned = ret;
@@ -276,6 +383,8 @@
     else if ((ret == -ENOMEM) &&
              (page_count > NV_NUM_PIN_PAGES_PER_ITERATION))
     {
+        NvU64 npages;
+
         for (pinned = 0; pinned < page_count; pinned += ret)
         {
             npages = page_count - pinned;
@@ -299,7 +408,7 @@
     {
         for (i = 0; i < pinned; i++)
             NV_UNPIN_USER_PAGE(user_pages[i]);
-        os_free_mem(user_pages);
+        nv_free_page_array(user_pages);
         return NV_ERR_INVALID_ADDRESS;
     }
 
@@ -316,16 +425,19 @@
 {
     NvBool write = FLD_TEST_DRF(_LOCK_USER_PAGES, _FLAGS, _WRITE, _YES, flags);
     struct page **user_pages = page_array;
-    NvU32 i;
+    nv_page_array_header_t *header = nv_page_array_header(user_pages);
+    NvU64 num_entries = header->num_entries;
+    NvU64 i;
 
-    for (i = 0; i < page_count; i++)
+    for (i = 0; i < num_entries; i++)
     {
         if (write)
             set_page_dirty_lock(user_pages[i]);
+
         NV_UNPIN_USER_PAGE(user_pages[i]);
     }
 
-    os_free_mem(user_pages);
+    nv_free_page_array(user_pages);
 
     return NV_OK;
 }
diff -ruN a/kernel-open/nvidia-uvm/uvm_gpu.h b/kernel-open/nvidia-uvm/uvm_gpu.h
--- a/kernel-open/nvidia-uvm/uvm_gpu.h
+++ b/kernel-open/nvidia-uvm/uvm_gpu.h
@@ -1824,6 +1824,13 @@
 
 static bool uvm_parent_gpu_is_coherent(const uvm_parent_gpu_t *parent_gpu)
 {
+    // Blackwell+ consumer GPUs (e.g. 5090) use BAR1 P2P via the SYS_COH
+    // aperture rewrite in nvGpuOpsBuildExternalAllocPtes. UVM's P2P
+    // registration path must take the coherent route to match, otherwise
+    // the ZONE_DEVICE peer DMA setup conflicts with BAR1-as-sysmem PTEs.
+    if (parent_gpu->rm_info.gpuArch >= NV2080_CTRL_MC_ARCH_INFO_ARCHITECTURE_GB100)
+        return true;
+
     return parent_gpu->system_bus.memory_window_end > parent_gpu->system_bus.memory_window_start;
 }
 
diff -ruN a/src/nvidia/arch/nvalloc/unix/include/nv.h b/src/nvidia/arch/nvalloc/unix/include/nv.h
--- a/src/nvidia/arch/nvalloc/unix/include/nv.h
+++ b/src/nvidia/arch/nvalloc/unix/include/nv.h
@@ -963,6 +963,8 @@
 
 NV_STATUS  NV_API_CALL  nv_register_user_pages   (nv_state_t *, NvU64, NvU64 *, void *, void **, NvBool);
 void       NV_API_CALL  nv_unregister_user_pages (nv_state_t *, NvU64, void **, void **);
+NvU32      NV_API_CALL  nv_get_compound_order    (void *);
+NvU32      NV_API_CALL  nv_get_page_array_compound_order(void *);
 
 NV_STATUS NV_API_CALL   nv_register_peer_io_mem  (nv_state_t *, NvU64 *, NvU64, void **);
 void      NV_API_CALL   nv_unregister_peer_io_mem(nv_state_t *, void *);
diff -ruN a/src/nvidia/arch/nvalloc/unix/src/osmemdesc.c b/src/nvidia/arch/nvalloc/unix/src/osmemdesc.c
--- a/src/nvidia/arch/nvalloc/unix/src/osmemdesc.c
+++ b/src/nvidia/arch/nvalloc/unix/src/osmemdesc.c
@@ -190,6 +190,8 @@
     NvU32 gpuCachedFlags;
     NvBool bUnprotected = NV_FALSE;
     NvU64 osPageCount;
+    NvU32 compoundOrder;
+    NvU64 memdescSize;
 
     //
     // Align size up to os page size. This is important in
@@ -201,6 +203,24 @@
 
     osPageCount = size >> os_page_shift;
 
+    //
+    // Read compound_order from os_lock_user_pages() hidden header. For
+    // hugepages, pass a reduced size to memdescCreate so the PTE array is
+    // sized for hugepage count instead of 4K page count. Restored after.
+    //
+    compoundOrder = nv_get_page_array_compound_order(*ppPrivate);
+
+    if (compoundOrder > 0)
+    {
+        NvU64 hugepageCount = size >> (os_page_shift + compoundOrder);
+
+        memdescSize = hugepageCount * NV_RM_PAGE_SIZE;
+    }
+    else
+    {
+        memdescSize = size;
+    }
+
     if (FLD_TEST_DRF(OS02, _FLAGS, _ALLOC_NISO_DISPLAY, _YES, flags))
     {
         memdescFlags |= MEMDESC_FLAGS_MEMORY_TYPE_DISPLAY_NISO;
@@ -223,7 +243,7 @@
         memdescFlags |= MEMDESC_FLAGS_DEVICE_READ_ONLY;
     }
 
-    rmStatus = memdescCreate(ppMemDesc, pGpu, size, 0,
+    rmStatus = memdescCreate(ppMemDesc, pGpu, memdescSize, 0,
                              NV_MEMORY_NONCONTIGUOUS, ADDR_SYSMEM,
                              cacheType, memdescFlags);
     if (rmStatus != NV_OK)
@@ -231,12 +251,19 @@
         return rmStatus;
     }
 
+    pMemDesc = *ppMemDesc;
+
+    // Restore actual size (memdescCreate stored the reduced PTE-sizing value).
+    if (compoundOrder > 0)
+    {
+        pMemDesc->Size = size;
+    }
+
     if (FLD_TEST_DRF(OS02, _FLAGS, _GPU_CACHEABLE, _YES, flags))
         gpuCachedFlags = NV_MEMORY_CACHED;
     else
         gpuCachedFlags = NV_MEMORY_UNCACHED;
 
-    pMemDesc = *ppMemDesc;
     rmStatus = nv_register_user_pages(NV_GET_NV_STATE(pGpu),
             osPageCount,
             memdescGetPteArray(pMemDesc, AT_CPU), pImportPriv,
@@ -251,7 +278,25 @@
     memdescSetFlag(pMemDesc, MEMDESC_FLAGS_KERNEL_MODE, NV_FALSE);
     memdescSetFlag(pMemDesc, MEMDESC_FLAGS_EXT_PAGE_ARRAY_MEM, NV_TRUE);
 
-    if (IS_DISCONTIG_AND_DYNGRAN_ENABLED(pMemDesc))
+    //
+    // For hugepages, set pageArrayGranularity to the hugepage size and
+    // advertise it as the GPU page size so UVM can use large GPU PTEs
+    // (e.g. 512MB on Blackwell) instead of 2MB.
+    //
+    if (compoundOrder > 0)
+    {
+        NvU64 hugepageGranularity = (NvU64)os_page_size << compoundOrder;
+
+        NV_ASSERT_OK_OR_GOTO(rmStatus,
+            memdescSetAllocSizeFields(pMemDesc, size, (NvU32)hugepageGranularity),
+            cleanup);
+
+        // TODO: UVM clamps to largest supported GPU page size via alignment.
+        // nvGpuOpsBuildExternalAllocPtes allows mappingPageSize <= pageSize
+        // when pageSize % mappingPageSize == 0.
+        memdescSetPageSize(pMemDesc, AT_GPU, hugepageGranularity);
+    }
+    else if (IS_DISCONTIG_AND_DYNGRAN_ENABLED(pMemDesc))
     {
         NV_ASSERT_OR_GOTO((os_page_size & (pMemDesc->pageArrayGranularity - 1ULL)) == 0, cleanup);
         NV_ASSERT_OK_OR_GOTO(rmStatus, memdescSetAllocSizeFields(pMemDesc, size, os_page_size), cleanup);
@@ -269,10 +314,14 @@
 
 
     //
-    // If the OS layer doesn't think in RM page size, we need to inflate the
-    // PTE array into RM pages.
+    // Inflate PTE array to RM pages.
+    // Skip for hugepages (already at granularity) and dynamic granularity.
     //
-    if (IS_DISCONTIG_AND_DYNGRAN_ENABLED(pMemDesc))
+    if (compoundOrder > 0)
+    {
+        // Hugepages: already at granularity, no conversion needed.
+    }
+    else if (IS_DISCONTIG_AND_DYNGRAN_ENABLED(pMemDesc))
     {
         // Because os_page_size == pMemDesc->pageArrayGranularity, we don't need to do any page array conversion.
         NV_ASSERT_OR_ELSE(os_page_size == pMemDesc->pageArrayGranularity, rmStatus = NV_ERR_INVALID_ARGUMENT; goto cleanup);
@@ -294,10 +343,15 @@
     memdescSetMemData(pMemDesc, *ppPrivate, NULL);
 
     rmStatus = memdescMapIommu(pMemDesc, pGpu->busInfo.iovaspaceId);
+
 cleanup:
     if (rmStatus != NV_OK)
     {
-        if (IS_DISCONTIG_AND_DYNGRAN_ENABLED(pMemDesc))
+        if (compoundOrder > 0)
+        {
+            // Hugepages: no deflation needed.
+        }
+        else if (IS_DISCONTIG_AND_DYNGRAN_ENABLED(pMemDesc))
         {
             // Because os_page_size == pMemDesc->pageArrayGranularity, we don't need to do any page array conversion.
             NV_ASSERT(os_page_size == pMemDesc->pageArrayGranularity);
@@ -1187,15 +1241,24 @@
     MEMORY_DESCRIPTOR *pMemDesc
 )
 {
-    OBJGPU   *pGpu        = pMemDesc->pGpu;
-    NvU64     osPageCount;
+    OBJGPU   *pGpu = pMemDesc->pGpu;
     NV_STATUS status;
     void     *pPrivate;
+    NvU32     compoundOrder;
+    NvU64     osPageCount;
 
     pPrivate = memdescGetMemData(pMemDesc);
 
     NV_ASSERT(pPrivate != NULL);
 
+    // Read before nv_unregister_user_pages frees the nv_alloc_t.
+    compoundOrder = nv_get_compound_order(pPrivate);
+
+    if (compoundOrder > 0)
+        osPageCount = pMemDesc->PageCount;
+    else
+        osPageCount = NV_RM_PAGES_TO_OS_PAGES(pMemDesc->PageCount);
+
     //
     // TODO: Bug 1811006: Notably skip any IOMMU mapping management as the
     // pMemDesc->pGpu might have been torn down already and the pGpu passed in
@@ -1205,21 +1268,21 @@
     // be cleaned up once the fix for bug 1811006 is known.
     //
 
-    if (IS_DISCONTIG_AND_DYNGRAN_ENABLED(pMemDesc))
+    // Deflate PTE array (skip for hugepages and dynamic granularity).
+    if (compoundOrder > 0)
+    {
+        // Hugepages: already at granularity, no deflation needed.
+    }
+    else if (IS_DISCONTIG_AND_DYNGRAN_ENABLED(pMemDesc))
     {
         // Because os_page_size == pMemDesc->pageArrayGranularity, we don't need to do any page array conversion.
         NV_ASSERT_OR_RETURN_VOID(os_page_size == pMemDesc->pageArrayGranularity);
-        osPageCount = pMemDesc->PageCount;
     }
-    else
-    {
-        osPageCount = NV_RM_PAGES_TO_OS_PAGES(pMemDesc->PageCount);
-        if ((NV_RM_PAGE_SIZE < os_page_size) &&
+    else if ((NV_RM_PAGE_SIZE < os_page_size) &&
             !memdescGetContiguity(pMemDesc, AT_CPU))
-        {
-            RmDeflateRmToOsPageArray(memdescGetPteArray(pMemDesc, AT_CPU),
-                                    pMemDesc->PageCount);
-        }
+    {
+        RmDeflateRmToOsPageArray(memdescGetPteArray(pMemDesc, AT_CPU),
+                                pMemDesc->PageCount);
     }
 
     nv_unregister_user_pages(NV_GET_NV_STATE(pGpu), osPageCount,
@@ -1231,12 +1294,8 @@
     }
     else
     {
-        //
-        // We use MEMDESC_FLAGS_USER_READ_ONLY because this reflects the
-        // NVOS02_FLAGS_ALLOC_USER_READ_ONLY flag value passed into
-        // os_lock_user_pages(). That flag also results in
-        // MEMDESC_FLAGS_DEVICE_READ_ONLY being set.
-        //
+        // TODO: os_unlock_user_pages reads the actual entry count from the
+        // hidden header, so osPageCount is only used in the non-hugepage path.
         NvBool writable = !memdescGetFlag(pMemDesc, MEMDESC_FLAGS_USER_READ_ONLY);
         NvU32 flags = DRF_NUM(_LOCK_USER_PAGES, _FLAGS, _WRITE, writable);
         status = os_unlock_user_pages(osPageCount, pPrivate, flags);
diff -ruN a/src/nvidia/generated/g_kern_bus_nvoc.c b/src/nvidia/generated/g_kern_bus_nvoc.c
--- a/src/nvidia/generated/g_kern_bus_nvoc.c
+++ b/src/nvidia/generated/g_kern_bus_nvoc.c
@@ -1064,7 +1064,7 @@
     // default
     else
     {
-        pThis->__kbusGetBar1P2PDmaInfo__ = &kbusGetBar1P2PDmaInfo_395e98;
+        pThis->__kbusGetBar1P2PDmaInfo__ = &kbusGetBar1P2PDmaInfo_GH100;
     }
 
     // kbusIncreaseStaticBar1Refcount -- halified (2 hals) body
@@ -1112,7 +1112,7 @@
     // default
     else
     {
-        pThis->__kbusCreateP2PMappingForBar1P2P__ = &kbusCreateP2PMappingForBar1P2P_395e98;
+        pThis->__kbusCreateP2PMappingForBar1P2P__ = &kbusCreateP2PMappingForBar1P2P_GH100;
     }
 
     // kbusRemoveP2PMappingForBar1P2P -- halified (2 hals) body
@@ -1124,7 +1124,7 @@
     // default
     else
     {
-        pThis->__kbusRemoveP2PMappingForBar1P2P__ = &kbusRemoveP2PMappingForBar1P2P_395e98;
+        pThis->__kbusRemoveP2PMappingForBar1P2P__ = &kbusRemoveP2PMappingForBar1P2P_GH100;
     }
 
     // kbusHasPcieBar1P2PMapping -- halified (2 hals) body
@@ -1136,7 +1136,7 @@
     // default
     else
     {
-        pThis->__kbusHasPcieBar1P2PMapping__ = &kbusHasPcieBar1P2PMapping_d69453;
+        pThis->__kbusHasPcieBar1P2PMapping__ = &kbusHasPcieBar1P2PMapping_GH100;
     }
 
     // kbusIsPcieBar1P2PMappingSupported -- halified (2 hals) body
@@ -1148,7 +1148,7 @@
     // default
     else
     {
-        pThis->__kbusIsPcieBar1P2PMappingSupported__ = &kbusIsPcieBar1P2PMappingSupported_d69453;
+        pThis->__kbusIsPcieBar1P2PMappingSupported__ = &kbusIsPcieBar1P2PMappingSupported_GH100;
     }
 
     // kbusCheckFlaSupportedAndInit -- halified (2 hals) body
diff -ruN a/src/nvidia/src/kernel/gpu/bif/kernel_bif.c b/src/nvidia/src/kernel/gpu/bif/kernel_bif.c
--- a/src/nvidia/src/kernel/gpu/bif/kernel_bif.c
+++ b/src/nvidia/src/kernel/gpu/bif/kernel_bif.c
@@ -1161,8 +1161,8 @@
 {
     NvU32 data32;
 
-    // P2P Override
-    pKernelBif->p2pOverride = BIF_P2P_NOT_OVERRIDEN;
+    // P2P Override: default to both reads+writes enabled so BAR1 P2P works out of the box
+    pKernelBif->p2pOverride = 0x11;
     if (osReadRegistryDword(pGpu, NV_REG_STR_CL_FORCE_P2P, &data32) == NV_OK)
     {
         pKernelBif->p2pOverride = data32;
@@ -1178,7 +1178,7 @@
         pKernelBif->forceP2PType = data32;
     }
 
-    pKernelBif->pcieP2PType = NV_REG_STR_RM_PCIEP2P_TYPE_DEFAULT;
+    pKernelBif->pcieP2PType = NV_REG_STR_RM_PCIEP2P_TYPE_BAR1;
     if (osReadRegistryDword(pGpu, NV_REG_STR_RM_PCIEP2P_TYPE, &data32) == NV_OK)
     {
         pKernelBif->pcieP2PType = data32;
diff -ruN a/src/nvidia/src/kernel/gpu/bus/arch/pascal/kern_bus_gp100.c b/src/nvidia/src/kernel/gpu/bus/arch/pascal/kern_bus_gp100.c
--- a/src/nvidia/src/kernel/gpu/bus/arch/pascal/kern_bus_gp100.c
+++ b/src/nvidia/src/kernel/gpu/bus/arch/pascal/kern_bus_gp100.c
@@ -65,6 +65,11 @@
         return kbusCreateP2PMappingForNvlink_HAL(pGpu0, pKernelBus0, pGpu1, pKernelBus1, peer0, peer1, attributes);
     }
 
+    if (FLD_TEST_DRF(_P2PAPI, _ATTRIBUTES, _CONNECTION_TYPE, _PCIE_BAR1, attributes))
+    {
+        return kbusCreateP2PMappingForBar1P2P_HAL(pGpu0, pKernelBus0, pGpu1, pKernelBus1, attributes);
+    }
+
     if (FLD_TEST_DRF(_P2PAPI, _ATTRIBUTES, _CONNECTION_TYPE, _PCIE, attributes))
     {
         return kbusCreateP2PMappingForMailbox_HAL(pGpu0, pKernelBus0, pGpu1, pKernelBus1, peer0, peer1, attributes);
@@ -643,6 +648,11 @@
         return kbusRemoveP2PMappingForNvlink_HAL(pGpu0, pKernelBus0, pGpu1, pKernelBus1, peer0, peer1, attributes);
     }
 
+    if (FLD_TEST_DRF(_P2PAPI, _ATTRIBUTES, _CONNECTION_TYPE, _PCIE_BAR1, attributes))
+    {
+        return kbusRemoveP2PMappingForBar1P2P_HAL(pGpu0, pKernelBus0, pGpu1, pKernelBus1, attributes);
+    }
+
     if (FLD_TEST_DRF(_P2PAPI, _ATTRIBUTES, _CONNECTION_TYPE, _PCIE, attributes))
     {
         return kbusRemoveP2PMappingForMailbox_HAL(pGpu0, pKernelBus0, pGpu1, pKernelBus1, peer0, peer1, attributes);
diff -ruN a/src/nvidia/src/kernel/mem_mgr/io_vaspace.c b/src/nvidia/src/kernel/mem_mgr/io_vaspace.c
--- a/src/nvidia/src/kernel/mem_mgr/io_vaspace.c
+++ b/src/nvidia/src/kernel/mem_mgr/io_vaspace.c
@@ -59,14 +59,15 @@
 void
 iovaspaceDestruct_IMPL(OBJIOVASPACE *pIOVAS)
 {
-    OBJVASPACE *pVAS = staticCast(pIOVAS, OBJVASPACE);
+    // OBJVASPACE *pVAS = staticCast(pIOVAS, OBJVASPACE);
 
-    if (pIOVAS->mappingCount != 0)
-    {
-        NV_PRINTF(LEVEL_ERROR, "%lld left-over mappings in IOVAS 0x%x\n",
-                  pIOVAS->mappingCount, pVAS->vaspaceId);
-        DBG_BREAKPOINT();
-    }
+    // TODO: might keep p2p mappings...
+    // if (pIOVAS->mappingCount != 0)
+    // {
+    //     NV_PRINTF(LEVEL_ERROR, "%lld left-over mappings in IOVAS 0x%x\n",
+    //               pIOVAS->mappingCount, pVAS->vaspaceId);
+    //     DBG_BREAKPOINT();
+    // }
 }
 
 NV_STATUS
@@ -595,7 +596,7 @@
     // not, the mapping has been left dangling outlasting the IOVAS it was
     // under.
     //
-    NV_ASSERT(pIOVAS != NULL);
+    // NV_ASSERT(pIOVAS != NULL);
 
     return pIOVAS;
 }
@@ -604,7 +605,7 @@
 {
     OBJIOVASPACE *pIOVAS = iovaspaceFromMapping(pIovaMapping);
 
-    NV_ASSERT_OR_RETURN_VOID(pIOVAS != NULL);
+    if (pIOVAS == NULL) return;
     iovaspaceDestroyMapping(pIOVAS, pIovaMapping);
 }
 
diff -ruN a/src/nvidia/src/kernel/rmapi/nv_gpu_ops.c b/src/nvidia/src/kernel/rmapi/nv_gpu_ops.c
--- a/src/nvidia/src/kernel/rmapi/nv_gpu_ops.c
+++ b/src/nvidia/src/kernel/rmapi/nv_gpu_ops.c
@@ -3875,7 +3875,8 @@
     NvBool      isPeerSupported,
     NvBool      isBar1P2PSupported,
     NvU32       peerId,
-    gpuExternalMappingInfo *pGpuExternalMappingInfo
+    gpuExternalMappingInfo *pGpuExternalMappingInfo,
+    RmPhysAddr bar1BusAddr
 )
 {
     NV_STATUS               status              = NV_OK;
@@ -4033,7 +4034,14 @@
         NvU32 ptePcfHw  = 0;
 
          nvFieldSetBool(&pPteFmt->fldValid, NV_TRUE, pte.v8);
-         gmmuFieldSetAperture(&pPteFmt->fldAperture, aperture, pte.v8);
+         if ((aperture == GMMU_APERTURE_PEER) && isBar1P2PSupported)
+         {
+             gmmuFieldSetAperture(&pPteFmt->fldAperture, GMMU_APERTURE_SYS_COH, pte.v8);
+         }
+         else
+         {
+             gmmuFieldSetAperture(&pPteFmt->fldAperture, aperture, pte.v8);
+         }
          nvFieldSet32(&pPteFmt->fldKind, kind, pte.v8);
 
          ptePcfSw |= vol         ? (1 << SW_MMU_PCF_UNCACHED_IDX) : 0;
@@ -4077,7 +4085,14 @@
         if (nvFieldIsValid32(&pPteFmt->fldAtomicDisable.desc))
             nvFieldSetBool(&pPteFmt->fldAtomicDisable, !atomic, pte.v8);
 
-        gmmuFieldSetAperture(&pPteFmt->fldAperture, aperture, pte.v8);
+        if ((aperture == GMMU_APERTURE_PEER) && isBar1P2PSupported)
+        {
+            gmmuFieldSetAperture(&pPteFmt->fldAperture, GMMU_APERTURE_SYS_NONCOH, pte.v8);
+        }
+        else
+        {
+            gmmuFieldSetAperture(&pPteFmt->fldAperture, aperture, pte.v8);
+        }
 
         if (!isCompressedKind)
         {
@@ -4088,7 +4103,12 @@
         }
     }
 
-    if (aperture == GMMU_APERTURE_PEER)
+    if ((aperture == GMMU_APERTURE_PEER) && isBar1P2PSupported)
+    {
+        fabricBaseAddress = bar1BusAddr;
+    }
+
+    if ((aperture == GMMU_APERTURE_PEER) && !isBar1P2PSupported)
     {
         nvFieldSet32(&pPteFmt->fldPeerIndex, peerId, pte.v8);
 
@@ -4347,7 +4367,8 @@
     NvBool      isPeerSupported,
     NvBool      isBar1P2PSupported,
     NvU32       peerId,
-    UvmGpuExternalPhysAddrInfo *pGpuExternalPhysAddrInfo
+    UvmGpuExternalPhysAddrInfo *pGpuExternalPhysAddrInfo,
+    RmPhysAddr bar1BusAddr
 )
 {
     NV_STATUS               status              = NV_OK;
@@ -4425,7 +4446,12 @@
         return NV_ERR_BUFFER_TOO_SMALL;
 
 
-    if (aperture == GMMU_APERTURE_PEER)
+    if ((aperture == GMMU_APERTURE_PEER) && isBar1P2PSupported)
+    {
+        fabricBaseAddress = bar1BusAddr;
+    }
+
+    if ((aperture == GMMU_APERTURE_PEER) && !isBar1P2PSupported)
     {
         //
         // Any fabric memory descriptors are pre-encoded with the fabric base address
@@ -4567,6 +4593,7 @@
     Memory *pMemory = NULL;
     PMEMORY_DESCRIPTOR pMemDesc = NULL;
     OBJGPU *pMappingGpu = NULL;
+    RmPhysAddr bar1BusAddr = 0;
     NvU32 peerId = 0;
     NvBool isSliSupported = NV_FALSE;
     NvBool isPeerSupported = NV_FALSE;
@@ -4706,6 +4733,8 @@
                                                        &peerId);
             if (status != NV_OK)
                 goto freeGpaMemdesc;
+
+            bar1BusAddr = gpumgrGetGpuPhysFbAddr(pAdjustedMemDesc->pGpu);
         }
 
         //
@@ -4794,14 +4823,15 @@
                                                 isPeerSupported,
                                                 isBar1P2PSupported,
                                                 peerId,
-                                                pGpuExternalMappingInfo);
+                                                pGpuExternalMappingInfo,
+                                                bar1BusAddr);
     }
 
     if (pGpuExternalPhysAddrInfo != NULL)
     {
         status = nvGpuOpsBuildExternalAllocPhysAddrs(pVAS, vaSpace->device->session, pMappingGpu, pAdjustedMemDesc,
                                                      pMemory, offset, size, isIndirectPeerSupported, isPeerSupported,
-                                                     isBar1P2PSupported, peerId, pGpuExternalPhysAddrInfo);
+                                                     isBar1P2PSupported, peerId, pGpuExternalPhysAddrInfo, bar1BusAddr);
     }
 
 freeGpaMemdesc:
@@ -10950,7 +10980,7 @@
 
     status = nvGpuOpsBuildExternalAllocPtes(pVAS, vaSpace->device->session, pMappingGpu, pMemDesc, NULL,
                                             offset, size, NV_FALSE, NV_FALSE,
-                                            NV_FALSE, 0, pGpuExternalMappingInfo);
+                                            NV_FALSE, 0, pGpuExternalMappingInfo, 0);
 
     _nvGpuOpsLocksRelease(&acquiredLocks);
     threadStateFree(&threadState, THREAD_STATE_FLAGS_NONE);
__P2P_PATCH__
}

main "$@"
