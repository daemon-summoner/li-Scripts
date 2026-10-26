#!/usr/bin/env bash
# setup/modules/hardening.sh - security hardening for Linux servers. Sourced.

_LI_SECURITY_APPS="rkhunter chkrootkit clamav clamav-daemon lynis auditd apparmor-utils libpam-pwquality unattended-upgrades needrestart debsums fail2ban psad"

mod_hardening() {
	require_os linux
	info "Installing security tools"
	# shellcheck disable=SC2086  # intentional word-splitting of the package list
	pkg_install $_LI_SECURITY_APPS
	best_effort apt-get -f install -y
	best_effort dpkg --configure -a

	_harden_ufw
	_harden_fail2ban
	_harden_rkhunter
	_harden_clamav
	_harden_auditd
	_harden_auto_updates
	_harden_sysctl
	_harden_pwquality
	_harden_scan_cron
	good "Security hardening complete"
}

_harden_ufw() {
	info "Configuring firewall (UFW)"
	ufw default deny incoming
	ufw default allow outgoing
	ufw allow 22/tcp comment 'SSH'
	ufw limit 22/tcp
	ufw --force enable
}

_harden_fail2ban() {
	info "Configuring Fail2ban"
	cat >/etc/fail2ban/jail.local <<-'EOF'
		[DEFAULT]
		bantime = 3600
		findtime = 600
		maxretry = 5
		destemail = root@localhost
		sendername = Fail2Ban
		action = %(action_mwl)s

		[sshd]
		enabled = true
		port = 22
		filter = sshd
		logpath = /var/log/auth.log
		maxretry = 3
		bantime = 7200
	EOF
	systemctl enable fail2ban
	systemctl restart fail2ban
}

_harden_rkhunter() {
	info "Configuring rkhunter"
	if [[ -f /etc/rkhunter.conf ]]; then
		sed -i 's|^WEB_CMD=.*|WEB_CMD="/usr/bin/curl -fsS --connect-timeout 10"|' /etc/rkhunter.conf
		sed -i 's|^#WEB_CMD=.*|WEB_CMD="/usr/bin/curl -fsS --connect-timeout 10"|' /etc/rkhunter.conf
		sed -i 's|^#PKGMGR=.*|PKGMGR=DPKG|' /etc/rkhunter.conf
		sed -i 's|^MIRRORS_MODE=.*|MIRRORS_MODE=0|' /etc/rkhunter.conf
		sed -i 's|^#MIRRORS_MODE=.*|MIRRORS_MODE=0|' /etc/rkhunter.conf
		sed -i 's|^UPDATE_MIRRORS=.*|UPDATE_MIRRORS=1|' /etc/rkhunter.conf
		sed -i 's|^#UPDATE_MIRRORS=.*|UPDATE_MIRRORS=1|' /etc/rkhunter.conf
	fi
	# Updates frequently fail on flaky networks; never abort the run for them.
	best_effort rkhunter --update
	best_effort rkhunter --propupd
}

_harden_clamav() {
	info "Configuring ClamAV (updating virus definitions may take a moment)"
	best_effort systemctl stop clamav-freshclam
	best_effort freshclam
	best_effort systemctl start clamav-freshclam
	best_effort systemctl enable clamav-daemon
}

_harden_auditd() {
	info "Configuring auditd rules"
	cat >>/etc/audit/rules.d/audit.rules <<-'EOF'
		# Monitor sudo usage
		-w /etc/sudoers -p wa -k sudoers_changes
		-w /etc/sudoers.d/ -p wa -k sudoers_changes

		# Monitor user/group changes
		-w /etc/passwd -p wa -k passwd_changes
		-w /etc/group -p wa -k group_changes
		-w /etc/shadow -p wa -k shadow_changes

		# Monitor SSH configuration
		-w /etc/ssh/sshd_config -p wa -k sshd_config

		# Monitor system calls
		-a exit,always -F arch=b64 -S execve -k exec
		-a exit,always -F arch=b32 -S execve -k exec
	EOF
	best_effort service auditd restart
}

_harden_auto_updates() {
	info "Configuring automatic security updates"
	cat >/etc/apt/apt.conf.d/50unattended-upgrades <<-'EOF'
		Unattended-Upgrade::Allowed-Origins {
		    "${distro_id}:${distro_codename}-security";
		    "${distro_id}ESMApps:${distro_codename}-apps-security";
		    "${distro_id}ESM:${distro_codename}-infra-security";
		};
		Unattended-Upgrade::AutoFixInterruptedDpkg "true";
		Unattended-Upgrade::MinimalSteps "true";
		Unattended-Upgrade::Remove-Unused-Dependencies "true";
		Unattended-Upgrade::Automatic-Reboot "false";
		Unattended-Upgrade::Automatic-Reboot-Time "03:00";
	EOF
	cat >/etc/apt/apt.conf.d/20auto-upgrades <<-'EOF'
		APT::Periodic::Update-Package-Lists "1";
		APT::Periodic::Download-Upgradeable-Packages "1";
		APT::Periodic::AutocleanInterval "7";
		APT::Periodic::Unattended-Upgrade "1";
	EOF
}

_harden_sysctl() {
	info "Applying kernel hardening (sysctl)"
	cat >/etc/sysctl.d/99-security.conf <<-'EOF'
		# IP Spoofing protection
		net.ipv4.conf.all.rp_filter = 1
		net.ipv4.conf.default.rp_filter = 1

		# Ignore ICMP redirects
		net.ipv4.conf.all.accept_redirects = 0
		net.ipv6.conf.all.accept_redirects = 0

		# Ignore send redirects
		net.ipv4.conf.all.send_redirects = 0

		# Disable source packet routing
		net.ipv4.conf.all.accept_source_route = 0
		net.ipv6.conf.all.accept_source_route = 0

		# Log Martians
		net.ipv4.conf.all.log_martians = 1

		# Ignore ICMP ping requests to broadcast
		net.ipv4.icmp_echo_ignore_broadcasts = 1

		# Ignore bogus ICMP error responses
		net.ipv4.icmp_ignore_bogus_error_responses = 1

		# Accept ICMP redirects only for listed gateways
		net.ipv4.conf.all.secure_redirects = 1

		# Protect against TCP time-wait assassination
		net.ipv4.tcp_rfc1337 = 1

		# TCP timeouts / keepalive
		net.ipv4.tcp_fin_timeout = 15
		net.ipv4.tcp_keepalive_time = 300
		net.ipv4.tcp_keepalive_probes = 5
		net.ipv4.tcp_keepalive_intvl = 15

		# ASLR
		kernel.randomize_va_space = 2

		# Limits
		fs.file-max = 65535
		kernel.pid_max = 65535
		net.ipv4.ip_local_port_range = 2000 65000
	EOF
	best_effort sysctl -p /etc/sysctl.d/99-security.conf
}

_harden_pwquality() {
	best_effort pkg_install libpam-pwquality
	if [[ -f /etc/security/pwquality.conf ]]; then
		info "Configuring password quality"
		sed -i 's/# minlen = 8/minlen = 12/' /etc/security/pwquality.conf
		sed -i 's/# ucredit = -1/ucredit = -1/' /etc/security/pwquality.conf
		sed -i 's/# lcredit = -1/lcredit = -1/' /etc/security/pwquality.conf
		sed -i 's/# dcredit = -1/dcredit = -1/' /etc/security/pwquality.conf
		sed -i 's/# ocredit = -1/ocredit = -1/' /etc/security/pwquality.conf
	else
		warn "pwquality config not found, skipping"
	fi
}

_harden_scan_cron() {
	info "Installing daily security-scan cron job"
	cat >/etc/cron.daily/security-scans <<-'EOF'
		#!/bin/bash
		# Daily security scans
		freshclam > /dev/null 2>&1
		rkhunter --update > /dev/null 2>&1
		clamscan -r / --quiet --infected --log=/var/log/clamav/daily-scan.log
		rkhunter --check --skip-keypress --quiet
		lynis audit system --quiet
		/usr/lib/update-notifier/apt-check --human-readable > /var/log/security-updates.log
	EOF
	chmod +x /etc/cron.daily/security-scans
}
