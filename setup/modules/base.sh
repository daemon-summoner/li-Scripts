#!/usr/bin/env bash
# setup/modules/base.sh - Linux apt preamble run before core packages. Sourced.

mod_base() {
	require_os linux
	_base_cleanup_repositories
	_base_backup
	_base_apt_compat
	_base_preconfigure
	_base_upgrade
	good "Base system prepared"
}

# Drop stale repository definitions (old Kubernetes lists/keys) and clear the
# apt cache, so a fresh index is fetched.
_base_cleanup_repositories() {
	info "Cleaning up old repository configurations"
	rm -f /etc/apt/sources.list.d/kubernetes*.list /usr/share/keyrings/kubernetes*.gpg
	if [[ -f /etc/apt/sources.list ]]; then
		sed -i '/apt\.kubernetes\.io/d' /etc/apt/sources.list
		sed -i '/packages\.cloud\.google\.com\/apt.*kubernetes/d' /etc/apt/sources.list
	fi
	apt-get clean
	rm -rf /var/lib/apt/lists/*
}

# Snapshot the config files this script rewrites, so a bad run can be undone.
_base_backup() {
	local dir="${LI_BACKUP_DIR:-/var/backups/ubuntu-setup}" name
	name="ubuntu-setup-$(date +%Y%m%d-%H%M%S)"
	info "Backing up system config to $dir/$name.tar.gz"
	install -d "$dir"
	best_effort tar -czf "$dir/$name.tar.gz" \
		/etc/apt/sources.list /etc/apt/sources.list.d/ \
		/etc/ssh/sshd_config /etc/ufw/ /etc/fail2ban/ \
		/home/*/.bashrc /home/*/.profile
}

# A non-system default python breaks apt's python3-apt hooks. Disable the two
# that fail, point command-not-found back at a system python, and remove the
# packages known to leave dpkg wedged, before any apt operation runs.
_base_apt_compat() {
	info "Making apt resilient to a non-system default Python"
	[[ -f /etc/apt/apt.conf.d/50command-not-found ]] &&
		mv /etc/apt/apt.conf.d/50command-not-found /etc/apt/apt.conf.d/50command-not-found.disabled
	if [[ -f /usr/lib/command-not-found ]]; then
		local sys_python
		for sys_python in python3.12 python3.11 python3.10; do
			if [[ -x "/usr/bin/$sys_python" ]]; then
				sed -i "1s|^#!/usr/bin/python3$|#!/usr/bin/$sys_python|" /usr/lib/command-not-found
				break
			fi
		done
	fi
	[[ -f /etc/apt/apt.conf.d/20listchanges ]] &&
		mv /etc/apt/apt.conf.d/20listchanges /etc/apt/apt.conf.d/20listchanges.disabled
	best_effort dpkg --remove --force-remove-reinstreq debsecan apt-listchanges samhain
	best_effort apt-get -f install -y
}

# Pre-answer debconf prompts so unattended installs never block.
_base_preconfigure() {
	info "Pre-configuring packages to avoid prompts"
	echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections
	echo "postfix postfix/mailname string $(hostname)" | debconf-set-selections
	echo "wireshark-common wireshark-common/install-setuid boolean true" | debconf-set-selections
	echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
	echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
}

_base_upgrade() {
	info "Updating and upgrading system packages"
	best_effort apt-get update
	best_effort apt-get full-upgrade -y -q
}
