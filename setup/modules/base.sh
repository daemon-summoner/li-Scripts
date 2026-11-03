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

# The Python that ships python3-apt (apt_pkg), found from the extension module's
# ABI tag (e.g. apt_pkg.cpython-314-*.so -> python3.14). Empty if not found.
_base_system_python() {
	local so ver
	so="$(ls /usr/lib/python3/dist-packages/apt_pkg.cpython-*.so 2>/dev/null | head -1)"
	if [[ -n "$so" ]]; then
		ver="$(basename "$so" | sed -E 's/^apt_pkg\.cpython-([0-9])([0-9]+)-.*/\1.\2/')"
		[[ -x "/usr/bin/python$ver" ]] && {
			echo "/usr/bin/python$ver"
			return 0
		}
	fi
	local c
	for c in python3.14 python3.13 python3.12 python3.11 python3.10; do
		if [[ -x "/usr/bin/$c" ]] && "/usr/bin/$c" -c 'import apt_pkg' 2>/dev/null; then
			echo "/usr/bin/$c"
			return 0
		fi
	done
	return 1
}

# Distro scripts that import apt/apt_pkg/softwareproperties but start with
# #!/usr/bin/python3, so they break once the default python3 is not the distro
# one. command-not-found fires on every mistyped command and runs
# do-release-upgrade; the rest fail when run directly or from apt/cron hooks.
_BASE_APT_PY_SCRIPTS=(
	/usr/lib/command-not-found
	/usr/bin/do-release-upgrade
	/usr/bin/add-apt-repository
	/usr/bin/apt-add-repository
	/usr/bin/unattended-upgrade
	/usr/bin/unattended-upgrades
	/usr/bin/ubuntu-security-status
	/usr/bin/hwe-support-status
	/usr/lib/software-properties/software-properties-dbus
	/usr/lib/ubuntu-advantage/convert_list_to_deb822.py
	/usr/lib/ubuntu-release-upgrader/check-new-release
	/usr/lib/ubuntu-release-upgrader/do-partial-upgrade
)

_base_fix_apt_shebangs() {
	local sys_python f
	sys_python="$(_base_system_python)" || {
		warn "No system Python with apt_pkg found; leaving apt script shebangs alone"
		return 0
	}
	for f in "${_BASE_APT_PY_SCRIPTS[@]}"; do
		[[ -f "$f" ]] || continue
		sed -i -E "1s|^#! ?/usr/bin/(env )?python3$|#!${sys_python}|" "$f"
	done
	# Package upgrades restore the stock shebangs; re-apply after every dpkg run.
	{
		cat <<'HOOK'
#!/bin/sh
# Managed by li-scripts: keep apt-dependent scripts on the python that has apt_pkg.
so=$(ls /usr/lib/python3/dist-packages/apt_pkg.cpython-*.so 2>/dev/null | head -1)
[ -n "$so" ] || exit 0
ver=$(basename "$so" | sed -E 's/^apt_pkg\.cpython-([0-9])([0-9]+)-.*/\1.\2/')
[ -x "/usr/bin/python$ver" ] || exit 0
for f in \
HOOK
		printf '\t%s \\\n' "${_BASE_APT_PY_SCRIPTS[@]}"
		cat <<'HOOK'
	; do
	[ -f "$f" ] && sed -i -E "1s|^#! ?/usr/bin/(env )?python3\$|#!/usr/bin/python$ver|" "$f"
done
exit 0
HOOK
	} >/usr/local/sbin/li-fix-apt-shebangs
	chmod 0755 /usr/local/sbin/li-fix-apt-shebangs
	echo 'DPkg::Post-Invoke { "/usr/local/sbin/li-fix-apt-shebangs || true"; };' \
		>/etc/apt/apt.conf.d/99li-fix-apt-shebangs
}

# A non-system default python breaks apt's python3-apt hooks. Disable the two
# that fail, point the apt-dependent scripts back at the system python, and
# remove the packages known to leave dpkg wedged, before any apt operation runs.
_base_apt_compat() {
	info "Making apt resilient to a non-system default Python"
	[[ -f /etc/apt/apt.conf.d/50command-not-found ]] &&
		mv /etc/apt/apt.conf.d/50command-not-found /etc/apt/apt.conf.d/50command-not-found.disabled
	_base_fix_apt_shebangs
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
