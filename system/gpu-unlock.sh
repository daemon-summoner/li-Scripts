#!/usr/bin/env bash
# Detect the NVIDIA GPUs and apply a power and clock cap at every boot. Advanced config optionally upgrades to
# the newest Ubuntu driver, adds gpu-unlock for Ampere cards and the P2P-patched driver for identical pairs.
# Usage: ./gpu-unlock.sh [--driver yes|no] [--unlock yes|no] [--p2p auto|yes|no] [--targets ...] [--power-limit ...]
#        ./unlock_gpu.sh p2p-check|p2p-uninstall|p2p-host <vmid>   (see --help)
set -euo pipefail

REPO_URL=https://github.com/Zagitta/gpu-unlock
WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KVER="$(uname -r)"
TARGETS=all
TARGETS_GIVEN=0
SRC_DIR=""
# 5090s stay at their stock 575W; the entry pins it so a lowered limit does not survive a reboot.
POWER_LIMIT=3090=275,5090=575
CLOCK_CAP=3090=2000
POWER_UNIT=/etc/systemd/system/nvidia-power-limit.service
# Both stay off unless advanced config or a flag turns them on: with the unlock active a 3090 here dropped
# off the bus (Xid 79) within hours of every boot, and a plain run must leave a stable machine.
UNLOCK=""
P2P=""
DRIVER=""
DRIVER_PKG=""
DRIVER_VERSION=""
REBOOT_NEEDED=0

P2P_VERSION=615.71.09
SRC_URL="https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/$P2P_VERSION.tar.gz"
SRC_SHA256=caf48cda7d5fe7374d1d24ca4a90efb4dc783eefabfad5fa4b64fdc24213b62a
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
die() {
	echo "unlock_gpu: error: $*" >&2
	exit 1
}

usage() {
	cat <<EOF
Usage: $0 [--driver yes|no] [--unlock yes|no] [--p2p auto|yes|no] [--targets all|<pci>[,<pci>...]]
          [--src DIR] [--power-limit W|MODEL=W[,MODEL=W...]]
       $0 p2p-check [--python "CMD"]
       $0 p2p-uninstall
       $0 p2p-host <vmid> [--clique N] [--undo]

With no subcommand it sets up this machine for the NVIDIA GPUs it finds:
  power cap      Every card, through a systemd unit that runs before Docker at each boot.
                 The same unit locks GPU clocks per model ($CLOCK_CAP MHz max).

It then asks "Do advanced config? (Y/n)" unless --driver, --unlock and --p2p settle every
feature; without a terminal, or when the answer is no, the driver is left as it is, the
other two stay off and any earlier install of them is removed:
  driver         Upgrade to the newest nvidia-driver-N-open apt offers (Debian/Ubuntu).
                 Asked first, default yes; P2P is then offered only if that version
                 is the one the P2P patch is for.
  gpu-unlock     BF16 unlock, only when an Ampere card (GA102/GA103/GA104/GA106) is present.
  P2P driver     Only when two identical cards are present and the stock open driver
                 is $P2P_VERSION on Debian/Ubuntu, inside the VM (not the Proxmox host).

  --driver       yes upgrades to the newest Ubuntu open driver, no leaves the driver alone.
  --unlock       yes installs gpu-unlock and adds its boot flag, no removes the flag.
  --p2p          yes installs the P2P driver and fails when it cannot, auto installs it
                 only when it applies, no removes it if installed.
  --targets      Cards to unlock, as gpu_unlock.targets takes them (default: all, which
                 covers only the Ampere cards). PCI addresses as 'lspci -D' prints them.
                 Implies --unlock yes.
  --src          An existing gpu-unlock checkout to install from. Without it the repo
                 is cloned into $WORK_DIR/gpu-unlock when the module is missing.
  --power-limit  Watts for every card, or per model (default: $POWER_LIMIT); a model
                 matches any card whose name contains it. Cards no entry matches keep
                 their default limit.

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
	done < <(lspci -D -nn -d 10de: |
		sed -nE 's/^([^ ]+) .*\[030[02]\]: NVIDIA Corporation (.*) \[10de:([0-9a-f]{4})\].*$/\1 \3 \2/p')
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
	modinfo -k "$KVER" gpu_unlock >/dev/null 2>&1 &&
		compgen -G "/usr/lib/firmware/gpu-unlock/*/gsp_ga10x.bin" >/dev/null
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
		die "changed the GRUB defaults, but found no update-grub or grub-mkconfig to regenerate grub.cfg"
	fi
}

add_flag() {
	local method="$1"
	case "$method" in
	grub)
		# Debian's update-grub reads /etc/default/grub.d; upstream grub-mkconfig only reads /etc/default/grub.
		if command -v update-grub >/dev/null && [[ -d /etc/default/grub.d ]]; then
			log "writing /etc/default/grub.d/99-gpu-unlock.cfg"
			echo "GRUB_CMDLINE_LINUX_DEFAULT=\"\$GRUB_CMDLINE_LINUX_DEFAULT $FLAG\"" |
				sudo tee /etc/default/grub.d/99-gpu-unlock.cfg >/dev/null
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
	[[ -n $method ]] || die "no supported boot config found (GRUB, grubby or /etc/kernel/cmdline); add $FLAG to your kernel command line by hand"
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

remove_flag() {
	local method="$1" f v
	case "$method" in
	grub)
		while read -r f; do
			grep -q 'gpu_unlock\.targets=' "$f" || continue
			if [[ $f == /etc/default/grub.d/99-gpu-unlock.cfg ]]; then
				log "removing $f"
				sudo rm "$f"
			else
				log "removing gpu_unlock.targets from $f"
				sudo sed -i -E 's/[[:space:]]*gpu_unlock\.targets=[^"'"'"' ]*//g' "$f"
			fi
		done < <(grub_files)
		[[ -z "$(configured_flag grub)" ]] || die "removed gpu_unlock.targets, but it is still in the GRUB config; check /etc/default/grub and /etc/default/grub.d"
		regenerate_grub
		;;
	grubby)
		while read -r v; do
			log "removing $v from every kernel with grubby"
			sudo grubby --update-kernel=ALL --remove-args="$v"
		done < <(sudo grubby --info=ALL | grep -o 'gpu_unlock\.targets=[^"'"'"' ]*' | sort -u)
		;;
	kernel-cmdline)
		log "removing gpu_unlock.targets from /etc/kernel/cmdline"
		sudo sed -i -E 's/[[:space:]]*gpu_unlock\.targets=[^ ]*//g' /etc/kernel/cmdline
		if command -v mkinitcpio >/dev/null; then
			sudo mkinitcpio -P
		else
			die "removed gpu_unlock.targets from /etc/kernel/cmdline, but only mkinitcpio regeneration is automated; rebuild your boot images yourself"
		fi
		;;
	esac
	REBOOT_NEEDED=1
}

# The module can stay installed: without gpu_unlock.targets on the command line it unlocks nothing.
ensure_unlock_off() {
	local method
	method="$(bootloader)"
	if [[ -n $method && -n "$(configured_flag "$method")" ]]; then
		remove_flag "$method"
	else
		log "gpu-unlock: off"
	fi
	if grep -qw 'gpu_unlock\.targets=[^ ]*' /proc/cmdline; then
		REBOOT_NEEDED=1
		log "gpu-unlock: the running kernel still has the unlock until the reboot"
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
	grep -E 'gpu_unlock: (unlocked|.*(skip|refus|fail|error))' <<<"$kernel_log" |
		grep -v 'module verification failed' |
		sed -e 's/^/  /' -e 's/(-114)$/(-114: card not cold, still unlocked from an earlier boot)/' || true
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
	elif [[ $DRIVER != yes ]]; then
		# With DRIVER=yes the driver step installs the open release first, and choose_features
		# has already refused one that does not match P2P_VERSION.
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
	# Read from dpkg, not nvidia-smi: right after a driver upgrade the old module is still loaded until the reboot.
	local userspace
	userspace="$(dpkg-query -W -f '${Version}' "libnvidia-compute-${P2P_VERSION%%.*}" 2>/dev/null || true)"
	[[ $userspace == "$P2P_VERSION"-* ]] ||
		die "CUDA userspace (libnvidia-compute-${P2P_VERSION%%.*}) is '${userspace:-not installed}', but the P2P patch is for $P2P_VERSION"

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
	apply_distro_patches "$src/kernel-open"

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
	{ [[ -f $DEPMOD_CONF ]] && grep -v " $KVER $INSTALL_SUBDIR\$" "$DEPMOD_CONF" || true; } >"$tmp"
	for m in "${MODULES[@]}"; do
		echo "override ${m//-/_} $KVER $INSTALL_SUBDIR" >>"$tmp"
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

# NVIDIA's release does not always build on the distro's newest kernels; the distro ships the fixes
# with its DKMS source and lists in dkms.conf which kernels each one is for, so they go on the same way.
apply_distro_patches() {
	local dest="$1" dkms="/usr/src/nvidia-$P2P_VERSION"
	[[ -f $dkms/dkms.conf ]] || die "no $dkms/dkms.conf; install the stock nvidia-driver-${P2P_VERSION%%.*}-open first"
	local line idx name match
	while IFS= read -r line; do
		idx="${line#PATCH[}"
		idx="${idx%%]*}"
		name="${line#*=\"}"
		name="${name%\"}"
		match="$(sed -nE "s/^PATCH_MATCH\[$idx\]='(.*)'\$/\1/p" "$dkms/dkms.conf")"
		if [[ -n $match && ! $KVER =~ $match ]]; then
			continue
		fi
		log "applying the distro build fix $name"
		patch -d "$dest" -p1 --forward --no-backup-if-mismatch -s <"$dkms/patches/$name"
	done < <(grep -E '^PATCH\[[0-9]+\]="[^"]+"$' "$dkms/dkms.conf")
}

ensure_p2p() {
	if [[ $P2P == no ]]; then
		if p2p_installed; then
			log "P2P: removing the patched driver"
			guest_uninstall
			REBOOT_NEEDED=1
		else
			log "P2P: off"
		fi
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
		grep -v " $KVER $INSTALL_SUBDIR\$" "$DEPMOD_CONF" >"$tmp" || true
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
		matrix="$(nvidia-smi topo -p2p "$mode" | sed '/^[[:space:]]*$/q' | sed '/^[[:space:]]*$/d')" ||
			die "nvidia-smi topo -p2p $mode failed"
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
	$PYTHON_CMD -c "$P2P_TEST_PY" ||
		die "copy test failed. If the patched driver is loaded, try the host step: $0 p2p-host <vmid>"
}

host_main() {
	local vmid="" clique=0 undo=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--clique)
			[[ $# -ge 2 && $2 =~ ^[0-9]+$ && $2 -le 15 ]] || die "--clique needs a number from 0 to 15"
			clique="$2"
			shift 2
			;;
		--undo)
			undo=1
			shift
			;;
		-*) die "unknown p2p-host option: $1" ;;
		*)
			[[ -z $vmid ]] || die "only one VM ID"
			vmid="$1"
			shift
			;;
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
		[[ $args == *"device.$idx.x-nv-gpudirect-clique="* ]] ||
			set_args+=("-set device.$idx.x-nv-gpudirect-clique=$clique")
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

# ---------------------------------------------------------------- driver upgrade

# Sets DRIVER_PKG and DRIVER_VERSION to the newest nvidia-driver-N-open apt can install; the
# transitional metapackages only point at a newer N, so they are skipped.
has_apt() {
	command -v apt-get >/dev/null && command -v dpkg-query >/dev/null
}

resolve_driver() {
	[[ -z $DRIVER_PKG ]] || return 0
	has_apt || die "the driver upgrade needs apt (Debian/Ubuntu)"
	log "refreshing the apt package lists"
	$SUDO apt-get update -qq
	DRIVER_PKG="$(apt-cache search --names-only '^nvidia-driver-[0-9]+-open$' |
		grep -v '(transitional package)' | awk '{ print $1 }' | sort -V | tail -n1)"
	[[ -n $DRIVER_PKG ]] || die "apt offers no nvidia-driver-N-open package; is the restricted component enabled?"
	DRIVER_VERSION="$(apt-cache policy "$DRIVER_PKG" | awk '/Candidate:/ { print $2 }')"
	[[ -n $DRIVER_VERSION && $DRIVER_VERSION != "(none)" ]] || die "apt has no installable version of $DRIVER_PKG"
}

driver_is_latest() {
	[[ "$(dpkg-query -W -f '${db:Status-Status} ${Version}' "$DRIVER_PKG" 2>/dev/null || true)" == "installed $DRIVER_VERSION" ]]
}

ensure_driver() {
	if [[ $DRIVER == no ]]; then
		log "driver: left as it is"
		return
	fi
	resolve_driver
	if driver_is_latest; then
		log "driver: $DRIVER_PKG $DRIVER_VERSION, the newest Ubuntu release, is already installed"
		return
	fi
	[[ ! -f $DEPMOD_CONF ]] ||
		die "the patched P2P driver is still installed ($DEPMOD_CONF) and would shadow the new driver; run $0 p2p-uninstall on each kernel it lists"
	# The P2P step holds whatever release it was built for; apt refuses to replace held packages.
	local held
	mapfile -t held < <(apt-mark showhold | grep -E '^(lib)?nvidia-|^xserver-xorg-video-nvidia-' || true)
	if [[ ${#held[@]} -gt 0 ]]; then
		log "releasing the hold on ${#held[@]} NVIDIA driver packages"
		$SUDO apt-mark unhold "${held[@]}" >/dev/null
	fi
	log "installing $DRIVER_PKG $DRIVER_VERSION"
	$SUDO apt-get install -y "$DRIVER_PKG"
	driver_is_latest || die "apt-get finished, but $DRIVER_PKG $DRIVER_VERSION is not installed"
	REBOOT_NEEDED=1
}

# ---------------------------------------------------------------- power cap

POWER_CMDS=()
CLOCK_CMDS=()

# Prints the value a W or MODEL=W[,MODEL=W...] spec gives a card with this name, or nothing when no entry matches.
model_value() {
	local spec="$1" name="$2" entry
	if [[ $spec =~ ^[1-9][0-9]*$ ]]; then
		echo "$spec"
		return
	fi
	local -a entries
	IFS=, read -ra entries <<<"$spec"
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
	[[ $count -eq ${#GPU_ADDRS[@]} ]] ||
		die "nvidia-smi reaches $count of the ${#GPU_ADDRS[@]} cards lspci lists; a card off the bus needs a reboot before power caps can be set"

	local bus name min max watts mhz
	while IFS=, read -r bus name min max; do
		name="${name# }"
		min="${min# }"
		max="${max# }"
		mhz="$(model_value "$CLOCK_CAP" "$name")"
		[[ -z $mhz ]] || CLOCK_CMDS+=("$bus $mhz")
		watts="$(model_value "$POWER_LIMIT" "$name")"
		if [[ -z $watts ]]; then
			log "$bus $name: no --power-limit entry matches, keeping its default limit"
			continue
		fi
		awk -v w="$watts" -v lo="$min" -v hi="$max" 'BEGIN { exit !(w >= lo && w <= hi) }' ||
			die "$name ($bus) accepts ${min%.*}-${max%.*}W, not ${watts}W; set it per model, e.g. --power-limit \"3090=325,5090=450\""
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
	for entry in "${CLOCK_CMDS[@]}"; do
		echo "ExecStart=/usr/bin/nvidia-smi -i ${entry% *} -lgc 210,${entry#* }"
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
	if [[ ${#POWER_CMDS[@]} -eq 0 && ${#CLOCK_CMDS[@]} -eq 0 ]]; then
		log "no card gets a power or clock cap"
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
	sudo systemctl restart nvidia-power-limit.service ||
		die "could not apply the power caps now (see: journalctl -u nvidia-power-limit); the unit is enabled and runs at next boot"
	log "power limits and current SM clocks now:"
	nvidia-smi --query-gpu=index,name,power.limit,clocks.sm --format=csv,noheader | sed 's/^/  GPU /'
}

# ---------------------------------------------------------------- advanced config

# Asks a yes/no question; an empty answer takes the default (y or n).
confirm() {
	local question="$1" default="$2" reply
	while true; do
		read -r -p "$question " reply || die "no answer to: $question"
		reply="${reply:-$default}"
		case "${reply,,}" in
		y | yes) return 0 ;;
		n | no) return 1 ;;
		*) echo "please answer y or n" ;;
		esac
	done
}

# Settles DRIVER, UNLOCK and P2P, asking only about the ones no flag decided.
choose_features() {
	local advanced=0
	if [[ -z $DRIVER || -z $UNLOCK || -z $P2P ]]; then
		if [[ ! -t 0 ]]; then
			log "no terminal to ask on; advanced config skipped"
		elif confirm "Do advanced config? (Y/n)" y; then
			advanced=1
		fi
	fi
	if [[ -z $DRIVER ]]; then
		DRIVER=no
		if [[ $advanced -eq 1 ]]; then
			if ! has_apt; then
				log "driver: upgrade not offered, it needs apt (Debian/Ubuntu)"
			else
				resolve_driver
				if driver_is_latest; then
					log "driver: $DRIVER_PKG $DRIVER_VERSION, the newest Ubuntu release, is already installed"
				elif confirm "Install the newest Ubuntu NVIDIA driver, $DRIVER_PKG $DRIVER_VERSION? (Y/n)" y; then
					DRIVER=yes
				fi
			fi
		fi
	fi
	# The P2P patch fits one driver release, so an upgrade to any other rules it out.
	local p2p_conflict=""
	if [[ $DRIVER == yes ]]; then
		resolve_driver
		[[ $DRIVER_VERSION == "$P2P_VERSION"-* ]] ||
			p2p_conflict="its patch is for driver $P2P_VERSION and the driver is moving to $DRIVER_VERSION"
	fi
	if [[ -n $p2p_conflict && $P2P == yes ]]; then
		die "P2P: $p2p_conflict; drop --driver yes or --p2p yes"
	elif [[ -n $p2p_conflict && $P2P == auto ]]; then
		log "P2P: skipped, $p2p_conflict"
		P2P=no
	fi
	if [[ -z $UNLOCK ]]; then
		UNLOCK=no
		if [[ $advanced -eq 1 ]] && has_ampere &&
			confirm "Enable the BF16 unlock (gpu-unlock)? It has made 3090s drop off the bus. (y/N)" n; then
			UNLOCK=yes
		fi
	fi
	if [[ -z $P2P ]]; then
		P2P=no
		if [[ $advanced -eq 1 ]]; then
			local why="$p2p_conflict"
			[[ -n $why ]] || p2p_installed || why="$(p2p_blocker)"
			if [[ -n $why ]]; then
				log "P2P: not offered, $why"
			elif confirm "Install the P2P GPU-to-GPU driver? (y/N)" n; then
				P2P=yes
			fi
		fi
	fi
}

# ---------------------------------------------------------------- main

setup_main() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--targets)
			[[ $# -ge 2 ]] || die "--targets needs a value"
			TARGETS="$2"
			TARGETS_GIVEN=1
			shift 2
			;;
		--src)
			[[ $# -ge 2 ]] || die "--src needs a directory"
			SRC_DIR="$2"
			shift 2
			;;
		--power-limit)
			[[ $# -ge 2 ]] || die "--power-limit needs a value in watts"
			POWER_LIMIT="$2"
			shift 2
			;;
		--p2p)
			[[ $# -ge 2 && $2 =~ ^(auto|yes|no)$ ]] || die "--p2p needs auto, yes or no"
			P2P="$2"
			shift 2
			;;
		--unlock)
			[[ $# -ge 2 && $2 =~ ^(yes|no)$ ]] || die "--unlock needs yes or no"
			UNLOCK="$2"
			shift 2
			;;
		--driver)
			[[ $# -ge 2 && $2 =~ ^(yes|no)$ ]] || die "--driver needs yes or no"
			DRIVER="$2"
			shift 2
			;;
		*)
			usage >&2
			die "unknown argument: $1"
			;;
		esac
	done

	[[ $EUID -ne 0 ]] || die "run as your normal user: package builders such as makepkg refuse root, and sudo is used where needed"

	local pci_re='[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]'
	[[ $TARGETS == all || $TARGETS =~ ^$pci_re(,$pci_re)*$ ]] ||
		die "--targets must be 'all' or comma-separated PCI addresses like 0000:01:00.0, got '$TARGETS'"
	FLAG="gpu_unlock.targets=$TARGETS"
	if [[ $TARGETS_GIVEN -eq 1 ]]; then
		[[ $UNLOCK != no ]] || die "--targets picks cards to unlock, but --unlock no turns the unlock off"
		UNLOCK=yes
	fi
	local model_re='[^=,]+=[1-9][0-9]*'
	[[ $POWER_LIMIT =~ ^[1-9][0-9]*$ || $POWER_LIMIT =~ ^$model_re(,$model_re)*$ ]] ||
		die "--power-limit must be whole watts or MODEL=WATTS pairs like 3090=325,5090=450, got '$POWER_LIMIT'"

	detect_gpus
	choose_features
	if ! has_ampere; then
		[[ $UNLOCK != yes ]] || die "gpu-unlock requested, but no Ampere card is present for it"
		log "gpu-unlock: skipped, it only supports Ampere cards (GA102/GA103/GA104/GA106)"
	elif [[ $UNLOCK == yes ]]; then
		install_module
		ensure_flag
	else
		ensure_unlock_off
	fi
	# Before any driver change: after an upgrade nvidia-smi cannot reach the cards until the reboot.
	ensure_power_limit
	# Patched P2P modules would shadow an upgraded driver, so removing them comes first,
	# while installing them needs the final driver in place.
	if [[ $P2P == no ]]; then
		ensure_p2p
		ensure_driver
	else
		ensure_driver
		ensure_p2p
	fi
	if has_ampere && [[ $UNLOCK == yes ]]; then
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
	-h | --help) usage ;;
	p2p-check)
		shift
		while [[ $# -gt 0 ]]; do
			case "$1" in
			--python)
				[[ $# -ge 2 ]] || die "--python needs a command"
				PYTHON_CMD="$2"
				shift 2
				;;
			*) die "unknown p2p-check option: $1" ;;
			esac
		done
		detect_gpus
		guest_check
		;;
	p2p-uninstall)
		shift
		[[ $# -eq 0 ]] || die "p2p-uninstall takes no options"
		guest_uninstall
		;;
	p2p-host)
		shift
		host_main "$@"
		;;
	*) setup_main "$@" ;;
	esac
}

# P2P patch for NVIDIA's open kernel modules at P2P_VERSION: the kernel sources of aikitoria/open-gpu-kernel-modules
# branch 615.71.09-p2p at c8bff5400e2f, which enable BAR1 P2P on GeForce 30/40/50-series cards.
p2p_patch() {
	cat <<'__P2P_PATCH__'
diff -ruN a/kernel-open/common/inc/nv.h b/kernel-open/common/inc/nv.h
--- a/kernel-open/common/inc/nv.h
+++ b/kernel-open/common/inc/nv.h
@@ -977,6 +977,8 @@
 
 NV_STATUS  NV_API_CALL  nv_register_user_pages   (nv_state_t *, NvU64, NvU64 *, void *, void **, NvBool);
 void       NV_API_CALL  nv_unregister_user_pages (nv_state_t *, NvU64, void **, void **);
+NvU32      NV_API_CALL  nv_get_compound_order    (void *);
+NvU32      NV_API_CALL  nv_get_page_array_compound_order(void *);
 
 NV_STATUS NV_API_CALL   nv_register_peer_io_mem  (nv_state_t *, NvU64 *, NvU64, void **);
 void      NV_API_CALL   nv_unregister_peer_io_mem(nv_state_t *, void *);
diff -ruN a/kernel-open/common/inc/nv-linux.h b/kernel-open/common/inc/nv-linux.h
--- a/kernel-open/common/inc/nv-linux.h
+++ b/kernel-open/common/inc/nv-linux.h
@@ -933,6 +933,7 @@
     unsigned int   cache_type;
     unsigned int   num_pages;
     unsigned int   order;
+    unsigned int   compound_order;      /* 0 for base pages */
     unsigned int   size;
     nvidia_pte_t  *page_table;          /* array of physical pages allocated */
     unsigned int   pid;
@@ -945,6 +946,14 @@
     nv_linux_mm_free_work_t *accounting_mm_work;
 } nv_alloc_t;
 
+static inline NvU64 nv_alloc_page_address(nv_alloc_t *at, NvU64 page_index)
+{
+    NvU64 offset = page_index & ((1ULL << at->compound_order) - 1);
+
+    return at->page_table[page_index >> at->compound_order].phys_addr +
+           (offset << PAGE_SHIFT);
+}
+
 /**
  * nv_is_dma_direct - return true if direct_dma is enabled
  *
@@ -1065,6 +1074,7 @@
     NvBool contiguous;
     NvU32 cache_type;
     NvBool bReadOnlyDeviceMap;
+    NvU64 page_granularity;             /* bytes per page array entry */
     struct sg_table *import_sgt;
 
     union
diff -ruN a/kernel-open/nvidia/nv.c b/kernel-open/nvidia/nv.c
--- a/kernel-open/nvidia/nv.c
+++ b/kernel-open/nvidia/nv.c
@@ -3598,12 +3598,21 @@
     NvU64 i;
     struct page **user_pages;
     nv_linux_state_t *nvl;
+    NvU32 compound_order;
+    NvU64 effective_count;
 
     nv_printf(NV_DBG_MEMINFO, "NVRM: VM: nv_register_user_pages: 0x%" NvU64_fmtx"\n", page_count);
     user_pages = *priv_data;
     nvl = NV_GET_NVL_FROM_NV_STATE(nv);
 
-    at = nvos_create_alloc(nvl->dev, page_count);
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
@@ -3624,9 +3633,10 @@
     if (unencrypted)
         at->flags.unencrypted = NV_TRUE;
 
+    at->compound_order = compound_order;
     at->order = get_order(at->num_pages * PAGE_SIZE);
 
-    for (i = 0; i < page_count; i++)
+    for (i = 0; i < effective_count; i++)
     {
         /*
          * We only assign the physical address and not the DMA address, since
@@ -3651,6 +3661,23 @@
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
+/* Matches nv_page_array_header_t in os-mlock.c. */
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
@@ -3878,12 +3905,13 @@
 )
 {
     nv_alloc_t *at = pAllocPrivate;
+    NvU64 page_count = (NvU64)at->num_pages << at->compound_order;
 
-    if (!pNumPages) {
+    if (!pNumPages || page_count > NV_U32_MAX) {
         return NV_ERR_INVALID_ARGUMENT;
     }
 
-    *pNumPages = at->num_pages;
+    *pNumPages = page_count;
 
     return NV_OK;
 }
@@ -3897,16 +3925,16 @@
     nv_alloc_t *at = pAllocPrivate;
     struct page **pages = (struct page **)pPages;
     NvU32 page_count;
-    int i;
+    NvU32 i;
 
     if (!pNumPages || !pPages) {
         return NV_ERR_INVALID_ARGUMENT;
     }
 
-    page_count = NV_MIN(*pNumPages, at->num_pages);
+    page_count = NV_MIN(*pNumPages, (NvU64)at->num_pages << at->compound_order);
 
     for (i = 0; i < page_count; i++) {
-        pages[i] = NV_GET_PAGE_STRUCT(at->page_table[i].phys_addr);
+        pages[i] = NV_GET_PAGE_STRUCT(nv_alloc_page_address(at, i));
     }
 
     *pNumPages = page_count;
@@ -3938,6 +3966,11 @@
     NvUPtr virt_addr;
     struct page **pages;
     NvBool isUserAllocatedMem;
+    NvU64 num_pages = (NvU64)at->num_pages << at->compound_order;
+
+    if (pageIndex >= num_pages || pageOffset >= PAGE_SIZE ||
+        size > ((num_pages - pageIndex) << PAGE_SHIFT) - pageOffset)
+        return NULL;
 
     //
     // For User allocated memory (like ErrorNotifier's) which is NOT allocated
@@ -3947,8 +3980,8 @@
     // those pages to obtain virtual address.
     //
     isUserAllocatedMem = at->flags.user &&
-                        !at->page_table[pageIndex].virt_addr &&
-                         at->page_table[pageIndex].phys_addr;
+                        !at->page_table[pageIndex >> at->compound_order].virt_addr &&
+                         at->page_table[pageIndex >> at->compound_order].phys_addr;
 
     //
     // User memory may NOT have kernel VA. So check this and fallback to else
@@ -3984,7 +4017,7 @@
             }
 
             for (j = 0; j < page_count; j++)
-                pages[j] = NV_GET_PAGE_STRUCT(at->page_table[pageIndex+j].phys_addr);
+                pages[j] = NV_GET_PAGE_STRUCT(nv_alloc_page_address(at, pageIndex + j));
 
             virt_addr = nv_vm_map_pages(pages, page_count,
                 at->cache_type == NV_MEMORY_CACHED, at->flags.unencrypted);
diff -ruN a/kernel-open/nvidia/nv-dma.c b/kernel-open/nvidia/nv-dma.c
--- a/kernel-open/nvidia/nv-dma.c
+++ b/kernel-open/nvidia/nv-dma.c
@@ -82,9 +82,10 @@
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
@@ -95,12 +96,13 @@
 
     dma_map->mapping.contig.dma_addr = *va;
 
-    if (!nv_dma_is_addressable(dma_dev, *va, dma_map->page_count * PAGE_SIZE))
+    if ((*va & (dma_map->page_granularity - 1)) != 0 ||
+        !nv_dma_is_addressable(dma_dev, *va, mapping_size))
     {
         NV_DMA_DEV_PRINTF(NV_DBG_ERRORS, dma_dev,
                 "DMA address not in addressable range of device "
                 "(0x%llx-0x%llx, 0x%llx-0x%llx)\n",
-                *va, *va + (dma_map->page_count * PAGE_SIZE - 1),
+                *va, *va + (mapping_size - 1),
                 dma_dev->addressable_range.start,
                 dma_dev->addressable_range.limit);
         nv_dma_unmap_contig(dma_map);
@@ -113,9 +115,10 @@
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
@@ -158,13 +161,50 @@
     nv_dma_submap_t *submap;
     NvU32 i;
 
-#if defined(NV_SG_ALLOC_TABLE_FROM_PAGES_SEGMENT_PRESENT)
-    dma_map->mapping.discontig.submap_count = 1;
-#else
+#if !defined(NV_SG_ALLOC_TABLE_FROM_PAGES_SEGMENT_PRESENT)
     NvU64 allocated_size = 0;
     NvU64 num_submaps = dma_map->page_count + NV_DMA_SUBMAP_MAX_PAGES - 1;
     NvU64 total_size = dma_map->page_count << PAGE_SHIFT;
+#endif
+
+    /* sg_alloc_table_from_pages() expects base pages. */
+    if (dma_map->page_granularity > PAGE_SIZE)
+    {
+        int ret;
+
+        dma_map->mapping.discontig.submap_count = 1;
+
+        status = os_alloc_mem((void **)&dma_map->mapping.discontig.submaps,
+            sizeof(nv_dma_submap_t));
+        if (status != NV_OK)
+            return status;
+
+        os_mem_set(dma_map->mapping.discontig.submaps, 0, sizeof(nv_dma_submap_t));
+
+        submap = &dma_map->mapping.discontig.submaps[0];
+        submap->page_count = dma_map->page_count;
+
+        ret = sg_alloc_table(&submap->sgt, submap->page_count, NV_GFP_KERNEL);
+        if (ret != 0)
+        {
+            os_free_mem(dma_map->mapping.discontig.submaps);
+            return NV_ERR_OPERATING_SYSTEM;
+        }
+
+        {
+            struct scatterlist *sg;
+            unsigned int j;
+
+            for_each_sg(submap->sgt.sgl, sg, submap->page_count, j)
+                sg_set_page(sg, dma_map->pages[j], dma_map->page_granularity, 0);
+        }
+
+        return NV_OK;
+    }
 
+#if defined(NV_SG_ALLOC_TABLE_FROM_PAGES_SEGMENT_PRESENT)
+    dma_map->mapping.discontig.submap_count = 1;
+#else
     /*
      * This turns into 64-bit division, which the ARMv7 kernel doesn't provide
      * implicitly. Instead, we need to use the platform's do_div() to perform
@@ -319,7 +359,7 @@
     os_free_mem(dma_map->mapping.discontig.submaps);
 }
 
-static void nv_load_dma_map_scatterlist(
+static NV_STATUS nv_load_dma_map_scatterlist(
     nv_dma_map_t *dma_map,
     NvU64 *va_array
 )
@@ -327,25 +367,31 @@
     unsigned int i, j;
     struct scatterlist *sg;
     nv_dma_submap_t *submap;
-    NvU64 sg_addr, sg_off, sg_len, k, l = 0;
+    NvU64 l = 0;
 
     NV_FOR_EACH_DMA_SUBMAP(dma_map, submap, i)
     {
         for_each_sg(submap->sgt.sgl, sg, submap->sg_map_count, j)
         {
-            /*
-             * It is possible for pci_map_sg() to merge scatterlist entries, so
-             * make sure we account for that here.
-             */
-            for (sg_addr = sg_dma_address(sg), sg_len = sg_dma_len(sg),
-                    sg_off = 0, k = 0;
-                 (sg_off < sg_len) && (k < submap->page_count);
-                 sg_off += PAGE_SIZE, l++, k++)
+            NvU64 sg_addr = sg_dma_address(sg);
+            NvU64 sg_len = sg_dma_len(sg);
+            NvU64 sg_off;
+
+            if ((sg_addr & (dma_map->page_granularity - 1)) != 0 ||
+                sg_len % dma_map->page_granularity != 0 ||
+                sg_len / dma_map->page_granularity > dma_map->page_count - l)
+                return NV_ERR_INVALID_ADDRESS;
+
+            /* DMA mapping may merge adjacent entries. */
+            for (sg_off = 0; sg_off < sg_len;
+                 sg_off += dma_map->page_granularity, l++)
             {
                 va_array[l] = sg_addr + sg_off;
             }
         }
     }
+
+    return l == dma_map->page_count ? NV_OK : NV_ERR_INVALID_ADDRESS;
 }
 
 static NV_STATUS nv_dma_map_scatterlist(
@@ -374,11 +420,16 @@
         return status;
     }
 
-    nv_load_dma_map_scatterlist(dma_map, va_array);
+    status = nv_load_dma_map_scatterlist(dma_map, va_array);
+    if (status != NV_OK)
+    {
+        nv_dma_unmap_scatterlist(dma_map);
+        return status;
+    }
 
     for (i = 0; i < dma_map->page_count; i++)
     {
-        if (!nv_dma_is_addressable(dma_dev, va_array[i], PAGE_SIZE))
+        if (!nv_dma_is_addressable(dma_dev, va_array[i], dma_map->page_granularity))
         {
             NV_DMA_DEV_PRINTF(NV_DBG_ERRORS, dma_dev,
                     "DMA address not in addressable range of device "
@@ -438,6 +489,7 @@
     dma_map->contiguous = NV_FALSE;
     dma_map->cache_type = cache_type;
     dma_map->bReadOnlyDeviceMap = bReadOnlyDeviceMap;
+    dma_map->page_granularity = PAGE_SIZE;
 
     dma_map->mapping.discontig.submap_count = 0;
     status = nv_dma_map_scatterlist(dma_dev, dma_map, va_array);
@@ -483,6 +535,7 @@
     NvU64           *va_array,
     NvBool           contig,
     NvU32            cache_type,
+    NvU64            page_granularity,
     NvBool           bReadOnlyDeviceMap,
     void           **priv
 )
@@ -521,6 +574,7 @@
     dma_map->contiguous = contig;
     dma_map->cache_type = cache_type;
     dma_map->bReadOnlyDeviceMap = bReadOnlyDeviceMap;
+    dma_map->page_granularity = page_granularity;
 
     if (dma_map->page_count > 1 && !dma_map->contiguous)
     {
@@ -685,8 +739,17 @@
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
+                                  cache_type, page_granularity,
+                                  bReadOnlyDeviceMap, priv);
+    }
     if (status != NV_OK)
     {
         *priv = at;
@@ -908,7 +971,7 @@
     {
         dma_sync_single_for_device(dma_dev->dev,
                                    dma_map->mapping.contig.dma_addr,
-                                   (size_t) PAGE_SIZE * dma_map->page_count,
+                                   (size_t) dma_map->page_granularity * dma_map->page_count,
                                    DMA_FROM_DEVICE);
     }
     else
diff -ruN a/kernel-open/nvidia/nv-mmap.c b/kernel-open/nvidia/nv-mmap.c
--- a/kernel-open/nvidia/nv-mmap.c
+++ b/kernel-open/nvidia/nv-mmap.c
@@ -171,14 +171,19 @@
             goto done;
         }
 
-        if (pageIndex >= at->num_pages)
+        if ((pageIndex >> at->compound_order) >= at->num_pages)
         {
             ret = -EINVAL;
             goto done;
         }
 
-        pageIndex = nv_array_index_no_speculate(pageIndex, at->num_pages);
-        kernel_mapping = (void *)(at->page_table[pageIndex].virt_addr + pageOffset);
+        pageIndex = nv_array_index_no_speculate(pageIndex,
+                                               (NvU64)at->num_pages << at->compound_order);
+        if (at->compound_order != 0)
+            kernel_mapping = (NvU8 *)page_address(NV_GET_PAGE_STRUCT(
+                                 nv_alloc_page_address(at, pageIndex))) + pageOffset;
+        else
+            kernel_mapping = (void *)(at->page_table[pageIndex].virt_addr + pageOffset);
     }
     else if (has_pages)
     {
@@ -472,7 +477,7 @@
                 vma->vm_page_prot = nv_adjust_pgprot(vma->vm_page_prot);
 
             ret = vm_insert_page(vma, start,
-                                 NV_GET_PAGE_STRUCT(at->page_table[j].phys_addr));
+                                 NV_GET_PAGE_STRUCT(nv_alloc_page_address(at, j)));
         }
 
         if (ret)
@@ -681,7 +686,8 @@
         mmap_size = NV_VMA_SIZE(vma);
         pages = mmap_size >> PAGE_SHIFT;
 
-        if ((page_index + pages) > at->num_pages)
+        if (page_index > ((NvU64)at->num_pages << at->compound_order) ||
+            pages > ((NvU64)at->num_pages << at->compound_order) - page_index)
         {
             ret = -ERANGE;
             goto done;
diff -ruN a/kernel-open/nvidia/nv-reg.h b/kernel-open/nvidia/nv-reg.h
--- a/kernel-open/nvidia/nv-reg.h
+++ b/kernel-open/nvidia/nv-reg.h
@@ -1076,7 +1076,7 @@
 NV_DEFINE_REG_ENTRY_GLOBAL(__NV_ENABLE_PCIE_RELAXED_ORDERING_MODE, 0);
 NV_DEFINE_REG_ENTRY_GLOBAL(__NV_REGISTER_PCI_DRIVER, 1);
 NV_DEFINE_REG_ENTRY_GLOBAL(__NV_REGISTER_PLATFORM_DEVICE_DRIVER, 1);
-NV_DEFINE_REG_ENTRY_GLOBAL(__NV_ENABLE_RESIZABLE_BAR, 0);
+NV_DEFINE_REG_ENTRY_GLOBAL(__NV_ENABLE_RESIZABLE_BAR, 1);
 NV_DEFINE_REG_ENTRY_GLOBAL(__NV_ENABLE_DBG_BREAKPOINT, 0);
 NV_DEFINE_REG_ENTRY_GLOBAL(__NV_TEGRA_GPU_PG_MASK, ~0);
 NV_DEFINE_REG_ENTRY_GLOBAL(__NV_ENABLE_NONBLOCKING_OPEN, 1);
diff -ruN a/kernel-open/nvidia/nv-usermap.c b/kernel-open/nvidia/nv-usermap.c
--- a/kernel-open/nvidia/nv-usermap.c
+++ b/kernel-open/nvidia/nv-usermap.c
@@ -141,10 +141,13 @@
 {
     nv_alloc_t *at = pAllocPrivate;
 
+    if ((pageIndex >> at->compound_order) >= at->num_pages)
+        return NV_ERR_INVALID_ARGUMENT;
+
     if (at->flags.contig)
         *pUserAddress = (at->page_table[0].phys_addr + (pageIndex * PAGE_SIZE) + pageOffset);
     else
-        *pUserAddress = (at->page_table[pageIndex].phys_addr + pageOffset);
+        *pUserAddress = nv_alloc_page_address(at, pageIndex) + pageOffset;
 
     return NV_OK;
 }
diff -ruN a/kernel-open/nvidia/os-mlock.c b/kernel-open/nvidia/os-mlock.c
--- a/kernel-open/nvidia/os-mlock.c
+++ b/kernel-open/nvidia/os-mlock.c
@@ -25,6 +25,7 @@
 
 #include "os-interface.h"
 #include "nv-linux.h"
+#include <linux/hugetlb.h>
 
 #if defined(NVCPU_FAMILY_X86) && defined(NV_FOLL_LONGTERM_PRESENT) && \
     (defined(NV_PIN_USER_PAGES_HAS_ARGS_VMAS) ||                      \
@@ -213,6 +214,86 @@
     return rmStatus;
 }
 
+/* Stored immediately before the returned page array. */
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
+static NvBool nv_hugetlb_fast_path_eligible(
+    struct vm_area_struct *vma,
+    unsigned long start,
+    NvU64 page_count,
+    unsigned long *hpage_size_out,
+    unsigned int *compound_order_out
+)
+{
+    NvU64 range_size;
+    unsigned long end;
+    unsigned long hpage_size;
+
+    if (!vma || start < vma->vm_start ||
+        !is_vm_hugetlb_page(vma) || page_count == 0)
+        return NV_FALSE;
+
+    if (page_count > ((NvU64)ULONG_MAX / PAGE_SIZE))
+        return NV_FALSE;
+
+    range_size = page_count * PAGE_SIZE;
+    if (start > ULONG_MAX - range_size)
+        return NV_FALSE;
+
+    end = start + range_size;
+    hpage_size = huge_page_size(hstate_vma(vma));
+
+    if (hpage_size <= PAGE_SIZE || hpage_size > NV_U32_MAX ||
+        (start & (hpage_size - 1)) != 0 ||
+        (range_size & (hpage_size - 1)) != 0 ||
+        end > vma->vm_end)
+    {
+        return NV_FALSE;
+    }
+
+    *hpage_size_out = hpage_size;
+    *compound_order_out = ilog2(hpage_size / PAGE_SIZE);
+    return NV_TRUE;
+}
+
 NV_STATUS NV_API_CALL os_lock_user_pages(
     void   *address,
     NvU64   page_count,
@@ -223,8 +304,7 @@
     NV_STATUS rmStatus;
     struct mm_struct *mm = current->mm;
     struct page **user_pages;
-    NvU64 i;
-    NvU64 npages = page_count;
+    NvU64 i, j;
     NvU64 pinned = 0;
     unsigned int gup_flags = DRF_VAL(_LOCK_USER_PAGES, _FLAGS, _WRITE, flags) ? FOLL_WRITE : 0;
     long ret;
@@ -240,18 +320,66 @@
         return NV_ERR_NOT_SUPPORTED;
     }
 
-    rmStatus = os_alloc_mem((void **)&user_pages,
-            (page_count * sizeof(*user_pages)));
+    nv_mmap_read_lock(mm);
+
+    /* One pin holds the entire hugetlb page. */
+    {
+        unsigned long start = (unsigned long)address;
+        struct vm_area_struct *vma = find_vma(mm, start);
+        unsigned long hpage_size;
+        unsigned int order;
+
+        if (nv_hugetlb_fast_path_eligible(vma,
+                                          start,
+                                          page_count,
+                                          &hpage_size,
+                                          &order))
+        {
+            NvU64 num_hugepages = page_count >> order;
+
+            rmStatus = nv_alloc_page_array(num_hugepages, order, &user_pages);
+            if (rmStatus != NV_OK)
+            {
+                nv_mmap_read_unlock(mm);
+                nv_printf(NV_DBG_ERRORS,
+                        "NVRM: failed to allocate hugepage table!\n");
+                return rmStatus;
+            }
+
+            for (i = 0; i < num_hugepages; i++)
+            {
+                ret = NV_PIN_USER_PAGES(start + i * hpage_size,
+                                        1,
+                                        gup_flags,
+                                        &user_pages[i]);
+                if (ret != 1)
+                {
+                    for (j = 0; j < i; j++)
+                        NV_UNPIN_USER_PAGE(user_pages[j]);
+                    nv_free_page_array(user_pages);
+                    nv_mmap_read_unlock(mm);
+                    return NV_ERR_INVALID_ADDRESS;
+                }
+            }
+
+            nv_mmap_read_unlock(mm);
+
+            *page_array = user_pages;
+            return NV_OK;
+        }
+    }
+
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
@@ -276,6 +404,8 @@
     else if ((ret == -ENOMEM) &&
              (page_count > NV_NUM_PIN_PAGES_PER_ITERATION))
     {
+        NvU64 npages;
+
         for (pinned = 0; pinned < page_count; pinned += ret)
         {
             npages = page_count - pinned;
@@ -299,7 +429,7 @@
     {
         for (i = 0; i < pinned; i++)
             NV_UNPIN_USER_PAGE(user_pages[i]);
-        os_free_mem(user_pages);
+        nv_free_page_array(user_pages);
         return NV_ERR_INVALID_ADDRESS;
     }
 
@@ -316,16 +446,19 @@
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
diff -ruN a/kernel-open/nvidia-uvm/uvm_devmem.c b/kernel-open/nvidia-uvm/uvm_devmem.c
--- a/kernel-open/nvidia-uvm/uvm_devmem.c
+++ b/kernel-open/nvidia-uvm/uvm_devmem.c
@@ -620,6 +620,18 @@
 
     parent_gpu->device_p2p_initialised = false;
 
+    if (parent_gpu->rm_info.gpuArch >= NV2080_CTRL_MC_ARCH_INFO_ARCHITECTURE_GB100) {
+        // Static BAR1 is also the GPU peer aperture on non-coherent Blackwell.
+        // Registering it as P2PDMA memory would replace its pagemap operations
+        // and conflict with the BAR1-as-sysmem PTEs used for GPU peer access.
+        UVM_DBG_PRINT("Skipping PCI P2PDMA static BAR1 registration on non-coherent GPU %s "
+                      "(size 0x%llx, write-combined %u)\n",
+                      uvm_parent_gpu_name(parent_gpu),
+                      parent_gpu->static_bar1_size,
+                      parent_gpu->static_bar1_write_combined);
+        return;
+    }
+
     // RM sets static_bar1_size when it has created a contiguous BAR mapping
     // large enough to cover all of GPU memory that will be allocated to
     // userspace buffers. This is required to support the P2PDMA feature to
diff -ruN a/src/nvidia/arch/nvalloc/unix/include/nv.h b/src/nvidia/arch/nvalloc/unix/include/nv.h
--- a/src/nvidia/arch/nvalloc/unix/include/nv.h
+++ b/src/nvidia/arch/nvalloc/unix/include/nv.h
@@ -977,6 +977,8 @@
 
 NV_STATUS  NV_API_CALL  nv_register_user_pages   (nv_state_t *, NvU64, NvU64 *, void *, void **, NvBool);
 void       NV_API_CALL  nv_unregister_user_pages (nv_state_t *, NvU64, void **, void **);
+NvU32      NV_API_CALL  nv_get_compound_order    (void *);
+NvU32      NV_API_CALL  nv_get_page_array_compound_order(void *);
 
 NV_STATUS NV_API_CALL   nv_register_peer_io_mem  (nv_state_t *, NvU64 *, NvU64, void **);
 void      NV_API_CALL   nv_unregister_peer_io_mem(nv_state_t *, void *);
diff -ruN a/src/nvidia/arch/nvalloc/unix/include/nv-reg.h b/src/nvidia/arch/nvalloc/unix/include/nv-reg.h
--- a/src/nvidia/arch/nvalloc/unix/include/nv-reg.h
+++ b/src/nvidia/arch/nvalloc/unix/include/nv-reg.h
@@ -1076,7 +1076,7 @@
 NV_DEFINE_REG_ENTRY_GLOBAL(__NV_ENABLE_PCIE_RELAXED_ORDERING_MODE, 0);
 NV_DEFINE_REG_ENTRY_GLOBAL(__NV_REGISTER_PCI_DRIVER, 1);
 NV_DEFINE_REG_ENTRY_GLOBAL(__NV_REGISTER_PLATFORM_DEVICE_DRIVER, 1);
-NV_DEFINE_REG_ENTRY_GLOBAL(__NV_ENABLE_RESIZABLE_BAR, 0);
+NV_DEFINE_REG_ENTRY_GLOBAL(__NV_ENABLE_RESIZABLE_BAR, 1);
 NV_DEFINE_REG_ENTRY_GLOBAL(__NV_ENABLE_DBG_BREAKPOINT, 0);
 NV_DEFINE_REG_ENTRY_GLOBAL(__NV_TEGRA_GPU_PG_MASK, ~0);
 NV_DEFINE_REG_ENTRY_GLOBAL(__NV_ENABLE_NONBLOCKING_OPEN, 1);
diff -ruN a/src/nvidia/arch/nvalloc/unix/src/osapi.c b/src/nvidia/arch/nvalloc/unix/src/osapi.c
--- a/src/nvidia/arch/nvalloc/unix/src/osapi.c
+++ b/src/nvidia/arch/nvalloc/unix/src/osapi.c
@@ -2377,7 +2377,15 @@
         return status;
     }
 
-    if (!nvuap->contig)
+    if (!nvuap->contig &&
+        memdescGetFlag(pMemDesc, MEMDESC_FLAGS_EXT_PAGE_ARRAY_MEM) &&
+        pMemDesc->pageArrayGranularity > NV_RM_PAGE_SIZE)
+    {
+        pages = nvuap->memArea.pRanges[0].size / os_page_size;
+        memdescGetPhysAddrs(pMemDesc, AT_CPU, nvuap->offset,
+                           os_page_size, pages, nvuap->page_array);
+    }
+    else if (!nvuap->contig)
     {
         pteArray = memdescGetPteArray(pMemDesc, AT_CPU);
         if (IS_DISCONTIG_AND_DYNGRAN_ENABLED(pMemDesc))
diff -ruN a/src/nvidia/arch/nvalloc/unix/src/os.c b/src/nvidia/arch/nvalloc/unix/src/os.c
--- a/src/nvidia/arch/nvalloc/unix/src/os.c
+++ b/src/nvidia/arch/nvalloc/unix/src/os.c
@@ -3830,6 +3830,7 @@
     NvBool bIsContig;
     NV_ADDRESS_SPACE addressSpace;
     NvU32 osPageCount;
+    NvBool bHugePages;
 
     if (pIovaMapping == NULL)
     {
@@ -3875,7 +3876,13 @@
     }
 
     nv = NV_GET_NV_STATE(pGpu);
-    if (IS_DISCONTIG_AND_DYNGRAN_ENABLED(pIovaMapping->pPhysMemDesc))
+    bHugePages = memdescGetFlag(pIovaMapping->pPhysMemDesc, MEMDESC_FLAGS_EXT_PAGE_ARRAY_MEM) &&
+                pIovaMapping->pPhysMemDesc->pageArrayGranularity > os_page_size;
+    if (bHugePages)
+    {
+        osPageCount = pIovaMapping->pPhysMemDesc->PageCount;
+    }
+    else if (IS_DISCONTIG_AND_DYNGRAN_ENABLED(pIovaMapping->pPhysMemDesc))
     {
         osPageCount = pIovaMapping->pPhysMemDesc->PageCount;
         NV_ASSERT_OR_RETURN(os_page_size == pIovaMapping->pPhysMemDesc->pageArrayGranularity, NV_ERR_INVALID_PARAMETER);
@@ -3916,11 +3923,11 @@
     //
     peer = NV_GET_NV_STATE(pRootMemDesc->pGpu);
     bIsContig = memdescGetContiguity(pIovaMapping->pPhysMemDesc, AT_CPU);
-    if (IS_DISCONTIG_AND_DYNGRAN_ENABLED(pIovaMapping->pPhysMemDesc))
+    if (!bHugePages && IS_DISCONTIG_AND_DYNGRAN_ENABLED(pIovaMapping->pPhysMemDesc))
     {
         NV_ASSERT_OR_RETURN(pIovaMapping->pPhysMemDesc->pageArrayGranularity == os_page_size, NV_ERR_INVALID_ARGUMENT);
     }
-    else if (NV_RM_PAGE_SIZE < os_page_size && !bIsContig)
+    else if (!bHugePages && NV_RM_PAGE_SIZE < os_page_size && !bIsContig)
     {
         RmDeflateRmToOsPageArray(&pIovaMapping->iovaArray[0],
                                 pIovaMapping->pPhysMemDesc->PageCount);
@@ -4013,11 +4020,11 @@
     // If the OS layer doesn't think in RM page size, we need to inflate the
     // PTE array into RM pages.
     //
-    if (IS_DISCONTIG_AND_DYNGRAN_ENABLED(pIovaMapping->pPhysMemDesc))
+    if (!bHugePages && IS_DISCONTIG_AND_DYNGRAN_ENABLED(pIovaMapping->pPhysMemDesc))
     {
         NV_ASSERT_OR_RETURN(pIovaMapping->pPhysMemDesc->pageArrayGranularity == os_page_size, NV_ERR_INVALID_ARGUMENT);
     }
-    else if (NV_RM_PAGE_SIZE < os_page_size && !bIsContig)
+    else if (!bHugePages && NV_RM_PAGE_SIZE < os_page_size && !bIsContig)
     {
         RmInflateOsToRmPageArray(&pIovaMapping->iovaArray[0],
                                 pIovaMapping->pPhysMemDesc->PageCount);
@@ -4045,6 +4052,7 @@
     void *pPriv;
     NV_STATUS status;
     NvU64 osPageCount;
+    NvBool bHugePages;
 
     if (pIovaMapping == NULL)
     {
@@ -4073,7 +4081,13 @@
     {
         return;
     }
-    if (IS_DISCONTIG_AND_DYNGRAN_ENABLED(pIovaMapping->pPhysMemDesc))
+    bHugePages = memdescGetFlag(pIovaMapping->pPhysMemDesc, MEMDESC_FLAGS_EXT_PAGE_ARRAY_MEM) &&
+                pIovaMapping->pPhysMemDesc->pageArrayGranularity > os_page_size;
+    if (bHugePages)
+    {
+        osPageCount = pIovaMapping->pPhysMemDesc->PageCount;
+    }
+    else if (IS_DISCONTIG_AND_DYNGRAN_ENABLED(pIovaMapping->pPhysMemDesc))
     {
         osPageCount = pIovaMapping->pPhysMemDesc->PageCount;
         NV_ASSERT(os_page_size == pIovaMapping->pPhysMemDesc->pageArrayGranularity);
@@ -4098,11 +4112,11 @@
     //
     pPriv = (void *)pIovaMapping->pOsData;
 
-    if (IS_DISCONTIG_AND_DYNGRAN_ENABLED(pIovaMapping->pPhysMemDesc))
+    if (!bHugePages && IS_DISCONTIG_AND_DYNGRAN_ENABLED(pIovaMapping->pPhysMemDesc))
     {
         NV_ASSERT(pIovaMapping->pPhysMemDesc->pageArrayGranularity == os_page_size);
     }
-    else if (NV_RM_PAGE_SIZE < os_page_size &&
+    else if (!bHugePages && NV_RM_PAGE_SIZE < os_page_size &&
             !memdescGetContiguity(pIovaMapping->pPhysMemDesc, AT_CPU))
     {
         RmDeflateRmToOsPageArray(&pIovaMapping->iovaArray[0],
@@ -4132,11 +4146,11 @@
     // If the OS layer doesn't think in RM page size, we need to fluff out the
     // PTE array into RM pages.
     //
-    if (IS_DISCONTIG_AND_DYNGRAN_ENABLED(pIovaMapping->pPhysMemDesc))
+    if (!bHugePages && IS_DISCONTIG_AND_DYNGRAN_ENABLED(pIovaMapping->pPhysMemDesc))
     {
         NV_ASSERT(pIovaMapping->pPhysMemDesc->pageArrayGranularity == os_page_size);
     }
-    else if (NV_RM_PAGE_SIZE < os_page_size &&
+    else if (!bHugePages && NV_RM_PAGE_SIZE < os_page_size &&
             !memdescGetContiguity(pIovaMapping->pPhysMemDesc, AT_CPU))
     {
         RmInflateOsToRmPageArray(&pIovaMapping->iovaArray[0],
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
@@ -201,6 +203,20 @@
 
     osPageCount = size >> os_page_shift;
 
+    // Size the PTE array by hugepage count.
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
@@ -223,7 +239,7 @@
         memdescFlags |= MEMDESC_FLAGS_DEVICE_READ_ONLY;
     }
 
-    rmStatus = memdescCreate(ppMemDesc, pGpu, size, 0,
+    rmStatus = memdescCreate(ppMemDesc, pGpu, memdescSize, 0,
                              NV_MEMORY_NONCONTIGUOUS, ADDR_SYSMEM,
                              cacheType, memdescFlags);
     if (rmStatus != NV_OK)
@@ -231,12 +247,19 @@
         return rmStatus;
     }
 
+    pMemDesc = *ppMemDesc;
+
+    // Restore the buffer size.
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
@@ -251,7 +274,18 @@
     memdescSetFlag(pMemDesc, MEMDESC_FLAGS_KERNEL_MODE, NV_FALSE);
     memdescSetFlag(pMemDesc, MEMDESC_FLAGS_EXT_PAGE_ARRAY_MEM, NV_TRUE);
 
-    if (IS_DISCONTIG_AND_DYNGRAN_ENABLED(pMemDesc))
+    if (compoundOrder > 0)
+    {
+        NvU64 hugepageGranularity = (NvU64)os_page_size << compoundOrder;
+
+        NV_ASSERT_OK_OR_GOTO(rmStatus,
+            memdescSetAllocSizeFields(pMemDesc, size, (NvU32)hugepageGranularity),
+            cleanup);
+
+        // UVM selects a supported GPU page size.
+        memdescSetPageSize(pMemDesc, AT_GPU, hugepageGranularity);
+    }
+    else if (IS_DISCONTIG_AND_DYNGRAN_ENABLED(pMemDesc))
     {
         NV_ASSERT_OR_GOTO((os_page_size & (pMemDesc->pageArrayGranularity - 1ULL)) == 0, cleanup);
         NV_ASSERT_OK_OR_GOTO(rmStatus, memdescSetAllocSizeFields(pMemDesc, size, os_page_size), cleanup);
@@ -268,11 +302,12 @@
     }
 
 
-    //
-    // If the OS layer doesn't think in RM page size, we need to inflate the
-    // PTE array into RM pages.
-    //
-    if (IS_DISCONTIG_AND_DYNGRAN_ENABLED(pMemDesc))
+    // Inflate base-page arrays to RM pages.
+    if (compoundOrder > 0)
+    {
+        // No conversion needed.
+    }
+    else if (IS_DISCONTIG_AND_DYNGRAN_ENABLED(pMemDesc))
     {
         // Because os_page_size == pMemDesc->pageArrayGranularity, we don't need to do any page array conversion.
         NV_ASSERT_OR_ELSE(os_page_size == pMemDesc->pageArrayGranularity, rmStatus = NV_ERR_INVALID_ARGUMENT; goto cleanup);
@@ -294,10 +329,15 @@
     memdescSetMemData(pMemDesc, *ppPrivate, NULL);
 
     rmStatus = memdescMapIommu(pMemDesc, pGpu->busInfo.iovaspaceId);
+
 cleanup:
     if (rmStatus != NV_OK)
     {
-        if (IS_DISCONTIG_AND_DYNGRAN_ENABLED(pMemDesc))
+        if (compoundOrder > 0)
+        {
+            // No conversion needed.
+        }
+        else if (IS_DISCONTIG_AND_DYNGRAN_ENABLED(pMemDesc))
         {
             // Because os_page_size == pMemDesc->pageArrayGranularity, we don't need to do any page array conversion.
             NV_ASSERT(os_page_size == pMemDesc->pageArrayGranularity);
@@ -1187,15 +1227,23 @@
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
 
+    compoundOrder = nv_get_compound_order(pPrivate);
+
+    if (compoundOrder > 0 || IS_DISCONTIG_AND_DYNGRAN_ENABLED(pMemDesc))
+        osPageCount = pMemDesc->PageCount;
+    else
+        osPageCount = NV_RM_PAGES_TO_OS_PAGES(pMemDesc->PageCount);
+
     //
     // TODO: Bug 1811006: Notably skip any IOMMU mapping management as the
     // pMemDesc->pGpu might have been torn down already and the pGpu passed in
@@ -1205,21 +1253,21 @@
     // be cleaned up once the fix for bug 1811006 is known.
     //
 
-    if (IS_DISCONTIG_AND_DYNGRAN_ENABLED(pMemDesc))
+    // Deflate base-page arrays to OS pages.
+    if (compoundOrder > 0)
+    {
+        // No conversion needed.
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
@@ -1231,12 +1279,6 @@
     }
     else
     {
-        //
-        // We use MEMDESC_FLAGS_USER_READ_ONLY because this reflects the
-        // NVOS02_FLAGS_ALLOC_USER_READ_ONLY flag value passed into
-        // os_lock_user_pages(). That flag also results in
-        // MEMDESC_FLAGS_DEVICE_READ_ONLY being set.
-        //
         NvBool writable = !memdescGetFlag(pMemDesc, MEMDESC_FLAGS_USER_READ_ONLY);
         NvU32 flags = DRF_NUM(_LOCK_USER_PAGES, _FLAGS, _WRITE, writable);
         status = os_unlock_user_pages(osPageCount, pPrivate, flags);
diff -ruN a/src/nvidia/generated/g_kern_bus_nvoc.c b/src/nvidia/generated/g_kern_bus_nvoc.c
--- a/src/nvidia/generated/g_kern_bus_nvoc.c
+++ b/src/nvidia/generated/g_kern_bus_nvoc.c
@@ -340,7 +340,8 @@
     }
 
     // NVOC Property Hal field -- PDB_PROP_KBUS_SUPPORT_BAR1_P2P_BY_DEFAULT
-    if (( ((chipHal_HalVarIdx >> 5) == 2UL) && ((1UL << (chipHal_HalVarIdx & 0x1f)) & 0x000030feUL) )) /* ChipHal: GB202 | GB203 | GB205 | GB206 | GB207 | GB20B | GB20C | GR100 | GR102 */ 
+    if (( ((chipHal_HalVarIdx >> 5) == 1UL) && ((1UL << (chipHal_HalVarIdx & 0x1f)) & 0x01f0fc00UL) ) ||
+        ( ((chipHal_HalVarIdx >> 5) == 2UL) && ((1UL << (chipHal_HalVarIdx & 0x1f)) & 0x000030feUL) )) /* ChipHal: GA100 | GA102 | GA103 | GA104 | GA106 | GA107 | AD102 | AD103 | AD104 | AD106 | AD107 | GB202 | GB203 | GB205 | GB206 | GB207 | GB20B | GB20C | GR100 | GR102 */
     {
         pThis->setProperty(pThis, PDB_PROP_KBUS_SUPPORT_BAR1_P2P_BY_DEFAULT, NV_TRUE);
     }
@@ -1079,7 +1080,7 @@
     // default
     else
     {
-        pThis->__kbusGetBar1P2PDmaInfo__ = &kbusGetBar1P2PDmaInfo_395e98;
+        pThis->__kbusGetBar1P2PDmaInfo__ = &kbusGetBar1P2PDmaInfo_GH100;
     }
 
     // kbusShouldRefcountConstruct -- halified (2 hals) body
@@ -1139,7 +1140,7 @@
     // default
     else
     {
-        pThis->__kbusCreateP2PMappingForBar1P2P__ = &kbusCreateP2PMappingForBar1P2P_395e98;
+        pThis->__kbusCreateP2PMappingForBar1P2P__ = &kbusCreateP2PMappingForBar1P2P_GH100;
     }
 
     // kbusRemoveP2PMappingForBar1P2P -- halified (2 hals) body
@@ -1151,7 +1152,7 @@
     // default
     else
     {
-        pThis->__kbusRemoveP2PMappingForBar1P2P__ = &kbusRemoveP2PMappingForBar1P2P_395e98;
+        pThis->__kbusRemoveP2PMappingForBar1P2P__ = &kbusRemoveP2PMappingForBar1P2P_GH100;
     }
 
     // kbusHasPcieBar1P2PMapping -- halified (2 hals) body
@@ -1163,7 +1164,7 @@
     // default
     else
     {
-        pThis->__kbusHasPcieBar1P2PMapping__ = &kbusHasPcieBar1P2PMapping_d69453;
+        pThis->__kbusHasPcieBar1P2PMapping__ = &kbusHasPcieBar1P2PMapping_GH100;
     }
 
     // kbusIsPcieBar1P2PMappingSupported -- halified (2 hals) body
@@ -1175,7 +1176,7 @@
     // default
     else
     {
-        pThis->__kbusIsPcieBar1P2PMappingSupported__ = &kbusIsPcieBar1P2PMappingSupported_d69453;
+        pThis->__kbusIsPcieBar1P2PMappingSupported__ = &kbusIsPcieBar1P2PMappingSupported_GH100;
     }
 
     // kbusCheckFlaSupportedAndInit -- halified (2 hals) body
@@ -2264,4 +2265,3 @@
 
     return __nvoc_objCreate_KernelBus((KernelBus **) __nvoc_ppThis, __nvoc_pParent, __nvoc_createFlags);
 }
-
diff -ruN a/src/nvidia/generated/g_virt_mem_allocator_nvoc.c b/src/nvidia/generated/g_virt_mem_allocator_nvoc.c
--- a/src/nvidia/generated/g_virt_mem_allocator_nvoc.c
+++ b/src/nvidia/generated/g_virt_mem_allocator_nvoc.c
@@ -331,8 +331,9 @@
     }
 
     // dmaAllocBar1P2PMapping -- halified (2 hals) body
-    if (( ((chipHal_HalVarIdx >> 5) == 1UL) && ((1UL << (chipHal_HalVarIdx & 0x1f)) & 0xfc000000UL) ) ||
-        ( ((chipHal_HalVarIdx >> 5) == 2UL) && ((1UL << (chipHal_HalVarIdx & 0x1f)) & 0x000030ffUL) )) /* ChipHal: GH100 | GB100 | GB102 | GB10B | GB10C | GB110 | GB112 | GB202 | GB203 | GB205 | GB206 | GB207 | GB20B | GB20C | GR100 | GR102 */ 
+    if (( ((chipHal_HalVarIdx >> 5) == 1UL) && ((1UL << (chipHal_HalVarIdx & 0x1f)) & 0x01f0fc00UL) ) ||
+        ( ((chipHal_HalVarIdx >> 5) == 1UL) && ((1UL << (chipHal_HalVarIdx & 0x1f)) & 0xfc000000UL) ) ||
+        ( ((chipHal_HalVarIdx >> 5) == 2UL) && ((1UL << (chipHal_HalVarIdx & 0x1f)) & 0x000030ffUL) )) /* ChipHal: GA100 | GA102 | GA103 | GA104 | GA106 | GA107 | AD102 | AD103 | AD104 | AD106 | AD107 | GH100 | GB100 | GB102 | GB10B | GB10C | GB110 | GB112 | GB202 | GB203 | GB205 | GB206 | GB207 | GB20B | GB20C | GR100 | GR102 */
     {
         pThis->__dmaAllocBar1P2PMapping__ = &dmaAllocBar1P2PMapping_GH100;
     }
@@ -343,8 +344,9 @@
     }
 
     // dmaFreeBar1P2PMapping -- halified (2 hals) body
-    if (( ((chipHal_HalVarIdx >> 5) == 1UL) && ((1UL << (chipHal_HalVarIdx & 0x1f)) & 0xfc000000UL) ) ||
-        ( ((chipHal_HalVarIdx >> 5) == 2UL) && ((1UL << (chipHal_HalVarIdx & 0x1f)) & 0x000030ffUL) )) /* ChipHal: GH100 | GB100 | GB102 | GB10B | GB10C | GB110 | GB112 | GB202 | GB203 | GB205 | GB206 | GB207 | GB20B | GB20C | GR100 | GR102 */ 
+    if (( ((chipHal_HalVarIdx >> 5) == 1UL) && ((1UL << (chipHal_HalVarIdx & 0x1f)) & 0x01f0fc00UL) ) ||
+        ( ((chipHal_HalVarIdx >> 5) == 1UL) && ((1UL << (chipHal_HalVarIdx & 0x1f)) & 0xfc000000UL) ) ||
+        ( ((chipHal_HalVarIdx >> 5) == 2UL) && ((1UL << (chipHal_HalVarIdx & 0x1f)) & 0x000030ffUL) )) /* ChipHal: GA100 | GA102 | GA103 | GA104 | GA106 | GA107 | AD102 | AD103 | AD104 | AD106 | AD107 | GH100 | GB100 | GB102 | GB10B | GB10C | GB110 | GB112 | GB202 | GB203 | GB205 | GB206 | GB207 | GB20B | GB20C | GR100 | GR102 */
     {
         pThis->__dmaFreeBar1P2PMapping__ = &dmaFreeBar1P2PMapping_GH100;
     }
@@ -529,4 +531,3 @@
 
     return __nvoc_objCreate_VirtMemAllocator((VirtMemAllocator **) __nvoc_ppThis, __nvoc_pParent, __nvoc_createFlags);
 }
-
diff -ruN a/src/nvidia/inc/kernel/rmapi/mapping_list.h b/src/nvidia/inc/kernel/rmapi/mapping_list.h
--- a/src/nvidia/inc/kernel/rmapi/mapping_list.h
+++ b/src/nvidia/inc/kernel/rmapi/mapping_list.h
@@ -66,6 +66,7 @@
     ADDRESS_TRANSLATION   addressTranslation;
     MEMORY_DESCRIPTOR    *pBar1P2PVirtMemDesc;              // The peer GPU mapped BAR1 region
     MEMORY_DESCRIPTOR    *pBar1P2PPhysMemDesc;              // The peer GPU vidmem sub region
+    NvU64                 bar1P2PApertureOffset;             // Offset of the dynamic peer mapping in BAR1
     CLI_DMA_MAPPING_INFO *pNext;
 };
 
diff -ruN a/src/nvidia/src/kernel/gpu/bif/kernel_bif.c b/src/nvidia/src/kernel/gpu/bif/kernel_bif.c
--- a/src/nvidia/src/kernel/gpu/bif/kernel_bif.c
+++ b/src/nvidia/src/kernel/gpu/bif/kernel_bif.c
@@ -1130,8 +1130,11 @@
 {
     NvU32 data32;
 
-    // P2P Override
-    pKernelBif->p2pOverride = BIF_P2P_NOT_OVERRIDEN;
+    // Enable BAR1 P2P reads and writes without overriding platform atomic capabilities.
+    pKernelBif->p2pOverride =
+        DRF_DEF(_REG_STR, _CL_FORCE_P2P, _READ, _ENABLE) |
+        DRF_DEF(_REG_STR, _CL_FORCE_P2P, _WRITE, _ENABLE) |
+        DRF_DEF(_REG_STR, _CL_FORCE_P2P, _ATOMICS, _DEFAULT);
     if (osReadRegistryDword(pGpu, NV_REG_STR_CL_FORCE_P2P, &data32) == NV_OK)
     {
         pKernelBif->p2pOverride = data32;
@@ -1147,7 +1150,7 @@
         pKernelBif->forceP2PType = data32;
     }
 
-    pKernelBif->pcieP2PType = NV_REG_STR_RM_PCIEP2P_TYPE_DEFAULT;
+    pKernelBif->pcieP2PType = NV_REG_STR_RM_PCIEP2P_TYPE_BAR1;
     if (osReadRegistryDword(pGpu, NV_REG_STR_RM_PCIEP2P_TYPE, &data32) == NV_OK)
     {
         pKernelBif->pcieP2PType = data32;
@@ -2072,4 +2075,3 @@
 
     return NV_ERR_GENERIC;
 }
-
diff -ruN a/src/nvidia/src/kernel/gpu/bus/arch/maxwell/kern_bus_gm107.c b/src/nvidia/src/kernel/gpu/bus/arch/maxwell/kern_bus_gm107.c
--- a/src/nvidia/src/kernel/gpu/bus/arch/maxwell/kern_bus_gm107.c
+++ b/src/nvidia/src/kernel/gpu/bus/arch/maxwell/kern_bus_gm107.c
@@ -879,6 +879,43 @@
            !kbusIsP2pMailboxClientAllocated(pKernelBus);
 }
 
+// Share BAR1 VA only; the console's physical reservation is unchanged.
+static NvBool
+_kbusCanShareConsoleWithStaticBar1_GM107
+(
+    OBJGPU *pGpu,
+    KernelBus *pKernelBus,
+    MEMORY_DESCRIPTOR *pConsoleMemDesc,
+    NvU32 gfid
+)
+{
+    KernelBif *pKernelBif = GPU_GET_KERNEL_BIF(pGpu);
+    NvU64 staticSize;
+
+    if (!RMCFG_FEATURE_PLATFORM_UNIX || !IS_GFID_PF(gfid) || IS_VIRTUAL(pGpu) ||
+        pKernelBif == NULL ||
+        pKernelBif->pcieP2PType != NV_REG_STR_RM_PCIEP2P_TYPE_BAR1 ||
+        kbusIsBar1PhysicalModeEnabled(pKernelBus) ||
+        pKernelBus->p2pPcie.writeMailboxTotalSize != 0 ||
+        memdescGetAddressSpace(pConsoleMemDesc) != ADDR_FBMEM ||
+        memdescGetPteKind(pConsoleMemDesc) != NV_MMU_PTE_KIND_PITCH ||
+        memdescGetPhysAddr(pConsoleMemDesc, AT_GPU, 0) != 0)
+    {
+        return NV_FALSE;
+    }
+
+    staticSize = RM_ALIGN_DOWN(
+        memmgrGetClientFbAddrSpaceSize(pGpu, GPU_GET_MEMORY_MANAGER(pGpu)),
+        RM_PAGE_SIZE_2M);
+    if (memdescGetSize(pConsoleMemDesc) == 0 ||
+        memdescGetSize(pConsoleMemDesc) > staticSize)
+    {
+        return NV_FALSE;
+    }
+
+    return kbusIsStaticBar1Supported_HAL(pGpu, pKernelBus, gfid, 0, 0) == NV_OK;
+}
+
 /*!
  * @brief Init BAR1.
  *
@@ -908,6 +945,7 @@
                                                    RMCFG_FEATURE_PLATFORM_WINDOWS);
     NvU64             consoleSize     = 0;
     NvBool            bStaticBar1Supported;
+    NvBool            bShareConsoleWithStaticBar1 = NV_FALSE;
 
     vaRangeMax = pKernelBus->bar1[gfid].apertureLength - 1;
 
@@ -1065,8 +1103,7 @@
     NV_ASSERT(pKernelBus->bar1[gfid].apertureLength <= kbusGetPciBarSize(pKernelBus, 1));
 
     //
-    // If we need to preserve a console mapping at the start of BAR1, we
-    // need to allocate the VA space before anything else gets allocated.
+    // Reserve console VA unless it can share the static mapping.
     //
     // This must come before enabling the static BAR1 mapping for the same reason
     // The consoleSize is also used for below kbusIsStaticBar1Supported_HAL check.
@@ -1102,6 +1139,14 @@
         {
             consoleSize = memdescGetSize(pConsoleMemDesc);
 
+            bShareConsoleWithStaticBar1 = !bSmoothTransitionEnabled &&
+                _kbusCanShareConsoleWithStaticBar1_GM107(pGpu, pKernelBus, pConsoleMemDesc, gfid);
+            if (bShareConsoleWithStaticBar1)
+            {
+                consoleSize = 0;
+                goto console_mapping_done;
+            }
+
             NV_PRINTF(LEVEL_INFO,
                         "preserving console BAR1 mapping (0x%llx)\n",
                         consoleSize);
@@ -1147,6 +1192,7 @@
         }
     }
 
+console_mapping_done:
     //
     // Reserve space for max number of peers for the mailbox p2p  regardless of SLI config
     //
@@ -1196,6 +1242,19 @@
         NV_ASSERT_OK_OR_GOTO(rmStatus,
                              kbusEnableStaticBar1Mapping_HAL(pGpu, pKernelBus, gfid, bar1Offset),
                              kbusInitBar1_failed);
+
+        if (bShareConsoleWithStaticBar1)
+        {
+            NV_ASSERT(bar1Offset == 0);
+            pKernelBus->bBar1ConsolePreserved = NV_TRUE;
+            NV_PRINTF(LEVEL_INFO, "Console shares static BAR1 identity mapping\n");
+        }
+    }
+    else if (bShareConsoleWithStaticBar1)
+    {
+        // Eligibility must not change after skipping the separate console map.
+        rmStatus = NV_ERR_INVALID_STATE;
+        goto kbusInitBar1_failed;
     }
 
     //
@@ -1268,6 +1327,14 @@
 {
     if (pKernelBus->bBar1ConsolePreserved && IS_GFID_PF(gfid))
     {
+        if (pKernelBus->bar1[gfid].bStaticBar1Enabled &&
+            pKernelBus->bar1[gfid].staticBar1.startOffset == 0)
+        {
+            // Static BAR1 owns this mapping.
+            pKernelBus->bBar1ConsolePreserved = NV_FALSE;
+            return;
+        }
+
         MemoryManager *pMemoryManager = GPU_GET_MEMORY_MANAGER(pGpu);
         PMEMORY_DESCRIPTOR pConsoleMemDesc =
             memmgrGetReservedConsoleMemDesc(pGpu, pMemoryManager);
diff -ruN a/src/nvidia/src/kernel/gpu/bus/arch/maxwell/kern_bus_gm200.c b/src/nvidia/src/kernel/gpu/bus/arch/maxwell/kern_bus_gm200.c
--- a/src/nvidia/src/kernel/gpu/bus/arch/maxwell/kern_bus_gm200.c
+++ b/src/nvidia/src/kernel/gpu/bus/arch/maxwell/kern_bus_gm200.c
@@ -198,6 +198,19 @@
     PMEMORY_DESCRIPTOR *ppWMBoxMemDesc
 )
 {
+    if (pKernelBus0->p2pPcie.writeMailboxBar1Addr ==
+        PCIE_P2P_INVALID_WRITE_MAILBOX_ADDR)
+    {
+        NV_PRINTF(LEVEL_ERROR,
+                  "PCIe mailbox P2P requested without an allocated mailbox area "
+                  "ownerGpu=%u accessorGpu=%u peer=%u writeMailboxBar1Addr=0x%llx\n",
+                  gpuGetInstance(pGpu0),
+                  gpuGetInstance(pGpu1),
+                  local2Remote,
+                  pKernelBus0->p2pPcie.writeMailboxBar1Addr);
+        return ~0ULL;
+    }
+
     return kbusSetupPeerBarAccess(pGpu0, pGpu1,
                 gpumgrGetGpuPhysFbAddr(pGpu0) +
                     pKernelBus0->p2pPcie.writeMailboxBar1Addr +
@@ -797,6 +810,15 @@
 
     if (!kbusIsP2pMailboxClientAllocated(pKernelBus))
     {
+        if (pKernelBus->p2pPcie.writeMailboxBar1Addr ==
+            PCIE_P2P_INVALID_WRITE_MAILBOX_ADDR)
+        {
+            NV_PRINTF(LEVEL_ERROR,
+                      "P2P mailbox area expected from RM but no valid address is installed gpu=%u\n",
+                      gpuGetInstance(pGpu));
+            return NV_ERR_INVALID_STATE;
+        }
+
         // P2P mailbox area already allocated by RM. Nothing to do.
         return NV_OK;
     }
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
diff -ruN a/src/nvidia/src/kernel/gpu/bus/arch/turing/kern_bus_tu102.c b/src/nvidia/src/kernel/gpu/bus/arch/turing/kern_bus_tu102.c
--- a/src/nvidia/src/kernel/gpu/bus/arch/turing/kern_bus_tu102.c
+++ b/src/nvidia/src/kernel/gpu/bus/arch/turing/kern_bus_tu102.c
@@ -377,23 +377,22 @@
     MemoryManager *pMemoryManager = GPU_GET_MEMORY_MANAGER(pGpu);
     KernelFifo *pKernelFifo = GPU_GET_KERNEL_FIFO(pGpu);
 
-    //
-    // Use fbAddrSpaceSizeMb in this function to make sure there's
-    // enough space for the any possible allocations in the RM
-    // reserved region to be mapped through the dynamic section of
-    // BAR1
-    //
     NvU64 fbSize            = pMemoryManager->Ram.fbAddrSpaceSizeMb << 20;
-    NvU64 fbSizeAligned     = RM_ALIGN_UP(fbSize, RM_PAGE_SIZE_2M);
+    NvU64 clientFbSizeAligned =
+        RM_ALIGN_DOWN(memmgrGetClientFbAddrSpaceSize(pGpu, pMemoryManager),
+                      RM_PAGE_SIZE_2M);
     NvU64 bar1VASize        = pKernelBus->bar1[gfid].mappableLength;
     NvU64 bar1VASizeAligned = RM_ALIGN_DOWN(bar1VASize, RM_PAGE_SIZE_2M);
+    NvU64 reservedSize;
+    NvU64 staticBar1Offset;
+    NvU64 maxStaticMapSize;
 
     if (gfid != 0)
     {
         return NV_ERR_NOT_SUPPORTED;
     }
 
-    if ((fbSize == 0) || (bar1Size == 0))
+    if ((fbSize == 0) || (bar1Size == 0) || (clientFbSizeAligned == 0))
     {
         return NV_ERR_NOT_SUPPORTED;
     }
@@ -416,6 +415,16 @@
         return NV_ERR_NOT_SUPPORTED;
     }
 
+    if (!portSafeAddU64(consoleSize, mailboxSize, &reservedSize) ||
+        reservedSize > NV_U64_MAX - (RM_PAGE_SIZE_512M - 1))
+    {
+        return NV_ERR_INVALID_ARGUMENT;
+    }
+
+    staticBar1Offset = NV_ALIGN_UP(reservedSize, RM_PAGE_SIZE_512M);
+    maxStaticMapSize = (bar1VASizeAligned > staticBar1Offset) ?
+        bar1VASizeAligned - staticBar1Offset : 0;
+
     switch (pKernelBus->staticBar1ForceType)
     {
         case NV_REG_STR_RM_FORCE_STATIC_BAR1_DISABLE:
@@ -430,7 +439,7 @@
                     RM_ALIGN_DOWN(memmgrGetClientFbAddrSpaceSize(pGpu, pMemoryManager),
                                   RM_PAGE_SIZE_2M);
 
-                if (bar1VASizeAligned < bar1MapSize)
+                if (maxStaticMapSize < bar1MapSize)
                 {
                     NV_PRINTF(LEVEL_ERROR, "BAR1 size %lld is not large enough to map FB size"
                                            "%lld to force static BAR1\n",
@@ -453,7 +462,7 @@
 
                 //
                 // Auto-enable if there is enough space to map
-                // + all of FB once
+                // + the client-visible FB range
                 // + enough to reserve enough space for userD BAR mappings
                 //       for every channel in the system
                 //       (whether userD is allocated by RM or by the user)
@@ -469,31 +478,27 @@
                 //
                 NvU32 userdSize = 0;
                 NvU32 numChannels = kfifoGetMaxChannelsInSystem(pGpu, pKernelFifo);
-                NvU64 requiredAutoBar1Size = fbSizeAligned;
+                NvU64 requiredAutoBar1Size;
                 NvU64 mmioPrivSize = 16 * RM_PAGE_SIZE;
                 NvU64 doorbellSize = 16 * RM_PAGE_SIZE;
+                NvU64 dynamicBar1Size;
 
                 kfifoGetUserdSizeAlign_HAL(pKernelFifo, &userdSize, NULL);
 
-                userdSize *= numChannels;
+                dynamicBar1Size = (NvU64)userdSize * numChannels + mmioPrivSize + doorbellSize;
 
-                requiredAutoBar1Size += userdSize;
-                requiredAutoBar1Size += mmioPrivSize;
-                requiredAutoBar1Size += doorbellSize;
-                requiredAutoBar1Size += consoleSize;
-                requiredAutoBar1Size += mailboxSize;
-
-                //
-                // Console mappings are already mapped from the bottom of the BAR1 VASpace,
-                // and mailboxes get mapped before the static BAR1 region. The static BAR1
-                // region needs to be aligned to 512 MB to allow for 512 MB page sizes, so
-                // we need to add in the space between the console and mailbox mappings due
-                // to the alignment. If there are no mailbox or console mappings, we don't
-                // need to add any alignment padding.
-                //
-                if ((consoleSize != 0) || (mailboxSize != 0))
+                if (maxStaticMapSize < clientFbSizeAligned)
+                    return NV_ERR_NOT_SUPPORTED;
+
+                // Dynamic mappings can also use the alignment gap.
+                NvU64 alignmentPadding = staticBar1Offset - reservedSize;
+                requiredAutoBar1Size = clientFbSizeAligned + staticBar1Offset;
+                if (dynamicBar1Size > alignmentPadding &&
+                    !portSafeAddU64(requiredAutoBar1Size,
+                                    dynamicBar1Size - alignmentPadding,
+                                    &requiredAutoBar1Size))
                 {
-                    requiredAutoBar1Size += RM_PAGE_SIZE_512M - ((consoleSize + mailboxSize) % RM_PAGE_SIZE_512M);
+                    return NV_ERR_NOT_SUPPORTED;
                 }
 
                 if (bar1VASizeAligned >= requiredAutoBar1Size)
diff -ruN a/src/nvidia/src/kernel/gpu/mem_mgr/arch/hopper/virt_mem_allocator_gh100.c b/src/nvidia/src/kernel/gpu/mem_mgr/arch/hopper/virt_mem_allocator_gh100.c
--- a/src/nvidia/src/kernel/gpu/mem_mgr/arch/hopper/virt_mem_allocator_gh100.c
+++ b/src/nvidia/src/kernel/gpu/mem_mgr/arch/hopper/virt_mem_allocator_gh100.c
@@ -57,6 +57,7 @@
     OBJGPU *pPeerGpu = NULL;
     KernelBus *pPeerKernelBus = NULL;
     NV_STATUS status = NV_OK;
+    NvBool bBar1Mapped = NV_FALSE;
 
     if (params == NULL ||
         params->pVas == NULL ||
@@ -94,6 +95,8 @@
     if (status != NV_OK)
         goto cleanup;
 
+    bBar1Mapped = NV_TRUE;
+
     bar1PhyAddr = gpumgrGetGpuPhysFbAddr(pPeerGpu) + phyAddr;
 
     NV_PRINTF(LEVEL_INFO, "bar1p2p surface mapped at bar1PhyAddr 0x%llx, len 0x%llx\n",
@@ -127,6 +130,7 @@
 
     params->pDmaMappingInfo->pBar1P2PVirtMemDesc = pBar1P2PVirtMemDesc;
     params->pDmaMappingInfo->pBar1P2PPhysMemDesc = pBar1P2PPhysMemDesc;
+    params->pDmaMappingInfo->bar1P2PApertureOffset = phyAddr;
 
     // Save the MemDesc to be the newly created sysmem in the peer BAR1 aperture
     params->pMemDescOut = pBar1P2PVirtMemDesc;
@@ -147,10 +151,10 @@
     return NV_OK;;
 
 cleanup:
-    if (phyAddr != 0)
+    if (bBar1Mapped)
     {
         kbusUnmapFbApertureSingle(pPeerGpu, pPeerKernelBus,
-                                  params->pPeerMemDesc,
+                                  pBar1P2PPhysMemDesc,
                                   phyAddr,
                                   bar1ApertureLen,
                                   BUS_MAP_FB_FLAGS_MAP_UNICAST);
@@ -186,17 +190,18 @@
     {
         OBJGPU *pPeerGpu = pDmaMappingInfo->pBar1P2PPhysMemDesc->pGpu;
         KernelBus *pPeerKernelBus = GPU_GET_KERNEL_BUS(pPeerGpu);
-        NvU64   bar1PhysAddr = memdescGetPhysAddr(pDmaMappingInfo->pBar1P2PVirtMemDesc, AT_CPU, 0);
+        NvU64   bar1ApertureOffset = pDmaMappingInfo->bar1P2PApertureOffset;
         NvU64   bar1MapSize  = memdescGetSize(pDmaMappingInfo->pBar1P2PVirtMemDesc);
 
         // Unmap the BAR1 mapping
         kbusUnmapFbApertureSingle(pPeerGpu, pPeerKernelBus,
                                   pDmaMappingInfo->pBar1P2PPhysMemDesc,
-                                  bar1PhysAddr,
+                                  bar1ApertureOffset,
                                   bar1MapSize,
                                   BUS_MAP_FB_FLAGS_MAP_UNICAST);
 
-        NV_PRINTF(LEVEL_INFO, "bar1p2p surface UN-mapped at 0x%llx + 0x%llx\n", bar1PhysAddr, bar1MapSize);
+        NV_PRINTF(LEVEL_INFO, "bar1p2p surface UN-mapped at 0x%llx + 0x%llx\n",
+                              bar1ApertureOffset, bar1MapSize);
 
         // Destroy the source memory descriptor
         memdescDestroy(pDmaMappingInfo->pBar1P2PPhysMemDesc);
diff -ruN a/src/nvidia/src/kernel/gpu/mem_mgr/arch/maxwell/virt_mem_allocator_gm107.c b/src/nvidia/src/kernel/gpu/mem_mgr/arch/maxwell/virt_mem_allocator_gm107.c
--- a/src/nvidia/src/kernel/gpu/mem_mgr/arch/maxwell/virt_mem_allocator_gm107.c
+++ b/src/nvidia/src/kernel/gpu/mem_mgr/arch/maxwell/virt_mem_allocator_gm107.c
@@ -1831,6 +1831,8 @@
             {
                 pIter->physAddr = dmaPageArrayGetPhysAddr(pIter->pPageArray, currIdxMod);
 
+                if (pageSize < pTarget->pageArrayGranularity)
+                    pIter->physAddr -= pIter->pPageArray->PteAdjust;
                 pIter->physAddr += pIter->currPageOffset;
                 // Hack to WAR submemesc mappings
                 pIter->physAddr = NV_ALIGN_DOWN64(pIter->physAddr, pageSize);
@@ -1961,7 +1963,7 @@
         // pPageArray deals pages with granularity `pTarget->pageArrayGranularity`.
         // So increment by the ratio of mapping page size to `pTarget->pageArrayGranularity`
         //
-        if (SYS_GET_INSTANCE()->bEnableDynamicGranularityPageArrays && pageSize < pTarget->pageArrayGranularity)
+        if (pageSize < pTarget->pageArrayGranularity)
         {
             pIter->currPageOffset += pageSize;
             if (pIter->currPageOffset >= pTarget->pageArrayGranularity)
@@ -2254,7 +2256,8 @@
     // encounter a case where a larger page granularity physical surface gets
     // represented by a smaller granularity pageArray.
     //
-    if (!SYS_GET_INSTANCE()->bEnableDynamicGranularityPageArrays)
+    if (!SYS_GET_INSTANCE()->bEnableDynamicGranularityPageArrays &&
+        (pMemDesc == NULL || pageSize > pMemDesc->pageArrayGranularity))
     {
         //
         // VMM-TODO: Merge into PL1 traveral.
@@ -2362,6 +2365,8 @@
         //MMU_MAP_ITER
         mapIter.pFmt            = pFmt;
         mapIter.pPageArray      = pPageArray;
+        if (pageSize < pMemDesc->pageArrayGranularity && pPageArray != NULL)
+            mapIter.currPageOffset = pPageArray->PteAdjust;
         mapIter.surfaceOffset   = surfaceOffset;
         mapIter.comprInfo       = *pComprInfo;
         mapIter.bReadPtes       = readPte;
diff -ruN a/src/nvidia/src/kernel/gpu/mem_mgr/mem_desc.c b/src/nvidia/src/kernel/gpu/mem_mgr/mem_desc.c
--- a/src/nvidia/src/kernel/gpu/mem_mgr/mem_desc.c
+++ b/src/nvidia/src/kernel/gpu/mem_mgr/mem_desc.c
@@ -2532,6 +2532,10 @@
     MEMORY_DESCRIPTOR *pLast;
     MEMORY_DESCRIPTOR *pNew;
     OBJGPU *pGpuChild;
+    NvU64 descriptorSize = Size;
+    NvBool bNativePageArray =
+        memdescGetFlag(pMemDesc, MEMDESC_FLAGS_EXT_PAGE_ARRAY_MEM) &&
+        pMemDesc->pageArrayGranularity > RM_PAGE_SIZE;
 
     NV_ASSERT_OR_RETURN(Offset < pMemDesc->Size, NV_ERR_INVALID_ARGUMENT);
     NV_ASSERT_OR_RETURN(Size != 0, NV_ERR_INVALID_ARGUMENT);
@@ -2543,8 +2547,16 @@
         pGpu = pMemDesc->pGpu;
     }
 
+    if (bNativePageArray)
+    {
+        NvU64 granularity = pMemDesc->pageArrayGranularity;
+        NvU64 adjust = (pMemDesc->PteAdjust + Offset) & (granularity - 1);
+
+        descriptorSize = (NV_ALIGN_UP64(adjust + Size, granularity) / granularity) * RM_PAGE_SIZE;
+    }
+
     // Allocate the new MEMORY_DESCRIPTOR
-    status = memdescCreate(&pMemDescNew, pGpu, Size, 0,
+    status = memdescCreate(&pMemDescNew, pGpu, descriptorSize, 0,
                            !!(pMemDesc->_flags & MEMDESC_FLAGS_PHYSICALLY_CONTIGUOUS),
                            pMemDesc->_addressSpace,
                            pMemDesc->_cpuCacheAttrib,
@@ -2611,7 +2623,11 @@
         pMemDescNew->PteAdjust = OffsetAdjust & pageArrayGranularityMask;
 
         PageCount = NV_ALIGN_UP64(pMemDescNew->PteAdjust + Size, pageArrayGranularity) >> pageArrayGranularityShift;
-        memdescFillPages(pMemDescNew, 0, &pMemDesc->_pteArray[PageIndex], PageCount, pageArrayGranularity);
+        if (bNativePageArray)
+            _memdescFillPagesAtNativeGranularity(pMemDescNew, 0,
+                &pMemDesc->_pteArray[PageIndex], PageCount, pageArrayGranularity);
+        else
+            memdescFillPages(pMemDescNew, 0, &pMemDesc->_pteArray[PageIndex], PageCount, pageArrayGranularity);
     }
 
     if (memdescIsEgm(pMemDesc))
diff -ruN a/src/nvidia/src/kernel/mem_mgr/io_vaspace.c b/src/nvidia/src/kernel/mem_mgr/io_vaspace.c
--- a/src/nvidia/src/kernel/mem_mgr/io_vaspace.c
+++ b/src/nvidia/src/kernel/mem_mgr/io_vaspace.c
@@ -63,9 +63,10 @@
 
     if (pIOVAS->mappingCount != 0)
     {
-        NV_PRINTF(LEVEL_ERROR, "%lld left-over mappings in IOVAS 0x%x\n",
-                  pIOVAS->mappingCount, pVAS->vaspaceId);
-        DBG_BREAKPOINT();
+        NV_PRINTF(LEVEL_WARNING,
+                  "%" NvU64_fmtu " left-over mappings in IOVAS 0x%x\n",
+                  pIOVAS->mappingCount,
+                  pVAS->vaspaceId);
     }
 }
 
@@ -599,12 +600,9 @@
     OBJIOVASPACE *pIOVAS = iovaspaceFromId(pIovaMapping->iovaspaceId);
 
     //
-    // The IOVASPACE has to be there as the mapping is referencing it. If it's
-    // not, the mapping has been left dangling outlasting the IOVAS it was
-    // under.
+    // A missing IOVAS means the mapping was left dangling and outlived the
+    // address space it belonged to. The destroy path reports that condition.
     //
-    NV_ASSERT(pIOVAS != NULL);
-
     return pIOVAS;
 }
 
@@ -612,7 +610,14 @@
 {
     OBJIOVASPACE *pIOVAS = iovaspaceFromMapping(pIovaMapping);
 
-    NV_ASSERT_OR_RETURN_VOID(pIOVAS != NULL);
+    if (pIOVAS == NULL)
+    {
+        NV_PRINTF(LEVEL_WARNING,
+                  "IOVA mapping outlived IOVAS 0x%x\n",
+                  pIovaMapping->iovaspaceId);
+        return;
+    }
+
     iovaspaceDestroyMapping(pIOVAS, pIovaMapping);
 }
 
diff -ruN a/src/nvidia/src/kernel/platform/p2p/p2p_caps.c b/src/nvidia/src/kernel/platform/p2p/p2p_caps.c
--- a/src/nvidia/src/kernel/platform/p2p/p2p_caps.c
+++ b/src/nvidia/src/kernel/platform/p2p/p2p_caps.c
@@ -66,6 +66,36 @@
     return NV_TRUE;
 }
 
+/**
+ * @brief Determines if all GPUs can use the proprietary PCIe P2P protocol
+ *
+ * Static BAR1 P2P does not exchange the architecture-specific mailbox
+ * protocol, so this compatibility check must only gate the proprietary PCIe
+ * fallback.
+ */
+static NvBool
+areAllGpusP2PCompatible(NvU32 gpuMask)
+{
+    NvU32 gpuInstance = 0;
+    OBJGPU *pGpu;
+    OBJGPU *pFirstGpu = gpumgrGetNextGpu(gpuMask, &gpuInstance);
+
+    if (pFirstGpu == NULL)
+    {
+        return NV_FALSE;
+    }
+
+    while ((pGpu = gpumgrGetNextGpu(gpuMask, &gpuInstance)) != NULL)
+    {
+        if (!areGpusP2PCompatible(pFirstGpu, pGpu))
+        {
+            return NV_FALSE;
+        }
+    }
+
+    return NV_TRUE;
+}
+
 NV_STATUS
 p2pGetCaps
 (
@@ -773,6 +803,19 @@
         return NV_OK;
     }
 
+    // Retain the PCIe restriction when retrying BAR1 with fresh status.
+    gpuInstance = 0;
+    while ((pGpuPeer = gpumgrGetNextGpu(gpuMask, &gpuInstance)) != NULL)
+    {
+        if (gpuIsSelfHosted(pGpuPeer))
+        {
+            *pP2PReadCapStatus = NV0000_P2P_CAPS_STATUS_NOT_SUPPORTED;
+            *pP2PWriteCapStatus = NV0000_P2P_CAPS_STATUS_NOT_SUPPORTED;
+            *pP2PAtomicsCapStatus = NV0000_P2P_CAPS_STATUS_NOT_SUPPORTED;
+            return NV_ERR_NOT_SUPPORTED;
+        }
+    }
+
     NV_CHECK_OK_OR_RETURN(LEVEL_ERROR,
                           _p2pCapsGetHostSystemStatusOverPcieBar1(pFirstGpu, &writeCapStatus,
                             &readCapStatus, bCommonPciSwitchFound));
@@ -915,33 +958,41 @@
     }
 
     //
-    // Check PCIE P2P connectivity.
-    //
-    // We can control P2P connectivity for PCI-E peers using regkeys, hence
-    // if either read or write is supported, return success. See
-    // _kp2pCapsCheckStatusOverridesForPcie for details.
+    // Check PCIe topology and proprietary P2P capabilities first to retain
+    // its common-switch result. BAR1 is a separate transport, so check it
+    // with fresh status even when proprietary compatibility failed.
     //
     if (_kp2pCapsGetStatusOverPcie(gpuMask, pP2PWriteCapStatus,
                                   pP2PReadCapStatus, &bCommonSwitchFound) == NV_OK)
     {
+        NvU8 bar1P2PWriteCapStatus = NV0000_P2P_CAPS_STATUS_OK;
+        NvU8 bar1P2PReadCapStatus = NV0000_P2P_CAPS_STATUS_OK;
+        NvU8 bar1P2PAtomicsCapStatus = NV0000_P2P_CAPS_STATUS_NOT_SUPPORTED;
+
+        if (_kp2pCapsGetStatusOverPcieBar1(gpuMask, &bar1P2PWriteCapStatus,
+                &bar1P2PReadCapStatus, &bar1P2PAtomicsCapStatus,
+                bCommonSwitchFound) == NV_OK)
+        {
+            *pP2PWriteCapStatus = bar1P2PWriteCapStatus;
+            *pP2PReadCapStatus = bar1P2PReadCapStatus;
+            *pP2PAtomicsCapStatus = bar1P2PAtomicsCapStatus;
+            *pConnectivity = P2P_CONNECTIVITY_PCIE_BAR1;
+            return NV_OK;
+        }
+
+        // BAR1 is the only architecture-independent PCIe transport here.
+        if (!areAllGpusP2PCompatible(gpuMask))
+        {
+            *pP2PWriteCapStatus = NV0000_P2P_CAPS_STATUS_NOT_SUPPORTED;
+            *pP2PReadCapStatus = NV0000_P2P_CAPS_STATUS_NOT_SUPPORTED;
+            *pP2PAtomicsCapStatus = NV0000_P2P_CAPS_STATUS_NOT_SUPPORTED;
+            return NV_OK;
+        }
+
         if ((*pP2PWriteCapStatus == NV0000_P2P_CAPS_STATUS_OK) ||
             (*pP2PReadCapStatus == NV0000_P2P_CAPS_STATUS_OK))
         {
-            NvU8 bar1P2PWriteCapStatus = *pP2PWriteCapStatus;
-            NvU8 bar1P2PReadCapStatus = *pP2PReadCapStatus;
-            NvU8 bar1P2PAtomicsCapStatus = NV0000_P2P_CAPS_STATUS_NOT_SUPPORTED;
-
             *pConnectivity = P2P_CONNECTIVITY_PCIE_PROPRIETARY;
-
-            if (_kp2pCapsGetStatusOverPcieBar1(gpuMask, &bar1P2PWriteCapStatus,
-                    &bar1P2PReadCapStatus, &bar1P2PAtomicsCapStatus, bCommonSwitchFound) == NV_OK)
-            {
-                *pP2PWriteCapStatus = bar1P2PWriteCapStatus;
-                *pP2PReadCapStatus = bar1P2PReadCapStatus;
-                *pP2PAtomicsCapStatus = bar1P2PAtomicsCapStatus;
-                *pConnectivity = P2P_CONNECTIVITY_PCIE_BAR1;
-            }
-
             return NV_OK;
         }
     }
diff -ruN a/src/nvidia/src/kernel/rmapi/nv_gpu_ops.c b/src/nvidia/src/kernel/rmapi/nv_gpu_ops.c
--- a/src/nvidia/src/kernel/rmapi/nv_gpu_ops.c
+++ b/src/nvidia/src/kernel/rmapi/nv_gpu_ops.c
@@ -3244,15 +3244,29 @@
 }
 
 // TODO: Bug 3264814: [HOPPER][RM] Support Bar1 P2P PCIE Atomics
-// The logic here should consider bus topology and routing between
-// the two GPUs.
+// The logic here should consider bus topology and routing between the two
+// GPUs. Mixed-architecture BAR1 mappings must remain non-coherent until that
+// routing and the atomic protocol compatibility have been validated.
 NvBool _nvGpuOpsIsBar1P2pAtomicEnabled(struct gpuSession *session, OBJGPU *pMappingGpu, OBJGPU *pOwningGpu)
 {
-    NvU32 arch;
-    NV_STATUS status = _nvGpuOpsGetDeviceArchByGpuId(session, pOwningGpu->gpuId, &arch);
+    NvU32 mappingArch;
+    NvU32 owningArch;
+    NV_STATUS status = _nvGpuOpsGetDeviceArchByGpuId(session, pOwningGpu->gpuId, &owningArch);
 
     NV_ASSERT_OR_RETURN(status == NV_OK, 0);
-    return arch >= GPU_ARCHITECTURE_BLACKWELL_GB1XX;
+
+    if (pMappingGpu != NULL)
+    {
+        status = _nvGpuOpsGetDeviceArchByGpuId(session, pMappingGpu->gpuId, &mappingArch);
+        NV_ASSERT_OR_RETURN(status == NV_OK, 0);
+
+        if (mappingArch != owningArch)
+        {
+            return NV_FALSE;
+        }
+    }
+
+    return owningArch >= GPU_ARCHITECTURE_BLACKWELL_GB1XX;
 }
 
 NV_STATUS nvGpuOpsGetP2PCaps(struct gpuDevice *device1,
@@ -3670,6 +3684,7 @@
 }
 
 static GMMU_APERTURE nvGpuOpsGetExternalAllocAperture(struct gpuSession *session,
+                                                      OBJGPU *pMappingGpu,
                                                       PMEMORY_DESCRIPTOR pMemDesc,
                                                       NvBool isIndirectPeerSupported,
                                                       NvBool isPeerSupported,
@@ -3687,7 +3702,7 @@
 
         if (isBar1P2PSupported)
         {
-            if (_nvGpuOpsIsBar1P2pAtomicEnabled(session, NULL, pMemDesc->pGpu))
+            if (_nvGpuOpsIsBar1P2pAtomicEnabled(session, pMappingGpu, pMemDesc->pGpu))
             {
                 return GMMU_APERTURE_SYS_COH;
             }
@@ -3941,22 +3956,42 @@
  *
  * @param[in] pAddresses        : Array of physical addresses to be encoded.
  * @param[in] dmaBaseAddress    : IOVA base address.
+ * @param[in] dmaSize           : IOVA window size.
+ * @param[in] pageSize          : Size covered by each physical address.
  * @param[in] count             : Count of physical addresses.
  */
-static void
+static NV_STATUS
 _nvGpuOpsEncodeBar1P2PAddrs
 (
     NvU64 *pAddresses,
     NvU64  dmaBaseAddress,
+    NvU64  dmaSize,
+    NvU64  pageSize,
     NvU64  count
 )
 {
-    NvU32 i;
+    NvU64 i;
 
     for (i = 0; i < count; i++)
     {
-        pAddresses[i] = dmaBaseAddress + pAddresses[i];
+        NvU64 offset = pAddresses[i];
+        NvU64 encodedAddress;
+
+        if ((offset >= dmaSize) ||
+            (pageSize > (dmaSize - offset)) ||
+            !portSafeAddU64(dmaBaseAddress, offset, &encodedAddress))
+        {
+            NV_PRINTF(LEVEL_ERROR,
+                      "BAR1 P2P address range exceeds DMA window: "
+                      "offset=0x%llx pageSize=0x%llx dmaBase=0x%llx dmaSize=0x%llx\n",
+                      offset, pageSize, dmaBaseAddress, dmaSize);
+            return NV_ERR_INVALID_ADDRESS;
+        }
+
+        pAddresses[i] = encodedAddress;
     }
+
+    return NV_OK;
 }
 
 static
@@ -4081,6 +4116,7 @@
         memdescSetPteKindForGpu(pMemDesc, pMappingGpu, oldKind);
 
     aperture = nvGpuOpsGetExternalAllocAperture(session,
+                                                pMappingGpu,
                                                 pMemDesc,
                                                 isIndirectPeerSupported,
                                                 isPeerSupported,
@@ -4183,7 +4219,7 @@
         }
     }
 
-    if (aperture == GMMU_APERTURE_PEER)
+    if ((aperture == GMMU_APERTURE_PEER) && !isBar1P2PSupported)
     {
         nvFieldSet32(&pPteFmt->fldPeerIndex, peerId, pte.v8);
 
@@ -4293,7 +4329,13 @@
             status = NV_ERR_INVALID_STATE;
             goto done;
         }
-        _nvGpuOpsEncodeBar1P2PAddrs(physicalAddresses, dmaBaseAddress, pteCount);
+        NV_CHECK_OK_OR_GOTO(status, LEVEL_ERROR,
+                            _nvGpuOpsEncodeBar1P2PAddrs(physicalAddresses,
+                                                        dmaBaseAddress,
+                                                        dmaSize,
+                                                        mappingPageSize,
+                                                        pteCount),
+                            done);
     }
     else
     {
@@ -4499,6 +4541,7 @@
         return NV_ERR_INVALID_ARGUMENT;
 
     aperture = nvGpuOpsGetExternalAllocAperture(session,
+                                                pMappingGpu,
                                                 pMemDesc,
                                                 isIndirectPeerSupported,
                                                 isPeerSupported,
@@ -4520,7 +4563,7 @@
         return NV_ERR_BUFFER_TOO_SMALL;
 
 
-    if (aperture == GMMU_APERTURE_PEER)
+    if ((aperture == GMMU_APERTURE_PEER) && !isBar1P2PSupported)
     {
         //
         // Any fabric memory descriptors are pre-encoded with the fabric base address
@@ -4627,7 +4670,13 @@
             status = NV_ERR_INVALID_STATE;
             goto done;
         }
-        _nvGpuOpsEncodeBar1P2PAddrs(physicalAddresses, dmaBaseAddress, physAddrCount);
+        NV_CHECK_OK_OR_GOTO(status, LEVEL_ERROR,
+                            _nvGpuOpsEncodeBar1P2PAddrs(physicalAddresses,
+                                                        dmaBaseAddress,
+                                                        dmaSize,
+                                                        mappingPageSize,
+                                                        physAddrCount),
+                            done);
     }
     else
     {
@@ -8122,6 +8171,7 @@
     if (pGpuMemoryInfo->contig)
     {
         GMMU_APERTURE aperture = nvGpuOpsGetExternalAllocAperture(NULL,
+                                                                  pMappingGpu,
                                                                   pMemDesc,
                                                                   NV_FALSE,
                                                                   NV_FALSE,
__P2P_PATCH__
}

main "$@"
