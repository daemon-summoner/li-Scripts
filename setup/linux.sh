#!/usr/bin/env bash
# setup/linux.sh - Ubuntu/Debian provisioning. Run as root, usually via setup.sh.
#
# Usage:
#   sudo ./setup.sh [selections] [options]      (dispatches here on Linux)
#   sudo setup/linux.sh 1,2,3                    numeric menu, same as before
#   sudo setup/linux.sh --core --security        named groups
#
# Selections (numeric menu, comma-separated, or the named flag):
#   1  --core           base packages, shell, python, node, go, docker, k8s, git
#   2  --security       UFW, fail2ban, rkhunter, clamav, auditd, sysctl hardening
#   3  --server         hardened OpenSSH, Nginx, auto-updates
#   4  --mate           MATE desktop environment
#   5  --gui            GUI apps, JetBrains IDEs, VS Code, fonts
#   6  --vm-guest       VMware/VirtualBox guest additions
#   7  --hyperv-guest   Hyper-V guest additions
#   8  --wsl-fix        WSL systemd/interop fixes (restarts WSL)
#
# Options:
#   --user NAME         login to create/configure for core (else prompted)
#   --only IDS          run only these module ids (comma-separated)
#   --skip IDS          skip these module ids
#   --reboot            reboot at the end without asking
#   --no-reboot         never reboot (default is to ask)
#   -h, --help          show this help
# --- end usage ---
set -Eeuo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
LI_ROOT="$(dirname "$HERE")"
export LI_ROOT
# shellcheck source=lib/common.sh
source "$LI_ROOT/lib/common.sh"
# shellcheck source=lib/platform.sh
source "$LI_ROOT/lib/platform.sh"
# shellcheck source=setup/common.sh
source "$HERE/common.sh"
for m in base shell cli-tools python node go docker kubernetes git-config \
	hardening server desktop guests nvidia editors; do
	# shellcheck source=/dev/null
	source "$HERE/modules/$m.sh"
done

# --- finalize helpers ---------------------------------------------------------
# Route Docker's traffic through UFW so published container ports still respect
# the firewall. Only acts when both services are up.
_finalize_docker_ufw() {
	systemctl is-active docker &>/dev/null && systemctl is-active ufw &>/dev/null || return 0
	info "Configuring Docker firewall rules"
	local iface
	iface="$(ip route | awk '/default/ {print $5; exit}')"
	[[ -f /etc/ufw/after.rules.backup ]] || cp /etc/ufw/after.rules /etc/ufw/after.rules.backup
	if ! grep -q "DOCKER-USER" /etc/ufw/after.rules; then
		cat >>/etc/ufw/after.rules <<-EOF

			# BEGIN UFW AND DOCKER
			*filter
			:DOCKER-USER - [0:0]
			:ufw-user-input - [0:0]

			-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
			-A DOCKER-USER -m conntrack --ctstate INVALID -j DROP
			-A DOCKER-USER -i ${iface} -j ufw-user-input
			-A DOCKER-USER -i ${iface} -j DROP
			COMMIT
			# END UFW AND DOCKER
		EOF
	fi
	best_effort systemctl restart ufw
	best_effort systemctl restart docker
	good "Docker firewall rules configured"
}

_finalize_cleanup() {
	info "Final cleanup"
	best_effort apt-get autoremove -y
	best_effort apt-get autoclean -y
	best_effort apt-get clean
	best_effort apt-get purge -y popularity-contest
	command -v updatedb >/dev/null 2>&1 && best_effort updatedb
}

# A short human-readable record of what ran, in the target user's home.
_write_summary() {
	local out="$LI_TARGET_HOME/ubuntu-setup-summary.log"
	info "Writing setup summary to $out"
	{
		echo "li-Scripts Linux setup -- summary"
		echo "================================="
		echo "Date:     $(date)"
		echo "Hostname: $(hostname)"
		echo "User:     $LI_TARGET_USER"
		echo
		echo "Installed:"
		[[ "$want_core" == y ]] && echo "  - Core system"
		[[ "$want_security" == y ]] && echo "  - Security hardening"
		[[ "$want_server" == y ]] && echo "  - Server setup"
		[[ "$want_mate" == y ]] && echo "  - MATE desktop"
		[[ "$want_gui" == y ]] && echo "  - GUI applications"
		[[ "$want_vm" == y ]] && echo "  - VM guest additions"
		[[ "$want_hyperv" == y ]] && echo "  - Hyper-V guest additions"
		echo
		echo "Versions:"
		echo "  Python: $(python3 --version 2>/dev/null || echo n/a)"
		echo "  Go:     $(/usr/local/go/bin/go version 2>/dev/null || echo n/a)"
		echo "  Docker: $(docker --version 2>/dev/null || echo n/a)"
	} >"$out"
	own_target "$out"
	good "Summary written to $out"
}

require_os linux

# --- selection state ----------------------------------------------------------
want_core="" want_security="" want_server="" want_mate="" want_gui=""
want_vm="" want_hyperv="" want_wsl=""
cli_user=""

_select_num() {
	case "$1" in
	1) want_core=y ;;
	2) want_security=y ;;
	3) want_server=y ;;
	4) want_mate=y ;;
	5) want_gui=y ;;
	6) want_vm=y ;;
	7) want_hyperv=y ;;
	8) want_wsl=y ;;
	*) warn "ignoring unknown selection: $1" ;;
	esac
}

_menu() {
	cat <<-EOF

		${c_b}li-Scripts -- Linux setup${c_0}
		Choose options, comma-separated (e.g. 1,2,3):

		  ${c_g}1${c_0}  Core system      base packages, shell, python, node, go, docker, k8s, git
		  ${c_g}2${c_0}  Security         UFW, fail2ban, rkhunter, clamav, auditd, sysctl hardening
		  ${c_g}3${c_0}  Server           hardened OpenSSH, Nginx, auto-updates
		  ${c_g}4${c_0}  MATE desktop     full MATE environment
		  ${c_g}5${c_0}  GUI apps         browsers, editors, JetBrains IDEs, VS Code, fonts
		  ${c_g}6${c_0}  VM guest         VMware/VirtualBox additions
		  ${c_g}7${c_0}  Hyper-V guest    Hyper-V additions
		  ${c_g}8${c_0}  WSL fixes        systemd/interop fixes (restarts WSL)
	EOF
	local reply
	ask reply "Selections"
	local IFS=,
	local n
	for n in $reply; do _select_num "${n// /}"; done
}

# --- argument parsing ---------------------------------------------------------
parse_args() {
	local got_selection=""
	while (($#)); do
		case "$1" in
		-h | --help) usage 0 ;;
		--core) want_core=y got_selection=y ;;
		--security) want_security=y got_selection=y ;;
		--server) want_server=y got_selection=y ;;
		--mate) want_mate=y got_selection=y ;;
		--gui) want_gui=y got_selection=y ;;
		--vm-guest) want_vm=y got_selection=y ;;
		--hyperv-guest) want_hyperv=y got_selection=y ;;
		--wsl-fix) want_wsl=y got_selection=y ;;
		--user) cli_user="${2:?--user needs a name}" && shift ;;
		--user=*) cli_user="${1#*=}" ;;
		--only) LI_ONLY="${2:?--only needs ids}" && shift ;;
		--only=*) LI_ONLY="${1#*=}" ;;
		--skip) LI_SKIP="${2:?--skip needs ids}" && shift ;;
		--skip=*) LI_SKIP="${1#*=}" ;;
		--reboot) LI_REBOOT=1 ;;
		--no-reboot) LI_NO_REBOOT=1 ;;
		[0-9]*)
			local IFS=,
			local n
			for n in $1; do _select_num "${n// /}"; done
			got_selection=y
			;;
		*) die "unknown argument: $1 (try: $0 --help)" ;;
		esac
		shift
	done
	[[ -n "$got_selection" ]] || _menu
}

parse_args "$@"
export LI_ONLY="${LI_ONLY:-}" LI_SKIP="${LI_SKIP:-}" LI_REBOOT="${LI_REBOOT:-0}" LI_NO_REBOOT="${LI_NO_REBOOT:-0}"

# From here on we provision the machine, so enforce root and load config (seeding
# a live config.env on first run). Kept after parse_args so --help needs no sudo
# and never writes config.env as a side effect.
require_root "Linux setup (try: sudo $0 $*)"
li_load_config
li_seed_config
li_load_config

# --- WSL fixes (special: restarts WSL and does not return) --------------------
if [[ "$want_wsl" == y ]] && is_wsl; then
	step "WSL fixes"
	best_effort apt-get update
	pkg_install daemonize dbus-user-session fontconfig libsquashfuse0 squashfuse fuse snapd
	warn "WSL will restart after fixes are applied"
	daemonize /usr/bin/unshare --fork --pid --mount-proc /lib/systemd/systemd --system-unit=basic.target
	exec nsenter -t "$(pidof systemd)" -a su - "$LOGNAME"
fi

# --- core: establish the target login ----------------------------------------
if [[ "$want_core" == y ]]; then
	step "Core system setup"
	local_user="$cli_user"
	if [[ -z "$local_user" ]]; then
		ask local_user "Username to create/configure (with sudo access)"
	fi
	local_user="$(printf '%s' "$local_user" | tr -d '[:space:]')"
	[[ -n "$local_user" ]] || die "a username is required for core setup"

	if ! id "$local_user" &>/dev/null; then
		info "Creating user $local_user"
		adduser --gecos "" "$local_user"
	fi
	usermod -aG sudo "$local_user"
	li_set_target "$local_user"
	good "User $local_user configured"

	if confirm "Change the root password now?" n; then
		passwd root
	fi

	step "Setting timezone to ${LI_TIMEZONE:-America/Chicago}"
	best_effort timedatectl set-timezone "${LI_TIMEZONE:-America/Chicago}"

	run_mod base "Base system" mod_base
	run_mod shell "Shell environment" mod_shell
	run_mod cli-tools "CLI tools" mod_cli_tools
	run_mod python "Python toolchain" mod_python
	run_mod node "Node.js toolchain" mod_node
	run_mod go "Go toolchain" mod_go
	run_mod docker "Docker" mod_docker
	run_mod kubernetes "Kubernetes tools" mod_kubernetes
	run_mod git-config "Git configuration" mod_git_config
fi

[[ "$want_security" == y ]] && run_mod hardening "Security hardening" mod_hardening
[[ "$want_server" == y ]] && run_mod server "Server setup" mod_server
[[ "$want_mate" == y ]] && run_mod mate "MATE desktop" mod_mate
if [[ "$want_gui" == y ]]; then
	run_mod gui "GUI applications" mod_gui
	run_mod editors "VS Code" mod_editors
fi
[[ "$want_vm" == y ]] && run_mod vm-guest "VM guest additions" mod_vm_guest
[[ "$want_hyperv" == y ]] && run_mod hyperv-guest "Hyper-V guest additions" mod_hyperv_guest

# --- finalize (when core or security ran) -------------------------------------
if [[ "$want_core" == y || "$want_security" == y ]]; then
	step "Final configuration"
	_finalize_docker_ufw
	_finalize_cleanup
	run_mod nvidia "NVIDIA driver" mod_nvidia
	_write_summary
	li_reboot_or_prompt
fi
