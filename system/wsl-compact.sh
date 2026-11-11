#!/usr/bin/env bash
# wsl-compact.sh - give disk space freed inside this WSL distro back to Windows. STOPS WSL and every container in it.
#   wsl-compact.sh [--print] [--yes]    --print: show the sizes and the manual steps only; --yes: skip the prompt
# --- end usage ---
set -Eeuo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/../lib/common.sh"
# shellcheck source=lib/platform.sh
source "$HERE/../lib/platform.sh"

# Windows never shrinks a distro's ext4.vhdx by itself, so deleting files in Linux frees nothing on C:. The disk is
# not made sparse: that mode sits behind wsl --allow-unsafe (reported ext4 corruption) and blocks the compact below.

# distro_name: this distro's name. It is pasted into a PowerShell string, so only plain characters pass.
distro_name() {
	local name="${WSL_DISTRO_NAME:-}" plain='^[A-Za-z0-9._ -]+$'
	[[ -n "$name" ]] || die "WSL_DISTRO_NAME is not set; run this from inside the WSL distro"
	[[ "$name" =~ $plain ]] || die "unsupported characters in the distro name '$name'"
	printf '%s' "$name"
}

# vhd_windows_path NAME: the Windows path of NAME's virtual disk, read from the Lxss registry key.
vhd_windows_path() {
	local name="$1" ps out base file prefix=$'\\\\?\\' sep=$'\\'
	ps="$(
		cat <<'EOF'
$k = Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' |
    ForEach-Object { Get-ItemProperty -LiteralPath $_.PSPath } |
    Where-Object { $_.DistributionName -eq '__DISTRO__' } | Select-Object -First 1
if (-not $k) { exit 3 }
$k.BasePath
$k.VhdFileName
EOF
	)"
	ps="${ps%%__DISTRO__*}${name}${ps#*__DISTRO__}"
	out="$(powershell.exe -NoProfile -NonInteractive -Command "$ps" | tr -d '\r')" ||
		die "distro '$name' is not registered for this Windows user (try: wsl.exe -l -v)"
	{
		IFS= read -r base || true
		IFS= read -r file || true
	} <<<"$out"
	[[ -n "$base" ]] || die "no BasePath for distro '$name' in the Windows registry"
	base="${base#"$prefix"}"
	base="${base%"$sep"}"
	printf '%s\\%s' "$base" "${file:-ext4.vhdx}"
}

# compact_script VHD: the PowerShell that runs elevated. It stops WSL, waits until Windows lets go of the disk,
# compacts it, and always detaches it again, even when the compact fails.
compact_script() {
	local vhd="${1//\'/\'\'}" ps
	ps="$(
		cat <<'EOF'
$ErrorActionPreference = 'Stop'
$vhd = '__VHD__'
$before = (Get-Item -LiteralPath $vhd).Length
try {
    Write-Host 'Stopping WSL...'
    wsl.exe --shutdown
    for ($i = 0; $i -lt 30; $i++) {
        try { [IO.File]::Open($vhd, 'Open', 'ReadWrite', 'None').Close(); break } catch { Start-Sleep -Seconds 2 }
    }
    $dp = [IO.Path]::GetTempFileName()
    try {
        Set-Content -LiteralPath $dp -Encoding ASCII -Value "select vdisk file=`"$vhd`"", 'attach vdisk readonly', 'compact vdisk'
        diskpart.exe /s $dp
        if ($LASTEXITCODE -ne 0) { throw "diskpart exited with $LASTEXITCODE" }
    } finally {
        Set-Content -LiteralPath $dp -Encoding ASCII -Value "select vdisk file=`"$vhd`"", 'detach vdisk'
        diskpart.exe /s $dp | Out-Null
        Remove-Item -LiteralPath $dp -Force
    }
    $after = (Get-Item -LiteralPath $vhd).Length
    Write-Host ('Done: {0:N1} GiB -> {1:N1} GiB' -f ($before / 1GB), ($after / 1GB))
} catch {
    Write-Host "FAILED: $_" -ForegroundColor Red
}
Read-Host 'Press Enter to close'
EOF
	)"
	printf '%s\n' "${ps%%__VHD__*}${vhd}${ps#*__VHD__}"
}

# launch_elevated SCRIPT: run SCRIPT in an administrator PowerShell window (Windows asks for approval). It goes in as
# -EncodedCommand because a script file in a user-writable folder could be swapped before it runs with admin rights.
launch_elevated() {
	local encoded
	encoded="$(printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)"
	powershell.exe -NoProfile -NonInteractive -Command \
		"Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand','$encoded'"
}

gib() { awk -v b="$1" 'BEGIN { printf "%.1f GiB", b / 1073741824 }'; }

# manual_steps VHD: the same compact, typed by hand.
manual_steps() {
	info "From an administrator PowerShell on Windows:"
	info "  wsl --shutdown"
	info "  diskpart"
	info "    select vdisk file=\"$1\""
	info "    attach vdisk readonly"
	info "    compact vdisk"
	info "    detach vdisk"
	info "    exit"
}

main() {
	local print_only=0 assume_yes=0
	while (($#)); do
		case "$1" in
		-h | --help) usage 0 ;;
		--print) print_only=1 ;;
		--yes) assume_yes=1 ;;
		*) die "unknown argument: $1 (try: $0 --help)" ;;
		esac
		shift
	done
	require_os wsl
	need powershell.exe "WSL interop is off"
	need wslpath
	need iconv
	need base64

	local name vhd_win vhd_file vhd_bytes used_bytes
	name="$(distro_name)"
	vhd_win="$(vhd_windows_path "$name")"
	vhd_file="$(wslpath -u "$vhd_win")"
	[[ -f "$vhd_file" ]] || die "virtual disk not found: $vhd_win"
	vhd_bytes="$(stat -c %s "$vhd_file")"
	used_bytes="$(df -B1 --output=used / | tail -n 1 | tr -d ' ')"

	step "WSL disk: $name"
	info "Windows holds $(gib "$vhd_bytes") for this distro; Linux uses $(gib "$used_bytes") of it."
	if ((vhd_bytes - used_bytes < 1073741824)); then
		good "Nothing worth compacting: less than 1 GiB would come back."
		return 0
	fi
	info "Compacting returns about $(gib $((vhd_bytes - used_bytes))) to Windows."
	if ((print_only)); then
		manual_steps "$vhd_win"
		return 0
	fi
	if ((!assume_yes)) && ! confirm "This stops WSL, this terminal and every container in it. Compact now?" n; then
		hint "Cancelled; nothing was stopped."
		manual_steps "$vhd_win"
		return 0
	fi
	launch_elevated "$(compact_script "$vhd_win")" || {
		warn "could not start the elevated compact (was the Windows prompt declined?)"
		manual_steps "$vhd_win"
		return 1
	}
	good "Compact started in an administrator window; this terminal closes when WSL stops."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
