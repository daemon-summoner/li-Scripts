#!/usr/bin/env bash
# setup/modules/cli-tools.sh - base packages and modern CLI tools. Sourced.

# Linux base package set (apt). Modern replacements that live in the Ubuntu
# repos are here; the six that do not (lazygit, zoxide, starship, fastfetch,
# dust, btop) are fetched from their GitHub releases below.
_LI_SYSTEM_APPS="vim neovim tmux curl wget nano build-essential cmake make gcc g++ unzip zip ufw fail2ban git git-lfs sysbench htop iotop nethogs nvtop fish zsh bat ripgrep fd-find fzf jq yq virtualenv python3-venv python3-pip docker.io docker-compose containerd snapd flatpak gpg apt-transport-https software-properties-common ca-certificates gnupg lsb-release net-tools dnsutils whois traceroute mtr-tiny nmap tcpdump iftop vnstat bmon nload speedtest-cli tree ncdu tldr eza duf plocate pciutils"

mod_cli_tools() {
	case "$(detect_os)" in
	linux | wsl) _cli_tools_linux ;;
	macos) _cli_tools_macos ;;
	esac
}

_cli_tools_linux() {
	info "Installing base system packages (apt)"
	# shellcheck disable=SC2086  # intentional word-splitting of the package list
	pkg_install $_LI_SYSTEM_APPS

	# The GitHub-release binaries below target x86_64 Linux, as the originals did.
	step "Installing modern CLI tools from GitHub releases"
	_install_lazygit
	_install_zoxide
	_install_starship
	_install_fastfetch
	_install_dust
	_install_btop
}

# Highest release tag for owner/repo, with an optional leading 'v' stripped.
_gh_latest() {
	curl -fsS --max-time 15 "https://api.github.com/repos/$1/releases/latest" 2>/dev/null |
		grep -Po '"tag_name": "v?\K[^"]*' | head -n1
}

_install_lazygit() {
	local v
	v="$(_gh_latest jesseduffield/lazygit)" || v=""
	[[ -n "$v" ]] || {
		warn "could not determine lazygit version, skipping"
		return 0
	}
	if curl -fsSL "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${v}_Linux_x86_64.tar.gz" -o /tmp/lazygit.tar.gz; then
		tar -xzf /tmp/lazygit.tar.gz -C /usr/local/bin/ lazygit && good "lazygit installed"
	else
		warn "lazygit download failed"
	fi
	rm -f /tmp/lazygit.tar.gz
}

_install_zoxide() {
	curl -fsS https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | bash || {
		warn "zoxide install failed"
		return 0
	}
	# The installer drops it in the invoking user's ~/.local/bin; expose it system-wide.
	if [[ -x /root/.local/bin/zoxide ]]; then
		install -m 0755 /root/.local/bin/zoxide /usr/local/bin/zoxide
	fi
	command -v zoxide >/dev/null 2>&1 && good "zoxide installed"
}

_install_starship() {
	if curl -fsS https://starship.rs/install.sh | sh -s -- -y >/dev/null 2>&1; then
		good "starship installed"
	else
		warn "starship install failed"
	fi
}

_install_fastfetch() {
	local v
	v="$(curl -fsS --max-time 15 'https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest' 2>/dev/null | grep -Po '"tag_name": "\K[^"]*' | head -n1)"
	[[ -n "$v" ]] || {
		warn "could not determine fastfetch version, skipping"
		return 0
	}
	if curl -fsSL "https://github.com/fastfetch-cli/fastfetch/releases/download/${v}/fastfetch-linux-amd64.deb" -o /tmp/fastfetch.deb; then
		if dpkg -i /tmp/fastfetch.deb >/dev/null 2>&1; then good "fastfetch installed"; else warn "fastfetch install failed"; fi
	else
		warn "fastfetch download failed"
	fi
	rm -f /tmp/fastfetch.deb
}

_install_dust() {
	local v
	v="$(_gh_latest bootandy/dust)" || v=""
	[[ -n "$v" ]] || {
		warn "could not determine dust version, skipping"
		return 0
	}
	local dir="dust-v${v}-x86_64-unknown-linux-musl"
	if curl -fsSL "https://github.com/bootandy/dust/releases/download/v${v}/${dir}.tar.gz" -o /tmp/dust.tar.gz; then
		tar -xzf /tmp/dust.tar.gz -C /tmp/
		if [[ -f "/tmp/${dir}/dust" ]]; then
			install -m 0755 "/tmp/${dir}/dust" /usr/local/bin/dust && good "dust installed"
		else
			warn "dust binary not found after extraction"
		fi
		rm -rf "/tmp/${dir}"
	else
		warn "dust download failed"
	fi
	rm -f /tmp/dust.tar.gz
}

_install_btop() {
	local v
	v="$(_gh_latest aristocratos/btop)" || v=""
	[[ -n "$v" ]] || {
		warn "could not determine btop version, skipping"
		return 0
	}
	if curl -fsSL --max-time 60 "https://github.com/aristocratos/btop/releases/download/v${v}/btop-x86_64-linux-musl.tbz" -o /tmp/btop.tbz; then
		if tar -xjf /tmp/btop.tbz -C /tmp/ 2>/dev/null && [[ -f /tmp/btop/bin/btop ]]; then
			install -m 0755 /tmp/btop/bin/btop /usr/local/bin/btop && good "btop installed"
		else
			warn "btop extraction failed (bzip2 missing?)"
		fi
	else
		warn "btop download failed"
	fi
	rm -rf /tmp/btop.tbz /tmp/btop
}

_cli_tools_macos() {
	need brew "install Homebrew: https://brew.sh"
	info "Installing CLI tools (brew)"
	pkg_install neovim lazygit coreutils \
		wget curl jq yq tree htop tmux watch gh \
		cmake protobuf postgresql redis sqlite ffmpeg watchman
	step "Upgrading existing Homebrew packages"
	best_effort brew upgrade
	# coreutils ships gtimeout; expose it as `timeout` for Linux parity.
	local gtimeout
	gtimeout="$(command -v gtimeout || true)"
	if [[ -n "$gtimeout" ]]; then
		best_effort sudo ln -sf "$gtimeout" /usr/local/bin/timeout
	fi
	good "CLI tools installed"
}
