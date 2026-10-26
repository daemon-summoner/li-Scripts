#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# format_usb_windows_11.sh
#
# Creates a UEFI-bootable Windows 11 installer USB from an ISO on macOS
# (Rufus-equivalent). Erases the chosen USB to a single FAT32/MBR volume,
# copies the ISO contents, splits an oversized install.wim into .swm chunks,
# and writes an autounattend.xml that bypasses the TPM 2.0 / Secure Boot / RAM
# checks and enables local-account setup (no Microsoft login required).
#
# Usage:
#   chmod +x format_usb_windows_11.sh
#   ./format_usb_windows_11.sh <path/to/win11.iso> [diskN]
#   ./format_usb_windows_11.sh --list
#
# Options:
#   --list         List candidate USB disks and exit (no changes made)
#   --no-bypass    Do not write autounattend.xml (keep stock install checks)
#   -h, --help     Show this help
#
# Example:
#   ./format_usb_windows_11.sh ~/Downloads/Win11_24H2_English_x64.iso
# ──────────────────────────────────────────────────────────────────────────────

VOLUME_LABEL="WIN11"       # FAT32 label: uppercase, max 11 chars
FAT32_MAX_BYTES=4294967296 # FAT32 single-file limit (4 GiB)
SWM_CHUNK_MB=3800          # .swm split size (MiB), safely under the limit
MIN_DISK_BYTES=8000000000  # 8 GB minimum target disk

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() {
	echo -e "${RED}[ERROR]${NC} $*"
	exit 1
}

ISO_PATH=""
PRESELECT=""
LIST_ONLY=0
WRITE_BYPASS=1
ISO_MOUNT=""
ISO_DEV=""
TARGET_DISK=""
USB_MOUNT=""
INSTALL_IMG=""
INSTALL_IMG_SIZE=0
NEEDS_SPLIT=0

# Detach the ISO on any exit; never touches the target disk so an abort
# mid-write leaves it inspectable instead of triggering more destruction.
cleanup() {
	if [[ -n "$ISO_DEV" ]]; then
		hdiutil detach "/dev/$ISO_DEV" -quiet 2>/dev/null || true
	fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

usage() {
	cat <<'USAGE'
Usage:
  format_usb_windows_11.sh <path/to/win11.iso> [diskN]
  format_usb_windows_11.sh --list

Creates a UEFI-bootable Windows 11 installer USB (Rufus-equivalent) on macOS.
ERASES the chosen USB disk: single FAT32 partition (MBR), ISO contents copied,
install.wim split into FAT32-sized .swm chunks, plus an autounattend.xml that
disables the TPM 2.0 / Secure Boot / RAM checks and allows creating a local
account without a Microsoft login.

Arguments:
  <path/to/win11.iso>  Windows 11 ISO (required unless --list)
  [diskN]              Pre-select the target disk (e.g. disk4); interactive
                       menu when omitted. Erase still requires confirmation.

Options:
  --list         List candidate USB disks and exit (no changes made)
  --no-bypass    Do not write autounattend.xml (keep stock install checks)
  -h, --help     Show this help
USAGE
}

require_macos() {
	[[ "$(uname -s)" == "Darwin" ]] || error "This script only runs on macOS"
}

parse_args() {
	while (($#)); do
		case "$1" in
		-h | --help)
			usage
			exit 0
			;;
		--list) LIST_ONLY=1 ;;
		--no-bypass) WRITE_BYPASS=0 ;;
		-*)
			usage >&2
			error "Unknown option: $1"
			;;
		*)
			if [[ -z "$ISO_PATH" ]]; then
				ISO_PATH="$1"
			elif [[ -z "$PRESELECT" ]]; then
				PRESELECT="${1#/dev/}"
			else
				error "Unexpected argument: $1"
			fi
			;;
		esac
		shift
	done

	if ((LIST_ONLY)); then
		return 0
	fi
	if [[ -z "$ISO_PATH" ]]; then
		usage >&2
		error "Missing required argument: path to the Windows 11 ISO"
	fi
	[[ -f "$ISO_PATH" ]] || error "ISO not found or not a regular file: $ISO_PATH"
	if [[ "$ISO_PATH" != *.iso && "$ISO_PATH" != *.ISO ]]; then
		warn "'$ISO_PATH' does not end in .iso -- proceeding anyway"
	fi
	if [[ -n "$PRESELECT" && ! "$PRESELECT" =~ ^disk[0-9]+$ ]]; then
		error "Invalid disk identifier: '$PRESELECT' (expected e.g. disk4)"
	fi
}

ensure_tool() {
	local cmd="$1" formula="$2"
	if command -v "$cmd" &>/dev/null; then
		return 0
	fi
	command -v brew &>/dev/null || error "'$cmd' is required (brew install $formula), but Homebrew is not installed: https://brew.sh"
	info "Installing $formula via brew..."
	brew install "$formula"
	command -v "$cmd" &>/dev/null || error "'$cmd' still not found after installing $formula"
}

# Prints one plist scalar for a disk; empty (never fails) when the key is absent.
disk_field() {
	diskutil info -plist "$1" 2>/dev/null | plutil -extract "$2" raw -o - - 2>/dev/null || true
}

# External physical whole-disk identifiers, one per line (excludes internal
# disks and virtual devices such as the attached ISO by construction).
list_usb_disks() {
	local plist count i
	plist="$(diskutil list -plist external physical)"
	count="$(plutil -extract WholeDisks raw -o - - <<<"$plist" 2>/dev/null)" || count=0
	for ((i = 0; i < count; i++)); do
		plutil -extract "WholeDisks.$i" raw -o - - <<<"$plist"
	done
}

print_disk_row() {
	local disk="$1" name size gb proto removable
	name="$(disk_field "$disk" MediaName)"
	[[ -n "$name" ]] || name="(unknown)"
	size="$(disk_field "$disk" Size)"
	[[ -n "$size" ]] || size=0
	gb="$(awk -v b="$size" 'BEGIN { printf "%.1f GB", b / 1e9 }')"
	proto="$(disk_field "$disk" BusProtocol)"
	[[ -n "$proto" ]] || proto="?"
	removable="$(disk_field "$disk" Removable)"
	if [[ "$removable" == "true" ]]; then removable="removable"; else removable="fixed"; fi
	printf '%-8s %-30s %10s  %-10s %s' "$disk" "$name" "$gb" "$proto" "$removable"
}

print_usb_table() {
	local d found=0
	while IFS= read -r d; do
		found=1
		printf '  %s\n' "$(print_disk_row "$d")"
	done < <(list_usb_disks)
	if ! ((found)); then
		warn "No external USB disks detected."
	fi
}

choose_disk() {
	local disks=() d
	while IFS= read -r d; do
		if [[ -n "$ISO_DEV" && "$d" == "$ISO_DEV" ]]; then
			continue
		fi
		disks+=("$d")
	done < <(list_usb_disks)
	((${#disks[@]})) || error "No external USB disks found. Plug in the target USB drive and re-run (or check with --list)."

	if [[ -n "$PRESELECT" ]]; then
		for d in "${disks[@]}"; do
			if [[ "$d" == "$PRESELECT" ]]; then
				TARGET_DISK="$d"
				return 0
			fi
		done
		error "'$PRESELECT' is not an attached external whole-disk. Run with --list to see candidates."
	fi

	echo
	info "Attached external disks:"
	local i=1
	for d in "${disks[@]}"; do
		printf '  %d) %s\n' "$i" "$(print_disk_row "$d")"
		i=$((i + 1))
	done
	echo
	local choice
	read -r -p "Select the disk to ERASE [1-${#disks[@]}] (anything else aborts): " choice || error "Aborted -- no changes made."
	if [[ "$choice" =~ ^[0-9]+$ ]] && ((10#$choice >= 1 && 10#$choice <= ${#disks[@]})); then
		TARGET_DISK="${disks[10#$choice - 1]}"
	else
		error "Aborted -- no changes made."
	fi
}

check_disk_size() {
	local size
	size="$(disk_field "$TARGET_DISK" Size)"
	[[ -n "$size" ]] || error "Could not read the size of $TARGET_DISK"
	((size >= MIN_DISK_BYTES)) || error "$TARGET_DISK is smaller than 8 GB -- too small for Windows 11 media"
}

confirm_destroy() {
	echo
	echo -e "${RED}==================== DATA DESTRUCTION WARNING ====================${NC}"
	echo -e "${RED}ALL data and partitions on /dev/$TARGET_DISK will be ERASED:${NC}"
	echo
	diskutil list "$TARGET_DISK"
	echo
	local answer
	read -r -p "Type the disk identifier ('$TARGET_DISK') to erase it, anything else aborts: " answer || error "Aborted -- no changes made to $TARGET_DISK."
	[[ "$answer" == "$TARGET_DISK" ]] || error "Aborted -- no changes made to $TARGET_DISK."
}

attach_iso() {
	info "Mounting ISO read-only: $ISO_PATH"
	local plist count i mp dev=""
	if ! plist="$(hdiutil attach -nobrowse -readonly -plist "$ISO_PATH")"; then
		error "Failed to attach '$ISO_PATH' -- is it a valid ISO image?"
	fi
	count="$(plutil -extract system-entities raw -o - - <<<"$plist" 2>/dev/null)" || count=0
	for ((i = 0; i < count; i++)); do
		if [[ -z "$dev" ]]; then
			dev="$(plutil -extract "system-entities.$i.dev-entry" raw -o - - <<<"$plist" 2>/dev/null || true)"
		fi
		mp="$(plutil -extract "system-entities.$i.mount-point" raw -o - - <<<"$plist" 2>/dev/null || true)"
		if [[ -n "$mp" ]]; then
			ISO_MOUNT="$mp"
			break
		fi
	done
	# Base disk identifier (strip any slice suffix) so cleanup detaches the whole
	# image; set before the mount-point check so the EXIT trap detaches on error.
	if [[ -n "$dev" ]]; then
		ISO_DEV="$(sed -E 's|^/dev/(disk[0-9]+).*|\1|' <<<"$dev")"
	fi
	if [[ -z "$ISO_MOUNT" || -z "$ISO_DEV" ]]; then
		error "Could not determine the ISO mount point -- unexpected hdiutil output"
	fi
	[[ -d "$ISO_MOUNT/sources" ]] || error "'$ISO_PATH' does not look like Windows installation media (no sources/ directory)"
	info "ISO mounted at: $ISO_MOUNT ($ISO_DEV)"
}

detect_install_image() {
	local ext
	for ext in wim esd; do
		if [[ -f "$ISO_MOUNT/sources/install.$ext" ]]; then
			INSTALL_IMG="install.$ext"
			break
		fi
	done
	[[ -n "$INSTALL_IMG" ]] || error "ISO has neither sources/install.wim nor sources/install.esd"
	INSTALL_IMG_SIZE="$(stat -f%z "$ISO_MOUNT/sources/$INSTALL_IMG")"
	if ((INSTALL_IMG_SIZE >= FAT32_MAX_BYTES)); then
		NEEDS_SPLIT=1
		info "$INSTALL_IMG is $(awk -v b="$INSTALL_IMG_SIZE" 'BEGIN { printf "%.2f GiB", b / 1073741824 }') -- exceeds the FAT32 4 GiB limit, will split into .swm chunks"
		ensure_tool wimlib-imagex wimlib
	else
		NEEDS_SPLIT=0
	fi
}

erase_and_partition() {
	info "Unmounting /dev/$TARGET_DISK..."
	diskutil unmountDisk force "/dev/$TARGET_DISK"
	info "Erasing /dev/$TARGET_DISK as FAT32 '$VOLUME_LABEL' (MBR)..."
	diskutil eraseDisk MS-DOS "$VOLUME_LABEL" MBR "/dev/$TARGET_DISK"

	local _try
	for _try in 1 2 3 4 5; do
		USB_MOUNT="$(disk_field "${TARGET_DISK}s1" MountPoint)"
		if [[ -n "$USB_MOUNT" ]]; then
			break
		fi
		sleep 1
	done
	if [[ -z "$USB_MOUNT" || ! -d "$USB_MOUNT" ]]; then
		error "The FAT32 volume did not mount after the erase (expected /Volumes/$VOLUME_LABEL)"
	fi
	info "USB volume mounted at: $USB_MOUNT"
}

# Minimal flag set supported by both classic rsync and openrsync; FAT32 stores
# no perms/owners/symlinks. --modify-window absorbs FAT's 2s mtime granularity.
run_iso_rsync() {
	rsync -rt --modify-window=1 --progress \
		--exclude 'sources/install.wim' --exclude 'sources/install.esd' \
		"$ISO_MOUNT"/ "$USB_MOUNT"/
}

copy_iso_files() {
	info "Copying installer files (excluding sources/$INSTALL_IMG)..."
	local rc=0
	run_iso_rsync || rc=$?
	if ((rc == 23 || rc == 24)); then
		# openrsync uses 23 for genuine partial-copy failures; a retry that
		# exits 0 proves every file made it, otherwise the media is incomplete.
		warn "rsync reported a partial transfer (exit $rc) -- retrying to verify completeness"
		rc=0
		run_iso_rsync || rc=$?
	fi
	((rc == 0)) || error "rsync failed (exit $rc) -- the installer media would be incomplete"
}

handle_install_image() {
	if ((NEEDS_SPLIT)); then
		info "Splitting $INSTALL_IMG into ${SWM_CHUNK_MB} MiB .swm chunks (Windows Setup consumes these natively)..."
		wimlib-imagex split "$ISO_MOUNT/sources/$INSTALL_IMG" "$USB_MOUNT/sources/install.swm" "$SWM_CHUNK_MB"
	else
		info "Copying sources/$INSTALL_IMG (fits within FAT32 limits)..."
		cp "$ISO_MOUNT/sources/$INSTALL_IMG" "$USB_MOUNT/sources/"
	fi
}

write_autounattend() {
	if [[ -f "$ISO_MOUNT/autounattend.xml" ]]; then
		warn "The ISO ships its own autounattend.xml -- replacing the USB copy with the bypass version (use --no-bypass to keep the original)"
	fi
	info "Writing autounattend.xml (bypass TPM/Secure Boot/RAM checks, allow local account)..."
	cat >"$USB_MOUNT/autounattend.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
    <settings pass="specialize">
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <OOBE>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
            </OOBE>
        </component>
    </settings>
</unattend>
XML
}

finalize() {
	info "Flushing writes to disk..."
	sync
	info "Ejecting /dev/$TARGET_DISK..."
	if ! diskutil eject "/dev/$TARGET_DISK"; then
		warn "Volume written successfully but could not be ejected (disk busy?) -- eject it manually before unplugging"
	fi
	echo
	info "Done -- bootable Windows 11 USB '$VOLUME_LABEL' created."
	echo
	echo "Next steps:"
	echo "  1. Plug the USB into the target PC and open its boot menu (often F12/F11/Esc)."
	echo "  2. Pick the UEFI entry for the USB drive."
	if ((WRITE_BYPASS)); then
		echo "  3. TPM/Secure Boot/RAM checks are bypassed automatically."
		echo "  4. For a local account: at the network screen choose 'I don't have internet'"
		echo "     -> 'Continue with limited setup' (enabled by the bundled autounattend.xml)."
	fi
}

main() {
	require_macos
	parse_args "$@"
	if ((LIST_ONLY)); then
		info "External physical whole-disks (USB candidates):"
		print_usb_table
		exit 0
	fi
	attach_iso
	detect_install_image
	choose_disk
	check_disk_size
	confirm_destroy
	erase_and_partition
	copy_iso_files
	handle_install_image
	if ((WRITE_BYPASS)); then
		write_autounattend
	fi
	finalize
}

main "$@"
