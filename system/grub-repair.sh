#!/usr/bin/env bash

# fix_grub.sh - Auto-repair GRUB bootloader from Ubuntu Live CD
# Designed for Proxmox Ubuntu 24.04 hosts with recurring GRUB corruption
#
# Usage:
#   sudo ./fix_grub.sh              # Interactive mode (recommended)
#   sudo ./fix_grub.sh --yes        # Skip confirmations (USE WITH CAUTION)
#   sudo ./fix_grub.sh --dry-run    # Show what would be done without doing it
#   sudo ./fix_grub.sh --help       # Show usage information
#
# Run this from an Ubuntu Live CD/USB after booting into the live environment.

set -uo pipefail

# ---------------------------------------------------------------------------
# Colors & output helpers (matches project convention from ubuntu_setup.sh)
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'
BOLD='\033[1m'

print_header() {
	local header="$1"
	local width=80
	local pad=$(((width - ${#header} - 2) / 2))
	echo
	echo -e "${CYAN}$(printf '=%.0s' $(seq 1 "$width"))${NC}"
	printf "${CYAN}|${NC}%*s${BOLD}${WHITE}%s${NC}%*s${CYAN}|${NC}\n" "$pad" "" "$header" "$pad" ""
	echo -e "${CYAN}$(printf '=%.0s' $(seq 1 "$width"))${NC}"
	echo
}

print_status() { echo -e "${BLUE}>>>${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_info() { echo -e "${CYAN}[INFO]${NC} $1"; }

die() {
	print_error "$1"
	exit 1
}

# ---------------------------------------------------------------------------
# Global state
# ---------------------------------------------------------------------------
MOUNT_ROOT="/mnt"
AUTO_YES=false
DRY_RUN=false
LVM_ACTIVATED=false
MOUNTED_BIND=()
MOUNTED_FS=()
ROOT_DEV=""
BOOT_DEV=""
EFI_DEV=""
DISK_DEV=""
IS_EFI=false

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
	cat <<'EOF'
Usage: sudo ./fix_grub.sh [OPTIONS]

Options:
  --yes, -y       Skip interactive confirmations (use with caution)
  --dry-run       Show detected layout and planned actions without executing
  --help, -h      Show this help message

This script must be run as root from an Ubuntu Live CD/USB environment.
It will:
  1. Auto-detect the installed system's disk, root, boot, and EFI partitions
  2. Run filesystem checks (fsck) on detected partitions
  3. Mount the installed system under /mnt
  4. Chroot in and repair GRUB (update-grub + grub-install)
  5. Clean up all mounts on exit (even on failure)
EOF
}

for arg in "$@"; do
	case "$arg" in
	--yes | -y) AUTO_YES=true ;;
	--dry-run) DRY_RUN=true ;;
	--help | -h)
		usage
		exit 0
		;;
	*) die "Unknown argument: $arg (try --help)" ;;
	esac
done

# ---------------------------------------------------------------------------
# Confirmation helper
# ---------------------------------------------------------------------------
confirm() {
	local prompt="$1"
	if "$AUTO_YES"; then
		print_info "Auto-confirmed: $prompt"
		return 0
	fi
	echo -en "${YELLOW}>>> ${prompt} [y/N]: ${NC}"
	read -r reply
	case "$reply" in
	[Yy]*) return 0 ;;
	*) return 1 ;;
	esac
}

# ---------------------------------------------------------------------------
# Cleanup — runs on EXIT (success or failure)
# ---------------------------------------------------------------------------
cleanup() {
	local exit_code=$?
	echo
	print_header "Cleanup"

	# Unmount bind mounts in reverse order
	for ((i = ${#MOUNTED_BIND[@]} - 1; i >= 0; i--)); do
		local mnt="${MOUNTED_BIND[$i]}"
		if mountpoint -q "$mnt" 2>/dev/null; then
			print_status "Unmounting bind: $mnt"
			umount -l "$mnt" 2>/dev/null || true
		fi
	done

	# Unmount filesystems in reverse order
	for ((i = ${#MOUNTED_FS[@]} - 1; i >= 0; i--)); do
		local mnt="${MOUNTED_FS[$i]}"
		if mountpoint -q "$mnt" 2>/dev/null; then
			print_status "Unmounting: $mnt"
			umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
		fi
	done

	# Deactivate LVM if we activated it
	if "$LVM_ACTIVATED"; then
		print_status "Deactivating LVM volume groups..."
		vgchange -an 2>/dev/null || true
	fi

	if [ "$exit_code" -eq 0 ]; then
		print_success "Cleanup complete."
	else
		print_warn "Cleanup complete (script exited with code $exit_code)."
	fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
check_prerequisites() {
	print_header "Checking Prerequisites"

	# Must be root
	if [[ $EUID -ne 0 ]]; then
		die "This script must be run as root. Try: sudo $0"
	fi
	print_success "Running as root"

	# Detect live environment (multiple heuristics)
	local is_live=false
	[[ -d /run/live ]] && is_live=true
	[[ -d /cdrom ]] && is_live=true
	[[ -f /etc/casper.conf ]] && is_live=true
	grep -q "overlay\|squashfs\|tmpfs" /proc/mounts 2>/dev/null &&
		grep -q " / " /proc/mounts 2>/dev/null && is_live=true
	# Also check if running from a casper/initrd-based system
	grep -q "boot=casper" /proc/cmdline 2>/dev/null && is_live=true

	if ! "$is_live"; then
		print_warn "Could not confirm this is a Live CD environment."
		print_warn "Running on the installed system could cause damage."
		if ! confirm "Continue anyway? (NOT RECOMMENDED)"; then
			die "Aborted. Please boot from an Ubuntu Live CD/USB first."
		fi
	else
		print_success "Live environment detected"
	fi

	# Required tools
	local missing=()
	for tool in lsblk blkid mount umount chroot fsck; do
		if ! command -v "$tool" &>/dev/null; then
			missing+=("$tool")
		fi
	done
	if [[ ${#missing[@]} -gt 0 ]]; then
		die "Missing required tools: ${missing[*]}"
	fi
	print_success "Required tools available"

	# Check if grub tools are available (may need to install in live env)
	if ! command -v grub-install &>/dev/null; then
		print_warn "grub-install not found in live environment."
		print_info "It will be available inside the chroot (from the installed system)."
	fi

	# Check for UEFI
	if [[ -d /sys/firmware/efi ]]; then
		IS_EFI=true
		print_success "UEFI firmware detected"
	else
		IS_EFI=false
		print_info "BIOS/Legacy firmware detected"
	fi

	# Check if /mnt is clear
	if mountpoint -q "$MOUNT_ROOT" 2>/dev/null; then
		die "$MOUNT_ROOT is already a mountpoint. Unmount it first."
	fi
	print_success "$MOUNT_ROOT is available for use"

	# Check for LVM tools
	if command -v lvm &>/dev/null; then
		print_success "LVM tools available"
	else
		print_info "LVM tools not found — will skip LVM detection"
	fi
}

# ---------------------------------------------------------------------------
# Disk & partition detection
# ---------------------------------------------------------------------------
detect_disk_and_partitions() {
	print_header "Detecting Installed System"

	# Show all block devices for context
	print_status "Block device layout:"
	lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT 2>/dev/null | sed 's/^/    /'
	echo

	# Find candidate disks: physical disks (not loop, not rom, not live USB)
	local live_devs=""
	live_devs=$(awk '$0 ~ /\/cdrom|\/run\/live|\/media/ {print $1}' /proc/mounts 2>/dev/null |
		xargs -I{} lsblk -no PKNAME {} 2>/dev/null | sort -u)

	local -a candidate_disks=()
	while IFS= read -r line; do
		local dname dtype dsize
		dname=$(echo "$line" | awk '{print $1}')
		dtype=$(echo "$line" | awk '{print $2}')
		dsize=$(echo "$line" | awk '{print $3}')

		[[ "$dtype" != "disk" ]] && continue
		[[ -z "$dname" ]] && continue

		# Skip if this is the live media
		local is_live_disk=false
		while IFS= read -r ld; do
			[[ "$ld" == "$dname" ]] && is_live_disk=true
		done <<<"$live_devs"
		"$is_live_disk" && continue

		# Check if it has any Linux-related partitions
		local has_linux=false
		if lsblk -no FSTYPE "/dev/$dname" 2>/dev/null | grep -qE "ext[234]|xfs|btrfs|LVM2_member|swap"; then
			has_linux=true
		fi
		if "$has_linux"; then
			candidate_disks+=("$dname|$dsize")
		fi
	done < <(lsblk -nd -o NAME,TYPE,SIZE 2>/dev/null)

	if [[ ${#candidate_disks[@]} -eq 0 ]]; then
		die "No disks with Linux filesystems found. Is the disk connected and visible?"
	fi

	# Select the target disk
	if [[ ${#candidate_disks[@]} -eq 1 ]]; then
		DISK_DEV="/dev/${candidate_disks[0]%%|*}"
		local disk_size="${candidate_disks[0]#*|}"
		print_success "Auto-detected target disk: ${BOLD}$DISK_DEV${NC} ($disk_size)"
	else
		print_status "Multiple candidate disks found:"
		local idx=1
		for entry in "${candidate_disks[@]}"; do
			local dname="${entry%%|*}"
			local dsize="${entry#*|}"
			echo -e "    ${BOLD}$idx)${NC} /dev/$dname ($dsize)"
			idx=$((idx + 1))
		done
		echo -en "${YELLOW}>>> Select disk number [1]: ${NC}"
		read -r choice
		choice="${choice:-1}"
		if [[ "$choice" -lt 1 || "$choice" -gt ${#candidate_disks[@]} ]] 2>/dev/null; then
			die "Invalid selection."
		fi
		local selected="${candidate_disks[$((choice - 1))]}"
		DISK_DEV="/dev/${selected%%|*}"
		print_success "Selected disk: ${BOLD}$DISK_DEV${NC}"
	fi

	# Activate LVM if any LVM PVs are on this disk
	if command -v lvm &>/dev/null; then
		if lsblk -no FSTYPE "$DISK_DEV" 2>/dev/null | grep -q "LVM2_member"; then
			print_status "LVM physical volumes detected — activating volume groups..."
			vgchange -ay 2>/dev/null
			LVM_ACTIVATED=true
			# Wait briefly for device nodes to appear
			sleep 1
			udevadm settle 2>/dev/null || true
			print_success "LVM volume groups activated"
		fi
	fi

	# --- Detect partitions ---
	# Strategy: Use blkid + lsblk to find EFI, boot, and root partitions

	# EFI partition: vfat on this disk, typically 100-1024 MB
	EFI_DEV=""
	while IFS= read -r part; do
		[[ -z "$part" ]] && continue
		local pdev="/dev/$part"
		local pfstype
		pfstype=$(blkid -s TYPE -o value "$pdev" 2>/dev/null)
		if [[ "$pfstype" == "vfat" ]]; then
			# Verify it looks like an EFI partition (check partition type GUID or size)
			local psize
			psize=$(lsblk -bno SIZE "$pdev" 2>/dev/null)
			if [[ -n "$psize" ]] && ((psize >= 50000000 && psize <= 2000000000)); then
				EFI_DEV="$pdev"
				break
			fi
		fi
	done < <(lsblk -no NAME "$DISK_DEV" 2>/dev/null | tail -n +2 | sed 's/[^a-zA-Z0-9]//g')

	# Root partition: the main ext4/xfs partition (largest), or LVM logical volume
	ROOT_DEV=""
	BOOT_DEV=""

	# First check for LVM logical volumes
	if "$LVM_ACTIVATED"; then
		# Find the root LV — look for the largest ext4/xfs LV
		local largest_lv=""
		local largest_size=0
		while IFS= read -r lv_path; do
			[[ -z "$lv_path" ]] && continue
			local lv_fs
			lv_fs=$(blkid -s TYPE -o value "$lv_path" 2>/dev/null)
			if [[ "$lv_fs" == "ext4" || "$lv_fs" == "xfs" ]]; then
				local lv_size
				lv_size=$(lsblk -bno SIZE "$lv_path" 2>/dev/null)
				if [[ -n "$lv_size" ]] && ((lv_size > largest_size)); then
					largest_size=$lv_size
					largest_lv=$lv_path
				fi
			fi
		done < <(lvs --noheadings -o lv_path 2>/dev/null)

		if [[ -n "$largest_lv" ]]; then
			ROOT_DEV="$largest_lv"
		fi
	fi

	# If no LVM root found, search direct partitions
	if [[ -z "$ROOT_DEV" ]]; then
		local largest_part=""
		local largest_size=0
		while IFS= read -r part; do
			[[ -z "$part" ]] && continue
			local pdev="/dev/$part"
			[[ "$pdev" == "$EFI_DEV" ]] && continue
			local pfstype
			pfstype=$(blkid -s TYPE -o value "$pdev" 2>/dev/null)
			if [[ "$pfstype" == "ext4" || "$pfstype" == "xfs" || "$pfstype" == "btrfs" ]]; then
				local psize
				psize=$(lsblk -bno SIZE "$pdev" 2>/dev/null)
				if [[ -n "$psize" ]] && ((psize > largest_size)); then
					largest_size=$psize
					largest_part=$pdev
				fi
			fi
		done < <(lsblk -no NAME "$DISK_DEV" 2>/dev/null | tail -n +2 | sed 's/[^a-zA-Z0-9]//g')
		ROOT_DEV="$largest_part"
	fi

	# Check for ZFS — separate handling
	if lsblk -no FSTYPE "$DISK_DEV" 2>/dev/null | grep -q "zfs_member"; then
		print_warn "ZFS partitions detected on this disk."
		print_warn "ZFS root requires 'zpool import -fR /mnt rpool' instead of a simple mount."
		print_warn "This script handles ext4/xfs/LVM roots. For ZFS root, use:"
		echo -e "    ${CYAN}zpool import -fR /mnt rpool${NC}"
		echo -e "    ${CYAN}# then run the chroot/grub-install steps manually${NC}"
		if [[ -z "$ROOT_DEV" ]]; then
			die "No non-ZFS root partition found. Manual ZFS repair needed."
		fi
		print_info "Proceeding with detected non-ZFS root: $ROOT_DEV"
	fi

	if [[ -z "$ROOT_DEV" ]]; then
		die "Could not detect root partition on $DISK_DEV."
	fi

	# Boot partition: ext4, small (200MB-4GB), not the root, not EFI
	# Check if root has a separate /boot by looking for a smaller ext4 partition
	while IFS= read -r part; do
		[[ -z "$part" ]] && continue
		local pdev="/dev/$part"
		[[ "$pdev" == "$EFI_DEV" ]] && continue
		[[ "$pdev" == "$ROOT_DEV" ]] && continue
		local pfstype
		pfstype=$(blkid -s TYPE -o value "$pdev" 2>/dev/null)
		if [[ "$pfstype" == "ext4" || "$pfstype" == "ext2" ]]; then
			local psize
			psize=$(lsblk -bno SIZE "$pdev" 2>/dev/null)
			# Boot partitions are typically 256MB to 4GB
			if [[ -n "$psize" ]] && ((psize >= 200000000 && psize <= 4000000000)); then
				BOOT_DEV="$pdev"
				break
			fi
		fi
	done < <(lsblk -no NAME "$DISK_DEV" 2>/dev/null | tail -n +2 | sed 's/[^a-zA-Z0-9]//g')

	# Summary
	print_header "Detected Layout"
	echo -e "    ${BOLD}Disk:${NC}       $DISK_DEV"
	echo -e "    ${BOLD}Root:${NC}       $ROOT_DEV ($(blkid -s TYPE -o value "$ROOT_DEV" 2>/dev/null))"
	if [[ -n "$BOOT_DEV" ]]; then
		echo -e "    ${BOLD}Boot:${NC}       $BOOT_DEV ($(blkid -s TYPE -o value "$BOOT_DEV" 2>/dev/null))"
	else
		echo -e "    ${BOLD}Boot:${NC}       (on root partition)"
	fi
	if [[ -n "$EFI_DEV" ]]; then
		echo -e "    ${BOLD}EFI:${NC}        $EFI_DEV (vfat)"
	else
		echo -e "    ${BOLD}EFI:${NC}        (none — BIOS mode)"
	fi
	echo -e "    ${BOLD}Firmware:${NC}   $("$IS_EFI" && echo "UEFI" || echo "BIOS/Legacy")"
	echo

	# Sanity check: if UEFI system but no EFI partition found
	if "$IS_EFI" && [[ -z "$EFI_DEV" ]]; then
		print_warn "System is booted in UEFI mode but no EFI partition found on $DISK_DEV."
		print_warn "GRUB install may fail without an EFI System Partition."
		if ! confirm "Continue anyway?"; then
			die "Aborted."
		fi
	fi

	if "$DRY_RUN"; then
		print_info "DRY RUN — would mount, fsck, and repair GRUB on the above layout."
		exit 0
	fi

	if ! confirm "Proceed with GRUB repair using the above layout?"; then
		die "Aborted by user."
	fi
}

# ---------------------------------------------------------------------------
# Filesystem check
# ---------------------------------------------------------------------------
run_fsck_on_partitions() {
	print_header "Filesystem Check (fsck)"

	local parts=("$ROOT_DEV")
	[[ -n "$BOOT_DEV" ]] && parts+=("$BOOT_DEV")
	# Skip fsck on EFI vfat — dosfsck may not be available and it's rarely corrupted

	for part in "${parts[@]}"; do
		print_status "Checking $part ..."
		local fstype
		fstype=$(blkid -s TYPE -o value "$part" 2>/dev/null)

		case "$fstype" in
		ext4 | ext3 | ext2)
			# -p: auto-repair safe issues; -f: force check even if clean
			if e2fsck -p -f "$part" 2>&1; then
				print_success "$part — clean"
			else
				local rc=$?
				if ((rc <= 1)); then
					print_success "$part — repaired automatically"
				else
					print_warn "$part — fsck returned code $rc"
					print_warn "There may be filesystem issues requiring manual attention."
					if ! confirm "Continue despite fsck warnings on $part?"; then
						die "Aborted due to fsck issues."
					fi
				fi
			fi
			;;
		xfs)
			# xfs_repair -n is read-only check
			if xfs_repair -n "$part" &>/dev/null; then
				print_success "$part — clean (xfs)"
			else
				print_warn "$part — XFS issues detected, running xfs_repair..."
				xfs_repair "$part" 2>&1 || true
			fi
			;;
		*)
			print_info "Skipping fsck for $part (unsupported fstype: $fstype)"
			;;
		esac
	done

	# Quick check on EFI partition if dosfsck is available
	if [[ -n "$EFI_DEV" ]] && command -v dosfsck &>/dev/null; then
		print_status "Checking EFI partition $EFI_DEV ..."
		if dosfsck -a "$EFI_DEV" 2>&1; then
			print_success "$EFI_DEV — clean (vfat)"
		else
			print_warn "$EFI_DEV — dosfsck reported issues (non-fatal, continuing)"
		fi
	fi
}

# ---------------------------------------------------------------------------
# Mount the installed system
# ---------------------------------------------------------------------------
mount_system() {
	print_header "Mounting Installed System"

	# Mount root
	print_status "Mounting root: $ROOT_DEV -> $MOUNT_ROOT"
	mount "$ROOT_DEV" "$MOUNT_ROOT" || die "Failed to mount root partition $ROOT_DEV"
	MOUNTED_FS+=("$MOUNT_ROOT")

	# Verify it looks like a real Linux root
	if [[ ! -d "$MOUNT_ROOT/etc" || ! -d "$MOUNT_ROOT/usr" ]]; then
		die "$ROOT_DEV does not appear to be a Linux root filesystem (missing /etc or /usr)."
	fi
	print_success "Root mounted — verified as Linux root filesystem"

	# Mount /boot if separate
	if [[ -n "$BOOT_DEV" ]]; then
		print_status "Mounting boot: $BOOT_DEV -> $MOUNT_ROOT/boot"
		mount "$BOOT_DEV" "$MOUNT_ROOT/boot" || die "Failed to mount boot partition $BOOT_DEV"
		MOUNTED_FS+=("$MOUNT_ROOT/boot")
		print_success "Boot partition mounted"
	fi

	# Mount EFI partition
	if [[ -n "$EFI_DEV" ]]; then
		# Determine EFI mount point — check fstab for the canonical location
		local efi_mount="$MOUNT_ROOT/boot/efi"
		if [[ -f "$MOUNT_ROOT/etc/fstab" ]]; then
			local fstab_efi
			fstab_efi=$(grep -E "/boot/efi|/efi" "$MOUNT_ROOT/etc/fstab" 2>/dev/null |
				grep -v "^#" | awk '{print $2}' | head -1)
			if [[ -n "$fstab_efi" ]]; then
				efi_mount="$MOUNT_ROOT$fstab_efi"
			fi
		fi
		mkdir -p "$efi_mount"
		print_status "Mounting EFI: $EFI_DEV -> $efi_mount"
		mount "$EFI_DEV" "$efi_mount" || die "Failed to mount EFI partition $EFI_DEV"
		MOUNTED_FS+=("$efi_mount")
		print_success "EFI partition mounted"
	fi

	# Bind mount virtual filesystems for chroot
	print_status "Setting up bind mounts for chroot..."
	for vfs in /proc /sys /dev /dev/pts /run; do
		if [[ -d "$vfs" ]]; then
			mkdir -p "$MOUNT_ROOT$vfs"
			mount --bind "$vfs" "$MOUNT_ROOT$vfs" || die "Failed to bind mount $vfs"
			MOUNTED_BIND+=("$MOUNT_ROOT$vfs")
		fi
	done

	# Also bind /sys/firmware/efi/efivars if UEFI — needed for grub-install
	if "$IS_EFI" && [[ -d /sys/firmware/efi/efivars ]]; then
		if ! mountpoint -q "$MOUNT_ROOT/sys/firmware/efi/efivars" 2>/dev/null; then
			mount --bind /sys/firmware/efi/efivars "$MOUNT_ROOT/sys/firmware/efi/efivars" 2>/dev/null || true
			MOUNTED_BIND+=("$MOUNT_ROOT/sys/firmware/efi/efivars")
		fi
	fi

	print_success "All filesystems mounted and ready for chroot"
}

# ---------------------------------------------------------------------------
# Repair GRUB
# ---------------------------------------------------------------------------
repair_grub() {
	print_header "Repairing GRUB"

	# Ensure resolv.conf is available for any package operations inside chroot
	if [[ -f /etc/resolv.conf ]]; then
		cp /etc/resolv.conf "$MOUNT_ROOT/etc/resolv.conf" 2>/dev/null || true
	fi

	# Fix apt_pkg module — Python version mismatch between live CD and installed system
	# update-grub calls scripts that import apt_pkg, a compiled C extension (.so) built
	# for a specific Python version. If the live CD's Python differs from the installed
	# system's Python, the import fails with "No module named 'apt_pkg'".
	# Fix: symlink the existing .so to the name the chroot's Python expects.
	fix_apt_pkg() {
		local apt_pkg_dir="$MOUNT_ROOT/usr/lib/python3/dist-packages"
		[[ -d "$apt_pkg_dir" ]] || return 0

		# Find the chroot's Python version
		local chroot_py_ver
		chroot_py_ver=$(chroot "$MOUNT_ROOT" python3 -c "import sys; print(f'{sys.version_info.major}{sys.version_info.minor}')" 2>/dev/null) || return 0

		# Check if apt_pkg already works
		if chroot "$MOUNT_ROOT" python3 -c "import apt_pkg" 2>/dev/null; then
			return 0
		fi

		print_warn "apt_pkg module not loadable — attempting fix..."

		# Find any existing apt_pkg .so file
		local existing_so
		existing_so=$(find "$apt_pkg_dir" -name "apt_pkg.cpython-*.so" 2>/dev/null | head -1)

		if [[ -z "$existing_so" ]]; then
			# Try to reinstall python3-apt inside the chroot
			print_status "No apt_pkg .so found — attempting to reinstall python3-apt..."
			chroot "$MOUNT_ROOT" apt-get install --reinstall -y python3-apt 2>/dev/null || true
			existing_so=$(find "$apt_pkg_dir" -name "apt_pkg.cpython-*.so" 2>/dev/null | head -1)
		fi

		if [[ -n "$existing_so" ]]; then
			local target_name="apt_pkg.cpython-${chroot_py_ver}-x86_64-linux-gnu.so"
			local target_path="$apt_pkg_dir/$target_name"
			if [[ ! -f "$target_path" ]]; then
				print_status "Symlinking $(basename "$existing_so") -> $target_name"
				ln -sf "$(basename "$existing_so")" "$target_path"
			fi

			# Verify the fix worked
			if chroot "$MOUNT_ROOT" python3 -c "import apt_pkg" 2>/dev/null; then
				print_success "apt_pkg module fixed"
			else
				print_warn "apt_pkg still not loadable — update-grub may show warnings"
			fi
		else
			print_warn "No apt_pkg .so found on the installed system"
			print_warn "update-grub may show Python import errors (usually non-fatal)"
		fi
	}
	fix_apt_pkg

	# Determine the grub-install command based on firmware type
	local grub_install_cmd
	if "$IS_EFI"; then
		# Find the EFI directory path relative to chroot
		local efi_dir="/boot/efi"
		if [[ -f "$MOUNT_ROOT/etc/fstab" ]]; then
			local fstab_efi
			fstab_efi=$(grep -E "/boot/efi|/efi" "$MOUNT_ROOT/etc/fstab" 2>/dev/null |
				grep -v "^#" | awk '{print $2}' | head -1)
			[[ -n "$fstab_efi" ]] && efi_dir="$fstab_efi"
		fi
		grub_install_cmd="grub-install --target=x86_64-efi --efi-directory=$efi_dir --bootloader-id=ubuntu --recheck"
	else
		grub_install_cmd="grub-install --target=i386-pc --recheck $DISK_DEV"
	fi

	print_info "GRUB install command: $grub_install_cmd"
	print_info "Target disk: $DISK_DEV"
	echo

	# Step 1: update-grub (regenerate grub.cfg)
	print_status "Running update-grub inside chroot..."
	if chroot "$MOUNT_ROOT" update-grub 2>&1; then
		print_success "update-grub completed"
	else
		print_warn "update-grub reported issues — checking if grub.cfg was generated..."
		if [[ -f "$MOUNT_ROOT/boot/grub/grub.cfg" ]]; then
			print_info "grub.cfg exists — continuing"
		else
			die "update-grub failed and no grub.cfg found. Cannot proceed."
		fi
	fi

	# Step 2: grub-install
	print_status "Running grub-install inside chroot..."
	if chroot "$MOUNT_ROOT" /bin/bash -c "$grub_install_cmd" 2>&1; then
		print_success "grub-install completed"
	else
		print_error "grub-install failed."
		# Try fallback: install without --recheck
		print_status "Attempting fallback grub-install..."
		local fallback_cmd="${grub_install_cmd//--recheck/}"
		if chroot "$MOUNT_ROOT" /bin/bash -c "$fallback_cmd" 2>&1; then
			print_success "Fallback grub-install succeeded"
		else
			die "grub-install failed. Check the output above for details."
		fi
	fi

	# Step 3: Verify
	print_status "Verifying GRUB installation..."
	if [[ -f "$MOUNT_ROOT/boot/grub/grub.cfg" ]]; then
		local kernel_count
		kernel_count=$(grep -c "menuentry " "$MOUNT_ROOT/boot/grub/grub.cfg" 2>/dev/null || echo 0)
		print_success "grub.cfg present with $kernel_count menu entries"
	else
		print_warn "grub.cfg not found at expected location"
	fi

	if "$IS_EFI"; then
		local efi_grub="$MOUNT_ROOT/boot/efi/EFI/ubuntu/grubx64.efi"
		if [[ -f "$efi_grub" ]]; then
			print_success "EFI GRUB binary present: grubx64.efi"
		else
			# Check alternate locations
			local found_efi
			found_efi=$(find "$MOUNT_ROOT/boot/efi/EFI" -name "grub*.efi" 2>/dev/null | head -1)
			if [[ -n "$found_efi" ]]; then
				print_success "EFI GRUB binary found: ${found_efi#"$MOUNT_ROOT"}"
			else
				print_warn "EFI GRUB binary not found — UEFI boot may not work"
			fi
		fi
	fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
	print_header "GRUB Auto-Repair for Ubuntu/Proxmox"
	echo -e "    This script will detect and repair the GRUB bootloader on your"
	echo -e "    installed Proxmox/Ubuntu system from the live environment."
	echo

	check_prerequisites
	detect_disk_and_partitions
	run_fsck_on_partitions
	mount_system
	repair_grub

	# Cleanup happens automatically via trap
	print_header "GRUB Repair Complete"
	echo -e "    ${GREEN}${BOLD}GRUB has been successfully repaired.${NC}"
	echo
	echo -e "    Next steps:"
	echo -e "      1. Remove the live CD/USB media"
	echo -e "      2. Reboot: ${CYAN}sudo reboot${NC}"
	echo
	if "$IS_EFI"; then
		echo -e "    ${YELLOW}Tip:${NC} If the system still doesn't boot, check your UEFI boot"
		echo -e "    order in the BIOS/firmware settings. The entry should be 'ubuntu'."
	fi
	echo
}

main "$@"
