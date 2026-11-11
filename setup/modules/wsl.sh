#!/usr/bin/env bash
# setup/modules/wsl.sh - mod_wsl_config and mod_wsl_memory: tune the Windows-side .wslconfig of a WSL VM. Sourced.
#
# Windows reads %UserProfile%\.wslconfig when the VM starts. Without autoMemoryReclaim the VM keeps every
# page of file cache it ever used, so Task Manager shows it near its cap long after the work has ended.
# Without a memory= cap the VM may grow to half the PC's RAM, which is too much on a big machine that also
# gives GPU memory out of the same RAM.

WSL_RECLAIM_SECTION="experimental"
WSL_RECLAIM_KEY="autoMemoryReclaim"
WSL_RECLAIM_VALUE="gradual"

WSL_MEMORY_SECTION="wsl2"
WSL_MEMORY_KEY="memory"
WSL_MEMORY_CAP_GB=32

# wslconfig_get FILE SECTION KEY: print KEY's value inside [SECTION], matching names without case.
# Prints nothing when the file, the section or the key is missing; commented-out lines never count.
wslconfig_get() {
	local file="$1" section="$2" key="$3"
	[[ -e "$file" ]] || return 0
	awk -v want="$section" -v key="$key" '
		BEGIN { want = tolower(want); key = tolower(key) }
		{ line = $0; sub(/\r$/, "", line) }
		line ~ /^[ \t]*\[.*\][ \t]*$/ {
			cur = line
			gsub(/^[ \t]*\[|\][ \t]*$/, "", cur)
			cur = tolower(cur)
			next
		}
		cur != want || index(line, "=") == 0 { next }
		{
			name = substr(line, 1, index(line, "=") - 1)
			gsub(/[ \t]/, "", name)
			if (tolower(name) != key) next
			val = substr(line, index(line, "=") + 1)
			gsub(/^[ \t]+|[ \t]+$/, "", val)
			print val
			exit
		}
	' "$file"
}

# wslconfig_add FILE SECTION KEY VALUE: print FILE with KEY=VALUE added under [SECTION], creating the section
# at the end when it is absent. Existing lines, other sections and CRLF line endings are kept. The caller
# decides whether KEY is already set (wslconfig_get); this always adds.
wslconfig_add() {
	local file="$1" section="$2" key="$3" value="$4"
	[[ -e "$file" ]] || file=/dev/null
	awk -v sect="$section" -v key="$key" -v value="$value" '
		BEGIN { want = tolower(sect) }
		{
			raw = $0
			line = raw
			sub(/\r$/, "", line)
			eol = (raw == line) ? "" : "\r"
			if (eol != "") crlf = "\r"
			last = line
			print raw
			if (line ~ /^[ \t]*\[.*\][ \t]*$/) {
				cur = line
				gsub(/^[ \t]*\[|\][ \t]*$/, "", cur)
				if (!done && tolower(cur) == want) {
					print key "=" value eol
					done = 1
				}
			}
		}
		END {
			if (done) exit
			if (NR > 0 && last != "") print crlf
			print "[" sect "]" crlf
			print key "=" value crlf
		}
	' "$file"
}

# _wslconfig_path: where Windows keeps this user's .wslconfig. LI_WSLCONFIG overrides it (tests, odd setups).
_wslconfig_path() {
	if [[ -n "${LI_WSLCONFIG:-}" ]]; then
		printf '%s' "$LI_WSLCONFIG"
		return 0
	fi
	need cmd.exe "WSL interop is off; set LI_WSLCONFIG to the .wslconfig path or pass --skip wsl-config"
	need wslpath
	local win_home dir
	# From /mnt/c because cmd.exe cannot start in a \\wsl.localhost\ directory and complains on stderr.
	win_home="$(cd /mnt/c && cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')" ||
		die "could not read the Windows profile folder via cmd.exe (try: --skip wsl-config)"
	[[ -n "$win_home" ]] || die "cmd.exe returned no Windows profile folder (try: --skip wsl-config)"
	dir="$(wslpath -u "$win_home")" || die "could not convert '$win_home' to a Linux path"
	[[ -d "$dir" ]] || die "Windows profile folder not found: $dir"
	printf '%s/.wslconfig' "$dir"
}

# _wslconfig_ensure FILE SECTION KEY VALUE: add KEY=VALUE under [SECTION] unless FILE already sets KEY there.
# Never overrides a value the operator chose. Returns 0 after writing the file, 1 when it left the file as it was.
_wslconfig_ensure() {
	local cfg="$1" section="$2" key="$3" value="$4" current tmp
	current="$(wslconfig_get "$cfg" "$section" "$key")"
	if [[ "$current" == "$value" ]]; then
		good "$cfg already sets $key=$value"
		return 1
	fi
	if [[ -n "$current" ]]; then
		hint "$cfg sets $key=$current; leaving that value alone"
		return 1
	fi
	info "Setting $key=$value in $cfg"
	tmp="$(mktemp "$cfg.XXXXXX")" || die "cannot create a temp file next to $cfg"
	if wslconfig_add "$cfg" "$section" "$key" "$value" >"$tmp"; then
		chmod 0644 "$tmp"
		mv -f "$tmp" "$cfg"
	else
		rm -f "$tmp"
		die "could not build the new .wslconfig"
	fi
}

_wslconfig_restart_note() {
	info "WSL reads .wslconfig only when the VM starts: run 'wsl --shutdown' from Windows, then reopen this distro."
}

# mod_wsl_config: set autoMemoryReclaim=gradual in the Windows-side .wslconfig unless it already has a value.
# Never shuts WSL down (that would kill this run).
mod_wsl_config() {
	require_os wsl
	local cfg
	cfg="$(_wslconfig_path)"
	if _wslconfig_ensure "$cfg" "$WSL_RECLAIM_SECTION" "$WSL_RECLAIM_KEY" "$WSL_RECLAIM_VALUE"; then
		good "Idle VM memory now returns to Windows"
		_wslconfig_restart_note
	fi
}

# _wsl_host_ram_mib: the physical RAM Windows reports, in MiB. Inside the VM /proc/meminfo shows the VM's own
# cap, so only Windows knows the real figure. LI_WSL_HOST_RAM_MIB overrides it (tests, odd setups).
_wsl_host_ram_mib() {
	if [[ -n "${LI_WSL_HOST_RAM_MIB:-}" ]]; then
		printf '%s' "$LI_WSL_HOST_RAM_MIB"
		return 0
	fi
	need powershell.exe "WSL interop is off; set LI_WSL_HOST_RAM_MIB to the PC's RAM in MiB or pass --skip wsl-memory"
	local bytes
	bytes="$(powershell.exe -NoProfile -Command '(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory' 2>/dev/null | tr -d '\r')" ||
		die "could not read the PC's RAM via powershell.exe (try: --skip wsl-memory)"
	[[ "$bytes" =~ ^[0-9]+$ ]] || die "powershell.exe returned '$bytes' for the PC's RAM, expected a byte count (try: --skip wsl-memory)"
	printf '%s' "$((bytes / 1048576))"
}

# wsl_memory_gb RAM_MIB: half of RAM_MIB rounded to the nearest whole GiB, never above WSL_MEMORY_CAP_GB.
# Rounds to nearest because Windows reports a "16 GB" PC as about 15.9 GiB and half of that should read 8.
wsl_memory_gb() {
	local ram_mib="$1" gb
	[[ "$ram_mib" =~ ^[0-9]+$ ]] || die "PC RAM must be a whole number of MiB, got '$ram_mib'"
	gb=$(((ram_mib + 1024) / 2048))
	((gb >= 1)) || die "PC RAM of $ram_mib MiB is too small to size WSL from"
	if ((gb > WSL_MEMORY_CAP_GB)); then
		gb="$WSL_MEMORY_CAP_GB"
	fi
	printf '%s' "$gb"
}

# mod_wsl_memory: cap the WSL VM at half the PC's RAM, at most WSL_MEMORY_CAP_GB, by setting memory= in the
# Windows-side .wslconfig unless it already has a value. Never shuts WSL down (that would kill this run).
mod_wsl_memory() {
	require_os wsl
	local cfg ram_mib gb size
	cfg="$(_wslconfig_path)" || return 1
	ram_mib="$(_wsl_host_ram_mib)" || return 1
	gb="$(wsl_memory_gb "$ram_mib")" || return 1
	size="${gb}GB"
	info "PC RAM is $(awk -v m="$ram_mib" 'BEGIN { printf "%.1f", m / 1024 }') GiB; half, capped at ${WSL_MEMORY_CAP_GB}GB, is $size"
	if _wslconfig_ensure "$cfg" "$WSL_MEMORY_SECTION" "$WSL_MEMORY_KEY" "$size"; then
		good "The WSL VM is now capped at $size"
		_wslconfig_restart_note
	fi
}
