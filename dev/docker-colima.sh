#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# install_docker.sh
#
# Installs Docker on macOS or Ubuntu (via apt).
#
# On macOS it installs Homebrew and docker-compose, then hands off to
# llm-tools/install_colima_docker.sh, which installs Colima, the docker CLI, the
# supervisor that keeps the VM healthy across sleep and wake, and Docker Model
# Runner. That installer is found at $COLIMA_INSTALLER, else
# ../llm-tools/install_colima_docker.sh next to this script, else
# ~/Projects/llm-tools/install_colima_docker.sh. An existing Colima VM is kept
# (it runs with --hooks-only); any arguments given here are passed to it, e.g.
# --no-dmr or --dmr-backend vllm.
#
# On macOS it also repairs what leaves brew packages off PATH: a formula brew
# could not link (conflicting files from another keg, e.g. the deprecated
# docker-completion) and a Homebrew prefix missing from the shell startup file.
#
# Usage:
#   chmod +x install_docker.sh
#   ./install_docker.sh [install_colima_docker.sh options]
#
# Options (macOS/Colima only):
#   COLIMA_CPU=4          CPU cores for the VM       (default: half the host's, at most 8)
#   COLIMA_MEMORY=8       Memory cap in GB           (default: a quarter of RAM, at most 16)
#   COLIMA_DISK=60        Disk size in GB for the VM (default: 60)
#   COLIMA_VMTYPE=vz      VM type: vz or qemu        (default: vz)
#
# Example:
#   COLIMA_CPU=4 COLIMA_MEMORY=8 ./install_docker.sh
# ──────────────────────────────────────────────────────────────────────────────

# Memory is a cap, not a reservation: a vz VM backs only the pages its guest touches but
# never hands them back, so the host footprint grows to the full cap and stays there
# until the VM restarts.
default_colima_cpu=2
default_colima_memory=4
if [ "$(uname -s)" = "Darwin" ]; then
	default_colima_cpu=$(($(sysctl -n hw.ncpu) / 2))
	((default_colima_cpu > 8)) && default_colima_cpu=8
	((default_colima_cpu < 2)) && default_colima_cpu=2
	default_colima_memory=$(($(sysctl -n hw.memsize) / 4294967296))
	((default_colima_memory > 16)) && default_colima_memory=16
	((default_colima_memory < 4)) && default_colima_memory=4
fi
COLIMA_CPU="${COLIMA_CPU:-$default_colima_cpu}"
COLIMA_MEMORY="${COLIMA_MEMORY:-$default_colima_memory}"
COLIMA_DISK="${COLIMA_DISK:-60}"
COLIMA_VMTYPE="${COLIMA_VMTYPE:-${COLIMA_VM_TYPE:-vz}}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() {
	echo -e "${RED}[ERROR]${NC} $*"
	exit 1
}

# ──────────────────────────────────────────────────────────────────────────────
# macOS install
# ──────────────────────────────────────────────────────────────────────────────

# Find the optional llm-tools/install_colima_docker.sh, which adds a wake/sleep
# supervisor and Docker Model Runner on top of a plain Colima. Sets
# COLIMA_INSTALLER_PATH to it, or to "" when it is not around -- in which case
# install_macos sets up Colima itself. An explicit COLIMA_INSTALLER that does
# not exist is still an error, not a reason to fall back silently.
resolve_colima_installer() {
	local script_dir candidate
	COLIMA_INSTALLER_PATH=""
	if [[ -n "${COLIMA_INSTALLER:-}" ]]; then
		if [[ -f "$COLIMA_INSTALLER" ]]; then
			COLIMA_INSTALLER_PATH="$COLIMA_INSTALLER"
			return 0
		fi
		error "COLIMA_INSTALLER=${COLIMA_INSTALLER} does not exist."
	fi
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	for candidate in \
		"$script_dir/../llm-tools/install_colima_docker.sh" \
		"$HOME/Projects/llm-tools/install_colima_docker.sh"; do
		if [[ -f "$candidate" ]]; then
			COLIMA_INSTALLER_PATH="$candidate"
			return 0
		fi
	done
	return 0
}

# Built-in Colima bootstrap for when the llm-tools installer is not present:
# install the CLIs and start the VM with the sizing computed above. Keeps an
# existing VM as-is.
install_colima_builtin() {
	info "Setting up Colima directly (llm-tools installer not found)"
	brew_install_linked colima docker docker-compose
	if colima_profile_exists; then
		info "Existing Colima profile found -- leaving it running"
		colima status 2>/dev/null || colima start
	else
		info "Starting Colima (${COLIMA_CPU} CPU, ${COLIMA_MEMORY}G RAM, ${COLIMA_DISK}G disk, ${COLIMA_VMTYPE})"
		colima start --cpu "$COLIMA_CPU" --memory "$COLIMA_MEMORY" \
			--disk "$COLIMA_DISK" --vm-type "$COLIMA_VMTYPE"
	fi
}

# Does Colima's default profile exist? That installer deletes and recreates an
# existing one unless it is told --hooks-only.
colima_profile_exists() {
	local profiles
	[[ -d "$HOME/.colima/default" ]] && return 0
	command -v colima &>/dev/null || return 1
	profiles="$(colima list -j 2>/dev/null)" || return 1
	grep -q '"name":"default"' <<<"$profiles"
}

brew_is_linked() { [[ -L "$(brew --prefix)/var/homebrew/linked/$1" ]]; }

# Is formula $1 deprecated or disabled with formula $2 as its replacement?
brew_replaced_by() {
	local json field
	json="$(brew info --json=v2 "$1")"
	for field in deprecation_replacement_formula disable_replacement_formula; do
		# plutil fails on a null field, which just means "no replacement".
		[[ "$(plutil -extract "formulae.0.$field" raw -o - - <<<"$json" 2>/dev/null)" == "$2" ]] && return 0
	done
	return 1
}

# Link a formula into the Homebrew prefix, clearing whatever blocks it. A keg
# that owns conflicting files and is deprecated in favor of this formula (as
# docker-completion is for docker) is uninstalled; any other conflict is
# overwritten, which replaces only the overlapping files, after listing them.
brew_link_formula() {
	local formula="$1" prefix listing line dst owner owners=() conflicts=()
	brew_is_linked "$formula" && return 0
	if brew link "$formula" &>/dev/null; then
		info "Linked $formula"
		return 0
	fi

	prefix="$(brew --prefix)"
	listing="$(brew link --overwrite --dry-run "$formula")"
	while IFS= read -r line; do
		[[ "$line" == "$prefix"/* ]] || continue
		dst="${line%% -> *}"
		conflicts+=("$dst")
		[[ -L "$dst" && "$(readlink "$dst")" =~ (^|/)Cellar/([^/]+)/ ]] || continue
		owner="${BASH_REMATCH[2]}"
		[[ "$owner" != "$formula" && " ${owners[*]-} " != *" $owner "* ]] && owners+=("$owner")
	done <<<"$listing"

	for owner in ${owners[@]+"${owners[@]}"}; do
		if brew_replaced_by "$owner" "$formula"; then
			info "Uninstalling $owner: it is deprecated in favor of $formula and blocks linking it"
			brew uninstall "$owner" || warn "Could not uninstall $owner; overwriting its files instead"
		fi
	done
	if brew link "$formula" &>/dev/null; then
		info "Linked $formula"
		return 0
	fi

	warn "Overwriting files in $prefix that block linking $formula:"
	printf '  %s\n' ${conflicts[@]+"${conflicts[@]}"}
	brew link --overwrite "$formula" || error "Could not link $formula into $prefix"
}

# brew exits non-zero when it installs a keg but cannot link it, which leaves
# the formula in the Cellar with nothing on PATH. Install (or upgrade), then
# repair the links of whatever came out unlinked.
brew_install_linked() {
	local formula
	if ! brew install "$@"; then
		for formula in "$@"; do
			brew list --versions "$formula" &>/dev/null || error "brew could not install $formula"
		done
		warn "brew installed everything but reported an error; repairing links"
	fi
	for formula in "$@"; do
		brew_link_formula "$formula"
	done
}

# New terminals only find a prefix outside the default PATH (/opt/homebrew on
# Apple Silicon) through `brew shellenv` in a shell startup file, which the
# Homebrew installer leaves to the user.
ensure_brew_on_login_path() {
	local prefix profile files=()
	prefix="$(brew --prefix)"
	grep -qsFx "$prefix/bin" /etc/paths /etc/paths.d/* && return 0
	case "$(basename "${SHELL:-}")" in
	zsh)
		profile="${ZDOTDIR:-$HOME}/.zprofile"
		files=(/etc/zshenv /etc/zprofile /etc/zshrc "${ZDOTDIR:-$HOME}"/.{zshenv,zprofile,zshrc,zlogin})
		;;
	bash)
		profile="$HOME/.bash_profile"
		files=(/etc/profile /etc/bashrc "$HOME"/.{bash_profile,bashrc,profile})
		;;
	*)
		warn "Add $prefix/bin to your PATH; ${SHELL:-your shell} is not set up automatically"
		return 0
		;;
	esac
	grep -qsF -e "brew shellenv" -e "$prefix/bin" "${files[@]}" && return 0
	# shellcheck disable=SC2016 # the $(...) is written out for the shell to run later
	printf '\neval "$(%s/bin/brew shellenv)"\n' "$prefix" >>"$profile"
	info "Added Homebrew to PATH in $profile; open a new terminal to pick it up"
}

install_macos() {
	info "Detected macOS"

	# Resolved before anything is installed or written, so a missing installer
	# leaves the machine untouched.
	resolve_colima_installer
	info "Colima installer: ${COLIMA_INSTALLER_PATH:-(built-in)}"

	# --- Homebrew ---
	if ! command -v brew &>/dev/null; then
		info "Installing Homebrew..."
		/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

		# Add brew to PATH for this session
		if [[ -f /opt/homebrew/bin/brew ]]; then
			eval "$(/opt/homebrew/bin/brew shellenv)"
		elif [[ -f /usr/local/bin/brew ]]; then
			eval "$(/usr/local/bin/brew shellenv)"
		fi
	else
		info "Homebrew already installed"
	fi
	ensure_brew_on_login_path

	# --- Docker Compose (the Colima installer brings the docker CLI, not compose) ---
	if ! brew list --formula docker-compose &>/dev/null; then
		info "Installing docker-compose via brew..."
		brew_install_linked docker-compose
	else
		info "docker-compose already installed"
		brew_link_formula docker-compose
	fi

	# --- Docker Compose CLI plugin (if missing or a dangling link) ---
	DOCKER_CLI_PLUGINS="$HOME/.docker/cli-plugins"
	if [[ ! -x "$DOCKER_CLI_PLUGINS/docker-compose" ]]; then
		mkdir -p "$DOCKER_CLI_PLUGINS"
		COMPOSE_BIN="$(brew --prefix docker-compose)/bin/docker-compose"
		if [[ -f "$COMPOSE_BIN" ]]; then
			ln -sfn "$COMPOSE_BIN" "$DOCKER_CLI_PLUGINS/docker-compose"
			info "Linked docker-compose as Docker CLI plugin"
		fi
	fi

	# --- Colima, its supervisor and Docker Model Runner ---
	export COLIMA_VM_TYPE="$COLIMA_VMTYPE" COLIMA_CPU COLIMA_MEMORY COLIMA_DISK
	if [[ -z "$COLIMA_INSTALLER_PATH" ]]; then
		install_colima_builtin
		return
	fi
	# That installer skips formulae that are already installed, so it would
	# leave an unlinked docker or colima unlinked.
	local formula
	for formula in docker colima; do
		if brew list --formula "$formula" &>/dev/null; then
			brew_link_formula "$formula"
		fi
	done
	if colima_profile_exists; then
		info "Existing Colima profile found -- keeping the VM (--hooks-only)"
		exec bash "$COLIMA_INSTALLER_PATH" --hooks-only "$@"
	fi
	info "Handing off to ${COLIMA_INSTALLER_PATH}"
	exec bash "$COLIMA_INSTALLER_PATH" "$@"
}

# ──────────────────────────────────────────────────────────────────────────────
# Ubuntu install
# ──────────────────────────────────────────────────────────────────────────────
install_ubuntu() {
	info "Detected Ubuntu/Debian"

	# --- Remove old/conflicting packages ---
	info "Removing any old Docker packages..."
	sudo apt-get remove -y \
		docker docker-engine docker.io containerd runc 2>/dev/null || true

	# --- Prerequisites ---
	info "Installing prerequisites..."
	sudo apt-get update
	sudo apt-get install -y \
		ca-certificates \
		curl \
		gnupg \
		lsb-release

	# --- Docker GPG key ---
	KEYRINGS_DIR="/etc/apt/keyrings"
	sudo install -m 0755 -d "$KEYRINGS_DIR"

	if [[ ! -f "$KEYRINGS_DIR/docker.asc" ]]; then
		info "Adding Docker GPG key..."
		curl -fsSL https://download.docker.com/linux/ubuntu/gpg |
			sudo tee "$KEYRINGS_DIR/docker.asc" >/dev/null
		sudo chmod a+r "$KEYRINGS_DIR/docker.asc"
	fi

	# --- Docker apt repo ---
	ARCH="$(dpkg --print-architecture)"
	# shellcheck source=/dev/null
	CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"

	info "Adding Docker apt repository..."
	echo \
		"deb [arch=${ARCH} signed-by=${KEYRINGS_DIR}/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable" |
		sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

	# --- Install Docker Engine ---
	info "Installing Docker Engine..."
	sudo apt-get update
	sudo apt-get install -y \
		docker-ce \
		docker-ce-cli \
		containerd.io \
		docker-buildx-plugin \
		docker-compose-plugin

	# --- Enable and start ---
	info "Enabling Docker service..."
	sudo systemctl enable docker
	sudo systemctl start docker

	# --- Add current user to docker group ---
	if ! groups "$USER" | grep -q '\bdocker\b'; then
		info "Adding $USER to the docker group..."
		sudo usermod -aG docker "$USER"
		warn "You'll need to log out and back in (or run 'newgrp docker') for group changes to take effect"
	fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────
main() {
	OS="$(uname -s)"

	case "$OS" in
	Darwin)
		install_macos "$@"
		;;
	Linux)
		if [[ -f /etc/os-release ]] && grep -qi 'ubuntu\|debian' /etc/os-release; then
			install_ubuntu
		else
			error "Unsupported Linux distribution. This script supports Ubuntu/Debian."
		fi
		;;
	*)
		error "Unsupported OS: ${OS}"
		;;
	esac

	# --- Verify ---
	info "Verifying Docker installation..."
	command -v docker &>/dev/null || error "docker CLI is not on PATH; the install did not complete."
	if docker info &>/dev/null; then
		info "Docker is running!"
		docker --version
		docker compose version 2>/dev/null || docker-compose --version 2>/dev/null || true
	else
		warn "Docker installed but daemon not reachable yet."
		warn "On Ubuntu, try: newgrp docker"
		warn "On macOS, check: colima status"
	fi

	echo ""
	info "Done!"
}

main "$@"
