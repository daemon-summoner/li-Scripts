#!/usr/bin/env bash
# setup/modules/docker.sh - Docker Engine (Linux) or Colima (macOS). Sourced.

mod_docker() {
	case "$(detect_os)" in
	linux | wsl) _docker_linux ;;
	macos) _docker_macos ;;
	esac
}

_docker_linux() {
	info "Installing Docker Engine"
	rm -f /usr/share/keyrings/docker-archive-keyring.gpg
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
	echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
		>/etc/apt/sources.list.d/docker.list
	best_effort apt-get update
	pkg_install docker-ce docker-ce-cli containerd.io docker-compose-plugin

	usermod -aG docker "$LI_TARGET_USER"
	good "Added $LI_TARGET_USER to the docker group"

	_docker_autocleanup
	good "Docker installed"
}

# BuildKit GC plus a daily system prune, so build cache and old images never
# fill the disk. Merges into any existing daemon.json rather than clobbering it.
_docker_autocleanup() {
	info "Configuring Docker auto-cleanup"
	command -v jq >/dev/null 2>&1 || pkg_install jq
	install -d /etc/docker
	local gc='{"builder":{"gc":{"enabled":true,"defaultKeepStorage":"20GB","policy":[{"keepStorage":"10GB","filter":["unused-for=48h"]},{"keepStorage":"20GB"}]}}}'
	if [[ -s /etc/docker/daemon.json ]]; then
		jq -s '.[0] * .[1]' /etc/docker/daemon.json <(echo "$gc") >/etc/docker/daemon.json.new &&
			mv /etc/docker/daemon.json.new /etc/docker/daemon.json
	else
		echo "$gc" | jq '.' >/etc/docker/daemon.json
	fi

	cat >/etc/systemd/system/docker-prune.service <<-'EOF'
		[Unit]
		Description=Prune unused Docker images and stopped containers older than 168h
		Wants=docker.service
		After=docker.service
		ConditionPathExists=/var/run/docker.sock

		[Service]
		Type=oneshot
		ExecStart=/usr/bin/docker system prune -af --filter until=168h
	EOF
	cat >/etc/systemd/system/docker-prune.timer <<-'EOF'
		[Unit]
		Description=Daily Docker prune (images/containers >168h)

		[Timer]
		OnCalendar=daily
		Persistent=true
		RandomizedDelaySec=30min

		[Install]
		WantedBy=timers.target
	EOF
	systemctl daemon-reload
	systemctl enable --now docker-prune.timer
	systemctl restart docker
	good "Docker auto-cleanup configured (build cache 48h, images/containers 168h)"
}

# macOS Docker is Colima; the dedicated installer owns the VM sizing and startup.
_docker_macos() {
	local installer="$LI_ROOT/dev/docker-colima.sh"
	[[ -x "$installer" || -f "$installer" ]] || die "missing $installer"
	info "Installing Docker via Colima (dev/docker-colima.sh)"
	bash "$installer"
	good "Docker (Colima) installed"
}
