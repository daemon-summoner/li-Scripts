#!/usr/bin/env bash
# setup/modules/wsl.sh - mod_wsl_config: let a WSL VM hand idle memory back to Windows. Sourced.
#
# Windows reads %UserProfile%\.wslconfig when the VM starts. Without autoMemoryReclaim the VM keeps every
# page of file cache it ever used, so Task Manager shows it near its cap long after the work has ended.

WSL_RECLAIM_SECTION="experimental"
WSL_RECLAIM_KEY="autoMemoryReclaim"
WSL_RECLAIM_VALUE="gradual"

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

# mod_wsl_config: set autoMemoryReclaim=gradual in the Windows-side .wslconfig unless it already has a value.
# Never overrides a value the operator chose, and never shuts WSL down (that would kill this run).
mod_wsl_config() {
	require_os wsl
	local cfg current tmp
	cfg="$(_wslconfig_path)"
	current="$(wslconfig_get "$cfg" "$WSL_RECLAIM_SECTION" "$WSL_RECLAIM_KEY")"
	if [[ "$current" == "$WSL_RECLAIM_VALUE" ]]; then
		good "$cfg already sets $WSL_RECLAIM_KEY=$WSL_RECLAIM_VALUE"
		return 0
	fi
	if [[ -n "$current" ]]; then
		hint "$cfg sets $WSL_RECLAIM_KEY=$current; leaving that value alone"
		return 0
	fi
	info "Setting $WSL_RECLAIM_KEY=$WSL_RECLAIM_VALUE in $cfg"
	tmp="$(mktemp "$cfg.XXXXXX")" || die "cannot create a temp file next to $cfg"
	if wslconfig_add "$cfg" "$WSL_RECLAIM_SECTION" "$WSL_RECLAIM_KEY" "$WSL_RECLAIM_VALUE" >"$tmp"; then
		chmod 0644 "$tmp"
		mv -f "$tmp" "$cfg"
	else
		rm -f "$tmp"
		die "could not build the new .wslconfig"
	fi
	good "Idle VM memory now returns to Windows"
	info "WSL reads .wslconfig only when the VM starts: run 'wsl --shutdown' from Windows, then reopen this distro."
}
