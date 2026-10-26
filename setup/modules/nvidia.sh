#!/usr/bin/env bash
# setup/modules/nvidia.sh - NVIDIA open driver + mismatch reboot guard. Sourced.

mod_nvidia() {
	require_os linux
	if ! lspci 2>/dev/null | grep -qi nvidia; then
		hint "No NVIDIA GPU detected; skipping driver installation"
		return 0
	fi
	local gpu
	gpu="$(lspci | grep -i nvidia | head -n1 | sed 's/.*: //')"
	info "NVIDIA GPU detected: $gpu"
	_nvidia_install_driver
	_nvidia_mismatch_guard
	good "NVIDIA setup complete"
}

_nvidia_install_driver() {
	if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
		local existing
		existing="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1)"
		good "NVIDIA driver already installed (version $existing); skipping"
		return 0
	fi
	info "Installing the recommended open kernel-module driver"
	local pkg=""
	best_effort pkg_install ubuntu-drivers-common
	if command -v ubuntu-drivers >/dev/null 2>&1; then
		pkg="$(ubuntu-drivers devices 2>/dev/null | grep -oP 'nvidia-driver-\d+-open' | sort -t- -k3 -n | tail -n1)"
	fi
	if [[ -z "$pkg" ]]; then
		warn "ubuntu-drivers found no -open driver; falling back to apt-cache"
		pkg="$(apt-cache pkgnames nvidia-driver- 2>/dev/null | grep -E '^nvidia-driver-[0-9]+-open$' | sort -t- -k3 -n | tail -n1)"
	fi
	if [[ -n "$pkg" ]]; then
		info "Installing $pkg"
		if apt-get install -y "$pkg"; then
			good "$pkg installed; reboot required to activate the driver"
		else
			warn "failed to install $pkg; install the driver manually after reboot"
		fi
	else
		warn "could not determine an NVIDIA open driver package; install manually"
	fi
}

# An upgraded userspace driver beside the still-loaded old kernel module breaks
# CUDA for every new process, yet creates no /var/run/reboot-required, so
# unattended-upgrades never reboots for it. Hold the driver back and reboot
# whenever the loaded and installed module versions diverge.
_nvidia_mismatch_guard() {
	info "Installing the NVIDIA driver mismatch guard"
	cat >/etc/apt/apt.conf.d/51unattended-upgrades-nvidia <<-'EOF'
		// NVIDIA driver upgrades need a reboot to load the new kernel module; until
		// then CUDA fails in every new process. Upgrade the driver by hand, then reboot.
		Unattended-Upgrade::Package-Blacklist {
		    "(lib)?nvidia-";
		    "xserver-xorg-video-nvidia-";
		};
	EOF

	cat >/etc/default/nvidia-mismatch-reboot <<-'EOF'
		# When to reboot after the loaded NVIDIA kernel module diverges from the
		# installed one: a shutdown(8) time ("04:30", "+5") or "now".
		REBOOT_AT=04:30
	EOF

	cat >/usr/local/sbin/nvidia-mismatch-reboot <<-'EOF'
		#!/bin/bash
		# Schedules a reboot when the loaded NVIDIA kernel module differs from the one
		# installed on disk (driver upgraded without a reboot).
		# Usage: nvidia-mismatch-reboot [--dry-run]   (config: /etc/default/nvidia-mismatch-reboot)
		set -euo pipefail

		dry_run=0
		[[ "${1:-}" == "--dry-run" ]] && dry_run=1

		REBOOT_AT=04:30
		# shellcheck source=/dev/null
		[[ -r /etc/default/nvidia-mismatch-reboot ]] && . /etc/default/nvidia-mismatch-reboot

		state_dir=/var/lib/nvidia-mismatch-reboot

		if [[ ! -r /sys/module/nvidia/version ]]; then
		    echo "nvidia kernel module not loaded; nothing to compare"
		    exit 0
		fi
		loaded=$(< /sys/module/nvidia/version)
		installed=$(modinfo -F version nvidia)

		if [[ "$loaded" == "$installed" ]]; then
		    echo "nvidia module in sync: $loaded"
		    exit 0
		fi

		pair="$loaded -> $installed"
		echo "nvidia module mismatch: loaded $loaded, installed $installed"

		if [[ -e /run/systemd/shutdown/scheduled ]]; then
		    echo "reboot already scheduled; leaving it in place"
		    exit 0
		fi

		# Scheduled for this exact pair, and the machine has booted since, yet the
		# mismatch remains (e.g. the new module fails to build or load): rebooting
		# again would loop forever.
		stamp="$state_dir/rebooted-for"
		boot_epoch=$(awk '/^btime/ {print $2}' /proc/stat)
		if [[ -r "$stamp" && "$(< "$stamp")" == "$pair" ]] && (( $(stat -c %Y "$stamp") < boot_epoch )); then
		    echo "rebooted once for $pair without effect; refusing to reboot again" >&2
		    exit 1
		fi

		if (( dry_run )); then
		    echo "dry run: would schedule reboot at $REBOOT_AT"
		    exit 0
		fi

		mkdir -p "$state_dir"
		printf '%s\n' "$pair" > "$state_dir/rebooted-for"
		shutdown -r "$REBOOT_AT" "NVIDIA driver upgraded ($pair); rebooting to load the new kernel module"
	EOF
	chmod 755 /usr/local/sbin/nvidia-mismatch-reboot

	cat >/etc/systemd/system/nvidia-mismatch-reboot.service <<-'EOF'
		[Unit]
		Description=Reboot when the loaded NVIDIA kernel module differs from the installed driver

		[Service]
		Type=oneshot
		ExecStart=/usr/local/sbin/nvidia-mismatch-reboot
	EOF
	cat >/etc/systemd/system/nvidia-mismatch-reboot.timer <<-'EOF'
		[Unit]
		Description=Check for NVIDIA driver/kernel-module mismatch every 10 minutes

		[Timer]
		OnBootSec=10min
		OnUnitActiveSec=10min

		[Install]
		WantedBy=timers.target
	EOF
	systemctl daemon-reload
	systemctl enable --now nvidia-mismatch-reboot.timer
	good "NVIDIA mismatch guard installed (driver held from unattended upgrades; reboot at 04:30 on mismatch)"
}
