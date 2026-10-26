#!/usr/bin/env bash
# setup/modules/macos-tweaks.sh - macOS system tweaks: Wi-Fi roaming, VRAM. Sourced.

# Append LINE to root's crontab only if an exact match is absent.
_root_cron_once() {
	local line="$1"
	if ! sudo crontab -l 2>/dev/null | grep -qF -- "$line"; then
		{
			sudo crontab -l 2>/dev/null || true
			printf '%s\n' "$line"
		} | sudo crontab -
	fi
}

# Roam to the strongest access point on each boot (multi-AP Wi-Fi).
mod_macos_tweaks() {
	require_os macos
	info "Enabling strongest-AP Wi-Fi roaming on boot"
	_root_cron_once "@reboot sudo /System/Library/PrivateFrameworks/Apple80211.framework/Versions/A/Resources/airport prefs joinMode=Strongest"
	good "macOS tweaks applied"
}

# Raise the Apple Silicon unified-memory cap available to the GPU, applied now
# and re-applied on every boot (macOS does not persist sysctl across reboots).
mod_vram() {
	require_os macos
	local mb="${LI_VRAM_LIMIT_MB:-114688}"
	info "Setting GPU wired-memory limit to ${mb}MB"
	sudo sysctl "iogpu.wired_limit_mb=$mb"
	_root_cron_once "@reboot sudo sysctl iogpu.wired_limit_mb=$mb"
	good "VRAM limit set to ${mb}MB (applied now and on every boot)"
}
