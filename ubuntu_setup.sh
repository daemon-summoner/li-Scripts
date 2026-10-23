#!/bin/bash

# Ubuntu Ultimate Setup Script v3.0
# Enhanced with better error handling, efficient package management, and configurable options

set -euo pipefail

# Color definitions for beautiful CLI output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Unicode characters for visual elements
CHECK_MARK="✓"
CROSS_MARK="✗"
ARROW="➜"
PACKAGE="📦"
SECURITY="🔒"
GEAR="⚙️"
ROCKET="🚀"
INFO="ℹ️"
WARNING="⚠️"

# Script version
SCRIPT_VERSION="3.0"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}${CROSS_MARK} This script must be run as root${NC}"
    echo -e "${YELLOW}${ARROW} Try: sudo $0 $@${NC}"
    exit 1
fi

# Configuration with defaults
declare -A CONFIG=(
    [TIMEZONE]="${TIMEZONE:-America/Chicago}"
    [PYTHON_VERSION]="${PYTHON_VERSION:-3.14}"
    [GO_VERSION]="${GO_VERSION:-1.25.4}"
    [NODE_VERSION]="${NODE_VERSION:-lts}"
    [BACKUP_DIR]="${BACKUP_DIR:-/var/backups/ubuntu-setup}"
    [LOG_FILE]="${LOG_FILE:-/var/log/ubuntu-setup.log}"
    [GIT_EMAIL]="${GIT_EMAIL:-user@example.com}"
    [GIT_NAME]="${GIT_NAME:-User}"
    [SSH_KEY]="${SSH_KEY:-}"
    [PACKAGE_TIMEOUT]="${PACKAGE_TIMEOUT:-300}"
    [RETRY_ATTEMPTS]="${RETRY_ATTEMPTS:-3}"
    [BATCH_SIZE]="${BATCH_SIZE:-10}"
)

# Arrays to track installation status
declare -a FAILED_PACKAGES=()
declare -a INSTALLED_PACKAGES=()
declare -a SKIPPED_PACKAGES=()

# Package groups
# Note: fastfetch, dust, and btop++ installed separately (not in Ubuntu repos)
systemApps="vim neovim tmux curl wget nano build-essential cmake make gcc g++ unzip zip ufw fail2ban git git-lfs sysbench htop iotop nethogs nvtop fish zsh bat ripgrep fd-find fzf jq yq virtualenv python3-venv python3-pip docker.io docker-compose containerd snapd flatpak gpg apt-transport-https software-properties-common ca-certificates gnupg lsb-release net-tools dnsutils whois traceroute mtr-tiny nmap tcpdump iftop vnstat bmon nload speedtest-cli tree ncdu tldr eza duf plocate pciutils"

# Note: tripwire removed as it requires interactive configuration
# Note: tiger removed as deprecated (last update 2008)
# Note: debsecan removed - incompatible with Python 3.14 (requires apt_pkg module)
# Note: aide removed - initialization takes too long (10-30+ minutes)
# Note: apt-listchanges removed - incompatible with Python 3.14 (requires apt_pkg module)
# Note: samhain removed - causes core dumps and leaves dpkg in broken state on Ubuntu 24.04
securityApps="rkhunter chkrootkit clamav clamav-daemon lynis auditd apparmor-utils libpam-pwquality unattended-upgrades needrestart debsums fail2ban psad"

serverApps="openssh-server nginx certbot python3-certbot-nginx"

guiApps="qbittorrent sublime-text sublime-merge tilix firefox chromium-browser git-cola gitg meld"

mateDesktop="mate-desktop-environment mate-desktop-environment-extras ubuntu-mate-themes"

vmGuestAdditions="open-vm-tools open-vm-tools-desktop"

hyperVGuestAdditions="linux-virtual linux-cloud-tools-virtual linux-tools-virtual"

containerTools="kubectl minikube helm k9s"

developmentTools="golang-go nodejs npm yarn redis-tools postgresql-client mysql-client mongodb-clients sqlite3 httpie insomnia postman"

# Function to print colored headers
print_header() {
    local header=$1
    local width=80
    local padding=$(( (width - ${#header} - 2) / 2 ))
    
    echo
    echo -e "${CYAN}$(printf '═%.0s' {1..80})${NC}"
    echo -e "${CYAN}║${NC}$(printf ' %.0s' $(seq 1 $padding))${BOLD}${WHITE}$header${NC}$(printf ' %.0s' $(seq 1 $padding))${CYAN}║${NC}"
    echo -e "${CYAN}$(printf '═%.0s' {1..80})${NC}"
    echo
}

# Function to print status messages
print_status() {
    echo -e "${BLUE}${ARROW}${NC} $1"
}

print_success() {
    echo -e "${GREEN}${CHECK_MARK}${NC} $1"
}

print_error() {
    echo -e "${RED}${CROSS_MARK}${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}${WARNING}${NC} $1"
}

print_info() {
    echo -e "${CYAN}${INFO}${NC} $1"
}

# Progress bar function
show_progress() {
    local current=$1
    local total=$2
    local width=50
    local percentage=$((current * 100 / total))
    local completed=$((width * current / total))
    
    printf "\r["
    printf "%${completed}s" | tr ' ' '█'
    printf "%$((width - completed))s" | tr ' ' '░'
    printf "] %d%%" $percentage
}

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "${CONFIG[LOG_FILE]}"
}

# Check if package is installed
is_package_installed() {
    local package="$1"
    set +e  # Temporarily disable exit on error
    dpkg -l "$package" 2>/dev/null | grep -q "^ii"
    local result=$?
    set -e  # Re-enable exit on error
    return $result
}

# Install packages with retry logic
install_package() {
    local package=$1
    local attempts=0
    local max_attempts="${CONFIG[RETRY_ATTEMPTS]}"
    
    # Check if already installed
    if is_package_installed "$package"; then
        SKIPPED_PACKAGES+=("$package")
        return 0
    fi
    
    while [ $attempts -lt $max_attempts ]; do
        attempts=$((attempts + 1))
        
        # Temporarily disable exit on error for package installation
        set +e
        timeout "${CONFIG[PACKAGE_TIMEOUT]}" apt-get install -y -q \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" \
            "$package" >/dev/null 2>&1
        local install_result=$?
        set -e
        
        if [ $install_result -eq 0 ]; then
            INSTALLED_PACKAGES+=("$package")
            return 0
        fi
        
        # If it's the last attempt, check if it was actually installed
        if [ $attempts -eq $max_attempts ]; then
            if is_package_installed "$package"; then
                INSTALLED_PACKAGES+=("$package")
                return 0
            fi
            # Log the failure for debugging
            log "Failed to install package: $package after $max_attempts attempts"
        fi
        
        # Wait before retry
        sleep 2
    done
    
    FAILED_PACKAGES+=("$package")
    return 1
}

# Batch install packages - SIMPLIFIED VERSION
batch_install_packages() {
    local packages=("$@")
    local total=${#packages[@]}
    
    print_status "Installing ${total} packages..."
    
    # Update package cache
    apt-get update -qq || true
    
    # Just try to install everything, don't worry about checking what's installed
    print_status "Installing packages with apt..."
    
    set +e
    apt-get install -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        "${packages[@]}"
    local result=$?
    set -e
    
    if [ $result -eq 0 ]; then
        print_success "Package installation completed successfully"
        INSTALLED_PACKAGES+=("${packages[@]}")
    else
        print_warning "Some packages may have failed to install (exit code: $result)"
        print_status "Continuing with script execution..."
    fi
}

# Pre-configure packages that require interaction
preconfigure_packages() {
    print_status "Pre-configuring packages to avoid prompts..."
    
    # Configure postfix
    echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections
    echo "postfix postfix/mailname string $(hostname)" | debconf-set-selections
    
    # Configure other packages that might prompt
    echo "wireshark-common wireshark-common/install-setuid boolean true" | debconf-set-selections
    echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
    echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
    
    print_success "Package pre-configuration complete"
}

# Load configuration from file if exists
load_config_file() {
    local config_file="${1:-/etc/ubuntu-setup.conf}"
    if [ -f "$config_file" ]; then
        print_info "Loading configuration from $config_file"
        source "$config_file"
    fi
}

# Backup function
create_backup() {
    print_status "Creating system backup..."
    
    local backup_name="ubuntu-setup-$(date +%Y%m%d-%H%M%S)"
    local backup_path="${CONFIG[BACKUP_DIR]}/$backup_name"
    
    mkdir -p "${CONFIG[BACKUP_DIR]}"
    
    # Backup critical system files
    local files_to_backup=(
        "/etc/apt/sources.list"
        "/etc/apt/sources.list.d/"
        "/etc/ssh/sshd_config"
        "/etc/ufw/"
        "/etc/fail2ban/"
        "/home/*/.bashrc"
        "/home/*/.profile"
    )
    
    tar -czf "$backup_path.tar.gz" ${files_to_backup[@]} 2>/dev/null || true
    
    print_success "Backup created at: $backup_path.tar.gz"
    log "Backup created: $backup_path.tar.gz"
}

# Function to check if running in WSL
detect_wsl() {
    if grep -qiE "(microsoft|wsl)" /proc/version; then
        return 0
    else
        return 1
    fi
}

# Clean up problematic repositories
cleanup_repositories() {
    print_status "Cleaning up old repository configurations..."
    
    # Remove old Kubernetes repositories
    rm -f /etc/apt/sources.list.d/kubernetes*.list
    rm -f /usr/share/keyrings/kubernetes*.gpg
    
    # Remove any references to old kubernetes repositories
    if [ -f /etc/apt/sources.list ]; then
        sed -i '/apt\.kubernetes\.io/d' /etc/apt/sources.list
        sed -i '/packages\.cloud\.google\.com\/apt.*kubernetes/d' /etc/apt/sources.list
    fi
    
    # Clean apt cache
    apt-get clean
    rm -rf /var/lib/apt/lists/*
    
    print_success "Repository cleanup complete"
}

# Install Python with better error handling
install_python() {
    local python_version="${CONFIG[PYTHON_VERSION]}"

    print_status "Installing Python ${python_version}..."

    # Add deadsnakes PPA manually (add-apt-repository fails with Python 3.14 due to apt_pkg)
    print_status "Adding deadsnakes PPA manually..."

    local codename deadsnakes_url
    codename=$(lsb_release -cs)
    deadsnakes_url="https://ppa.launchpadcontent.net/deadsnakes/ppa/ubuntu"

    # Skip if deadsnakes has no packages for this Ubuntu release yet (e.g., resolute)
    if curl -fsSL --max-time 15 -o /dev/null "${deadsnakes_url}/dists/${codename}/InRelease"; then
        # Remove existing keyring if present (prevents overwrite prompt)
        rm -f /usr/share/keyrings/deadsnakes-ppa-keyring.gpg

        # Add GPG key
        if ! gpg --keyserver keyserver.ubuntu.com --recv-keys F23C5A6CF475977595C89F51BA6932366A755776 2>/dev/null; then
            print_warning "Failed to import PPA GPG key via keyserver, trying alternative method..."
            curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xBA6932366A755776" | gpg --dearmor -o /usr/share/keyrings/deadsnakes-ppa-keyring.gpg
        else
            gpg --export F23C5A6CF475977595C89F51BA6932366A755776 | gpg --dearmor -o /usr/share/keyrings/deadsnakes-ppa-keyring.gpg
        fi

        # Add repository (HTTPS, launchpadcontent host)
        echo "deb [signed-by=/usr/share/keyrings/deadsnakes-ppa-keyring.gpg] ${deadsnakes_url} ${codename} main" | tee /etc/apt/sources.list.d/deadsnakes-ppa.list > /dev/null

        print_success "Deadsnakes PPA added manually"
    else
        # Disable any prior deadsnakes source so apt update doesn't error on it
        for f in /etc/apt/sources.list.d/deadsnakes-ppa.list /etc/apt/sources.list.d/deadsnakes-ppa.sources; do
            [ -f "$f" ] && mv "$f" "${f}.disabled"
        done
        print_warning "Deadsnakes PPA has no packages for '${codename}'; using system-provided Python ${python_version}"
    fi

    apt-get update -qq
    
    # Install Python packages
    # Note: distutils removed from Python 3.12+, no longer needed
    local python_packages=(
        "python${python_version}"
        "python${python_version}-venv"
        "python${python_version}-dev"
    )
    
    for pkg in "${python_packages[@]}"; do
        if ! apt-get install -y "$pkg"; then
            print_warning "Failed to install $pkg"
        fi
    done
    
    # Set as default Python 3
    update-alternatives --install /usr/bin/python3 python3 /usr/bin/python${python_version} 1
    update-alternatives --set python3 /usr/bin/python${python_version}
    
    # Install pip
    print_status "Installing pip..."
    if ! command -v pip3 &> /dev/null; then
        if curl -sS https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py; then
            # Install pip properly
            python3 /tmp/get-pip.py --user 2>/dev/null || \
            python3 /tmp/get-pip.py 2>/dev/null || \
            print_warning "Failed to install pip normally, trying with break-system-packages..."
            
            # If still no pip, try with break-system-packages
            if ! command -v pip3 &> /dev/null; then
                python3 /tmp/get-pip.py --break-system-packages 2>/dev/null || \
                print_error "Failed to install pip"
            fi
            
            rm -f /tmp/get-pip.py
        fi
    fi
    
    print_success "Python ${python_version} setup complete"
}

# Initialize script
initialize_script() {
    # Create log directory
    mkdir -p "$(dirname "${CONFIG[LOG_FILE]}")"
    
    # Start logging
    log "Ubuntu Setup Script v${SCRIPT_VERSION} started"
    
    # Set DEBIAN_FRONTEND for the entire script
    export DEBIAN_FRONTEND=noninteractive
    
    # Load config file if specified
    if [ -n "${CONFIG_FILE:-}" ]; then
        load_config_file "$CONFIG_FILE"
    fi
}

# Print installation summary
print_installation_summary() {
    echo
    print_header "Installation Summary"
    
    if [ ${#INSTALLED_PACKAGES[@]} -gt 0 ]; then
        echo -e "${GREEN}${BOLD}Successfully Installed (${#INSTALLED_PACKAGES[@]} packages):${NC}"
        printf '%s\n' "${INSTALLED_PACKAGES[@]}" | sort | column -c 80
        echo
    fi
    
    if [ ${#SKIPPED_PACKAGES[@]} -gt 0 ]; then
        echo -e "${CYAN}${BOLD}Already Installed/Skipped (${#SKIPPED_PACKAGES[@]} packages):${NC}"
        printf '%s\n' "${SKIPPED_PACKAGES[@]}" | sort | column -c 80
        echo
    fi
    
    if [ ${#FAILED_PACKAGES[@]} -gt 0 ]; then
        echo -e "${RED}${BOLD}Failed to Install (${#FAILED_PACKAGES[@]} packages):${NC}"
        printf '%s\n' "${FAILED_PACKAGES[@]}" | sort | column -c 80
        echo
        print_warning "You can try installing failed packages manually with:"
        echo -e "${YELLOW}sudo apt install ${FAILED_PACKAGES[*]}${NC}"
        echo
    fi
}

# Enhanced menu display
display_menu() {
    clear
    echo -e "${BOLD}${MAGENTA}"
    cat << "EOF"
    ╔═══════════════════════════════════════════════════════════════╗
    ║                                                               ║
    ║           Ubuntu Ultimate Setup Script v3.0                   ║
    ║                                                               ║
    ║         🚀 Modern Development Environment Setup 🚀            ║
    ║                                                               ║
    ╚═══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    
    echo -e "${CYAN}${BOLD}Available Options:${NC}"
    echo
    echo -e "${GREEN}1${NC} - ${BOLD}Core System Setup${NC}"
    echo -e "    ${PACKAGE} System utilities, Python ${CONFIG[PYTHON_VERSION]}, development tools"
    echo -e "    ${GEAR} Git, Docker, Kubernetes tools, Node.js (via nvm), Go"
    echo
    echo -e "${GREEN}2${NC} - ${BOLD}Security Hardening${NC}"
    echo -e "    ${SECURITY} SSH hardening, firewall, intrusion detection"
    echo -e "    ${SECURITY} Anti-malware, rootkit detection, security auditing"
    echo
    echo -e "${GREEN}3${NC} - ${BOLD}Server Setup${NC}"
    echo -e "    📡 OpenSSH, Nginx, Certbot"
    echo
    echo -e "${GREEN}4${NC} - ${BOLD}MATE Desktop Environment${NC}"
    echo -e "    🖥️  Full MATE desktop with extras"
    echo
    echo -e "${GREEN}5${NC} - ${BOLD}GUI Applications${NC}"
    echo -e "    🎨 Development tools, browsers, editors"
    echo
    echo -e "${GREEN}6${NC} - ${BOLD}VMware/VirtualBox Guest Additions${NC}"
    echo
    echo -e "${GREEN}7${NC} - ${BOLD}Hyper-V Guest Additions${NC}"
    echo
    echo -e "${GREEN}8${NC} - ${BOLD}WSL Fixes${NC} (requires restart)"
    echo
    echo -e "${GREEN}9${NC} - ${BOLD}Skip Reboot${NC} at end"
    echo
    echo -e "${YELLOW}${BOLD}Enter your choices separated by commas (e.g., 1,2,3):${NC}"
}

# Main script starts here
initialize_script

# Initialize choices
basicChoice=""
securityChoice=""
serverChoice=""
mateChoice=""
guiChoice=""
vmGuestChoice=""
hyperVGuestChoice=""
wslFix=""
preventRebootChoice=""
username=""

# Get user input
userInput="${1:-}"
if [[ -z "$userInput" ]]; then
    display_menu
    read -p "$(echo -e ${CYAN}${ARROW}${NC} ) " userInput
fi

# Parse user choices
IFS=',' read -ra CHOICES <<< "$userInput"
for choice in "${CHOICES[@]}"; do
    case $choice in
        1) basicChoice="y" ;;
        2) securityChoice="y" ;;
        3) serverChoice="y" ;;
        4) mateChoice="y" ;;
        5) guiChoice="y" ;;
        6) vmGuestChoice="y" ;;
        7) hyperVGuestChoice="y" ;;
        8) wslFix="y" ;;
        9) preventRebootChoice="y" ;;
    esac
done

# WSL detection and fixes
if [[ $wslFix == "y" ]] && detect_wsl; then
    print_header "WSL Fixes"
    print_status "Applying WSL-specific fixes..."
    
    apt-get update
    apt-get install -y daemonize dbus-user-session fontconfig libsquashfuse0 squashfuse fuse snapd
    
    print_warning "WSL will restart after fixes are applied"
    daemonize /usr/bin/unshare --fork --pid --mount-proc /lib/systemd/systemd --system-unit=basic.target
    exec nsenter -t $(pidof systemd) -a su - $LOGNAME
    wsl.exe --shutdown
fi

# Basic System Setup
if [[ $basicChoice == "y" ]]; then
    print_header "Core System Setup"
    
    # Clean up repositories
    cleanup_repositories
    
    # Create backup
    create_backup
    
    # Get username
    while true; do
        echo -e "${CYAN}Enter username to create/configure (with sudo access):${NC}"
        read -p "$(echo -e ${CYAN}${ARROW}${NC} ) " username
        username="$(echo -e "${username}" | tr -d '[:space:]')"
        
        echo -e "${YELLOW}Create/configure user: ${BOLD}$username${NC}? [Y/n]"
        read -p "$(echo -e ${CYAN}${ARROW}${NC} ) " confirm
        
        if [[ -z $confirm || $confirm =~ ^[Yy]$ ]]; then
            break
        fi
    done
    
    print_status "Setting up user: $username"
    if ! id "$username" &>/dev/null; then
        adduser --gecos "" "$username"
    fi
    usermod -aG sudo "$username"
    print_success "User configured"
    
    # Change root password
    echo -e "${YELLOW}Change ROOT password? [y/N]${NC}"
    read -p "$(echo -e ${CYAN}${ARROW}${NC} ) " rootPassChoice
    if [[ $rootPassChoice =~ ^[Yy]$ ]]; then
        passwd root
    fi
    
    # Set timezone
    print_status "Setting timezone to ${CONFIG[TIMEZONE]}"
    timedatectl set-timezone "${CONFIG[TIMEZONE]}"
    print_success "Timezone configured"
    
    # Configure shell environment
    print_status "Configuring shell environment"
    
    # Enhanced .bashrc
    cat > "/home/$username/.bashrc" << 'EOL'
# Enhanced .bashrc for Ubuntu Ultimate Setup

# If not running interactively, don't do anything
case $- in
    *i*) ;;
      *) return;;
esac

# History settings
HISTCONTROL=ignoreboth
HISTSIZE=10000
HISTFILESIZE=20000
shopt -s histappend

# Window size check
shopt -s checkwinsize

# Enable color support
if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
    alias ls='ls --color=auto'
    alias grep='grep --color=auto'
    alias fgrep='fgrep --color=auto'
    alias egrep='egrep --color=auto'
fi

# Modern aliases
alias python='python3'
alias pip='pip3'

# Modern tool seamless replacements (drop-in compatible)
alias htop='btop'
alias top='btop'
alias du='dust'
alias ls='eza --icons --group-directories-first'
alias ll='eza -l --icons --group-directories-first'
alias la='eza -la --icons --group-directories-first'
alias tree='eza --tree --icons'

# Preserve original commands with 'old' prefix
alias oldhtop='/usr/bin/htop'
alias oldtop='/usr/bin/top'
alias olddu='/usr/bin/du'
alias oldls='/bin/ls --color=auto'

# Tmux session helpers
for i in {1..10}; do
    eval "function tmux$i() { tmux attach-session -t main$i || tmux new-session -s main$i; }"
done

# Python virtual environment helpers
mkvenv() {
    python3 -m venv "${1:-venv}"
    source "${1:-venv}/bin/activate"
}

activate() {
    source "${1:-venv}/bin/activate"
}

# faster-whisper (library): create a local .venv here with faster-whisper installed via uv
whisper-lib() {
    uv venv --python 3.12 && uv pip install faster-whisper "$@" && \
        echo "faster-whisper ready in .venv -- activate with: source .venv/bin/activate"
}

# Enable programmable completion
if ! shopt -oq posix; then
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi

# NVM
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

# Go
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin

# User-local binaries (pip --user, uv, uv tools)
export PATH=$HOME/.local/bin:$PATH

# FZF
[ -f ~/.fzf.bash ] && source ~/.fzf.bash

# Initialize starship prompt (replaces PS1)
if command -v starship &> /dev/null; then
    eval "$(starship init bash)"
else
    # Fallback to colored prompt if starship not available
    PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
fi

fastfetch

# Initialize zoxide LAST (must be at end of bashrc)
if command -v zoxide &> /dev/null; then
    eval "$(zoxide init bash)"
    # Alias cd to z for seamless transition
    alias cd='z'
    # Preserve original cd
    alias oldcd='builtin cd'
fi
EOL
    
    chown "$username:$username" "/home/$username/.bashrc"
    print_success "Shell environment configured"
    
    # Pre-configure packages
    preconfigure_packages

    # Critical: Disable Python-dependent apt hooks and remove broken packages
    # BEFORE any apt operations (prevents failures on rerun with Python 3.14)
    # Python 3.14 is too new and doesn't have apt_pkg bindings yet
    print_status "Configuring apt for Python 3.14 compatibility..."

    # Disable command-not-found hook
    if [ -f /etc/apt/apt.conf.d/50command-not-found ]; then
        mv /etc/apt/apt.conf.d/50command-not-found /etc/apt/apt.conf.d/50command-not-found.disabled 2>/dev/null || true
    fi

    # Fix command-not-found script to use system Python with apt_pkg support
    # The script uses #!/usr/bin/python3 but apt_pkg only works with system Python
    if [ -f /usr/lib/command-not-found ]; then
        # Detect the original system Python (before we change the default)
        # On Ubuntu 24.04 it's python3.12, on 22.04 it's python3.10
        for sys_python in python3.12 python3.11 python3.10; do
            if [ -x "/usr/bin/$sys_python" ]; then
                print_status "Fixing command-not-found to use $sys_python..."
                sed -i "1s|^#!/usr/bin/python3$|#!/usr/bin/$sys_python|" /usr/lib/command-not-found
                print_success "command-not-found fixed"
                break
            fi
        done
    fi

    # Disable apt-listchanges hook (prevents it from running during upgrades)
    if [ -f /etc/apt/apt.conf.d/20listchanges ]; then
        mv /etc/apt/apt.conf.d/20listchanges /etc/apt/apt.conf.d/20listchanges.disabled 2>/dev/null || true
    fi

    # Remove broken/incompatible packages from previous runs (before upgrade tries to configure them)
    print_status "Removing problematic packages from previous runs..."
    dpkg --remove --force-remove-reinstreq debsecan apt-listchanges samhain 2>/dev/null || true

    # Fix any broken package dependencies
    apt-get -f install -y 2>/dev/null || true

    print_success "Apt configured for Python 3.14 compatibility"

    # System updates (NOW SAFE - hooks disabled, broken packages removed)
    print_status "Updating system packages..."
    apt-get update
    apt-get full-upgrade -y -q
    
    # Install base packages
    print_status "Installing system packages..."
    systemApps_array=($systemApps)
    batch_install_packages "${systemApps_array[@]}"
    
    # Install Python
    install_python
    
    # Install uv (fast Python package/tool manager) for the user.
    # Replaces pipx for isolated CLI tools; pip/pip3 stay available as a fallback.
    print_status "Installing uv..."
    sudo -u "$username" env HOME="/home/$username" INSTALLER_NO_MODIFY_PATH=1 bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh' || print_warning "uv installation may have failed"
    if [ -x "/home/$username/.local/bin/uv" ]; then
        # Expose uv system-wide (mirrors the zoxide/starship pattern below)
        cp /home/$username/.local/bin/uv /usr/local/bin/ 2>/dev/null || true
        cp /home/$username/.local/bin/uvx /usr/local/bin/ 2>/dev/null || true
        print_success "uv installed ($(/usr/local/bin/uv --version 2>/dev/null))"
    else
        print_warning "uv binary not found after installation"
    fi

    # Install faster-whisper CLI (whisper-ctranslate2) as an isolated uv tool.
    # Pinned to Python 3.12 for ctranslate2 wheel availability; uv fetches it if missing.
    # CPU works out of the box; GPU needs an NVIDIA card with CUDA 12 + cuDNN 9.
    print_status "Installing faster-whisper CLI (whisper-ctranslate2) via uv..."
    sudo -u "$username" env HOME="/home/$username" PATH="/home/$username/.local/bin:/usr/local/bin:$PATH" \
        uv tool install --python 3.12 whisper-ctranslate2 \
        && print_success "whisper-ctranslate2 installed (run: whisper-ctranslate2 --help)" \
        || print_warning "whisper-ctranslate2 installation failed (check network / Python build)"

    # Install Node.js via NVM
    print_status "Installing Node.js via NVM..."
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | sudo -u $username bash

    # Verify NVM installation
    if [ -d "/home/$username/.nvm" ]; then
        print_success "NVM installed successfully"
    else
        print_warning "NVM installation may have failed"
    fi

    # Install Node.js LTS
    sudo -u $username bash -c "source /home/$username/.nvm/nvm.sh && nvm install --lts && nvm use --lts && nvm alias default node"

    # Verify Node.js installation
    if sudo -u $username bash -c "source /home/$username/.nvm/nvm.sh && node --version" &>/dev/null; then
        NODE_VERSION=$(sudo -u $username bash -c "source /home/$username/.nvm/nvm.sh && node --version")
        print_success "Node.js $NODE_VERSION installed via NVM"
    else
        print_warning "Node.js installation may have failed"
    fi
    
    # Install Go
    print_status "Installing Go ${CONFIG[GO_VERSION]}..."
    if wget -q "https://go.dev/dl/go${CONFIG[GO_VERSION]}.linux-amd64.tar.gz" -O /tmp/go.tar.gz; then
        rm -rf /usr/local/go
        tar -C /usr/local -xzf /tmp/go.tar.gz
        rm /tmp/go.tar.gz
        
        # Verify Go installation
        export PATH=$PATH:/usr/local/go/bin
        if /usr/local/go/bin/go version &>/dev/null; then
            print_success "Go ${CONFIG[GO_VERSION]} installed"
        else
            print_warning "Go installation may have failed"
        fi
    else
        print_warning "Failed to download Go ${CONFIG[GO_VERSION]}"
    fi
    
    # Install Docker
    print_status "Installing Docker and container tools..."
    # Remove existing keyring if present (prevents overwrite prompt)
    rm -f /usr/share/keyrings/docker-archive-keyring.gpg
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    
    # Add user to docker group
    usermod -aG docker "$username"
    print_success "User added to docker group"

    # Configure Docker auto-cleanup (BuildKit GC + daily prune timer)
    print_status "Configuring Docker auto-cleanup..."
    command -v jq >/dev/null 2>&1 || apt install -y jq
    mkdir -p /etc/docker
    docker_gc_config='{"builder":{"gc":{"enabled":true,"defaultKeepStorage":"20GB","policy":[{"keepStorage":"10GB","filter":["unused-for=48h"]},{"keepStorage":"20GB"}]}}}'
    if [ -s /etc/docker/daemon.json ]; then
        jq -s '.[0] * .[1]' /etc/docker/daemon.json <(echo "$docker_gc_config") > /etc/docker/daemon.json.new \
            && mv /etc/docker/daemon.json.new /etc/docker/daemon.json
    else
        echo "$docker_gc_config" | jq '.' > /etc/docker/daemon.json
    fi
    cat > /etc/systemd/system/docker-prune.service <<'EOF'
[Unit]
Description=Prune unused Docker images and stopped containers older than 168h
Wants=docker.service
After=docker.service
ConditionPathExists=/var/run/docker.sock

[Service]
Type=oneshot
ExecStart=/usr/bin/docker system prune -af --filter until=168h
EOF
    cat > /etc/systemd/system/docker-prune.timer <<'EOF'
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
    print_success "Docker auto-cleanup configured (build cache 48h, images/containers 168h)"

    # Install Kubernetes tools
    print_status "Installing Kubernetes tools..."
    
    # Remove old Kubernetes repository if it exists
    rm -f /etc/apt/sources.list.d/kubernetes.list
    rm -f /usr/share/keyrings/kubernetes-archive-keyring.gpg
    rm -f /usr/share/keyrings/kubernetes-apt-keyring.gpg

    # Add the new Kubernetes apt repository
    if curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.33/deb/Release.key | gpg --dearmor -o /usr/share/keyrings/kubernetes-apt-keyring.gpg 2>/dev/null; then
        echo "deb [signed-by=/usr/share/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.33/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
        print_success "Kubernetes repository added"
    else
        print_warning "Failed to add Kubernetes repository key"
    fi
    
    if apt update; then
        apt install -y kubectl || print_warning "Failed to install kubectl"
    else
        print_warning "Failed to update package lists after adding Kubernetes repository"
    fi
    
    # Install minikube
    curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
    install minikube-linux-amd64 /usr/local/bin/minikube
    rm minikube-linux-amd64
    
    # Install Helm
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    
    # Install k9s
    wget -q https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_amd64.tar.gz -O /tmp/k9s.tar.gz
    tar -xzf /tmp/k9s.tar.gz -C /tmp/
    mv /tmp/k9s /usr/local/bin/
    rm /tmp/k9s.tar.gz
    
    print_success "Docker and container tools installed"
    
    # Install development tools
    print_status "Installing additional development tools..."
    
    # LazyGit
    LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | grep -Po '"tag_name": "v\K[^"]*')
    curl -Lo /tmp/lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz"
    tar -xzf /tmp/lazygit.tar.gz -C /usr/local/bin/
    rm /tmp/lazygit.tar.gz

    # Install zoxide (smart cd replacement)
    print_status "Installing zoxide..."
    curl -sS https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | bash
    if [ -f /root/.local/bin/zoxide ]; then
        cp /root/.local/bin/zoxide /usr/local/bin/
        print_success "zoxide installed"
    else
        print_warning "zoxide installation may have failed"
    fi

    # Install starship (modern prompt)
    print_status "Installing starship..."
    curl -sS https://starship.rs/install.sh | sh -s -- -y
    if command -v starship &> /dev/null; then
        print_success "starship installed"
    else
        print_warning "starship installation may have failed"
    fi

    # Install fastfetch (modern neofetch replacement)
    print_status "Installing fastfetch..."
    FASTFETCH_VERSION=$(curl -s "https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest" | grep -Po '"tag_name": "\K[^"]*')
    if [ -n "$FASTFETCH_VERSION" ]; then
        curl -sL "https://github.com/fastfetch-cli/fastfetch/releases/download/${FASTFETCH_VERSION}/fastfetch-linux-amd64.deb" -o /tmp/fastfetch.deb
        if dpkg -i /tmp/fastfetch.deb 2>/dev/null; then
            print_success "fastfetch installed"
        else
            print_warning "fastfetch installation failed"
        fi
        rm -f /tmp/fastfetch.deb
    else
        print_warning "Could not determine fastfetch version"
    fi

    # Install dust (modern du replacement)
    print_status "Installing dust..."
    DUST_VERSION=$(curl -s "https://api.github.com/repos/bootandy/dust/releases/latest" | grep -Po '"tag_name": "v\K[^"]*')
    if [ -n "$DUST_VERSION" ]; then
        curl -sL "https://github.com/bootandy/dust/releases/download/v${DUST_VERSION}/dust-v${DUST_VERSION}-x86_64-unknown-linux-musl.tar.gz" -o /tmp/dust.tar.gz
        tar -xzf /tmp/dust.tar.gz -C /tmp/
        if [ -f /tmp/dust-v${DUST_VERSION}-x86_64-unknown-linux-musl/dust ]; then
            mv /tmp/dust-v${DUST_VERSION}-x86_64-unknown-linux-musl/dust /usr/local/bin/
            chmod +x /usr/local/bin/dust
            print_success "dust installed"
        else
            print_warning "dust binary not found after extraction"
        fi
        rm -rf /tmp/dust.tar.gz /tmp/dust-v${DUST_VERSION}-x86_64-unknown-linux-musl
    else
        print_warning "Could not determine dust version"
    fi

    # Install btop (modern htop replacement)
    print_status "Installing btop..."
    set +e  # Temporarily disable exit on error for btop installation

    # Clean up any previous btop installation attempts
    rm -rf /tmp/btop.tbz /tmp/btop 2>/dev/null || true

    BTOP_VERSION=$(curl -s --max-time 10 "https://api.github.com/repos/aristocratos/btop/releases/latest" | grep -Po '"tag_name": "v\K[^"]*')
    if [ -n "$BTOP_VERSION" ]; then
        print_status "Downloading btop ${BTOP_VERSION}..."
        if curl -sL --max-time 60 "https://github.com/aristocratos/btop/releases/download/v${BTOP_VERSION}/btop-x86_64-linux-musl.tbz" -o /tmp/btop.tbz 2>/dev/null; then
            print_status "Extracting btop..."
            if tar -xjf /tmp/btop.tbz -C /tmp/ 2>/dev/null; then
                if [ -f /tmp/btop/bin/btop ]; then
                    mv /tmp/btop/bin/btop /usr/local/bin/ 2>/dev/null || true
                    chmod +x /usr/local/bin/btop 2>/dev/null || true
                    print_success "btop installed"
                else
                    print_warning "btop binary not found after extraction"
                fi
            else
                print_warning "Failed to extract btop archive (may need bzip2)"
            fi
        else
            print_warning "Failed to download btop"
        fi
    else
        print_warning "Could not determine btop version, skipping btop installation"
    fi

    # Clean up
    rm -rf /tmp/btop.tbz /tmp/btop 2>/dev/null || true
    set -e  # Re-enable exit on error

    # Install Go development tools
    # Export Go path for the current session
    export PATH=$PATH:/usr/local/go/bin
    
    # Install tools with proper PATH
    sudo -u $username bash -c "export PATH=$PATH:/usr/local/go/bin && go install golang.org/x/tools/gopls@latest" || print_warning "Failed to install gopls"
    sudo -u $username bash -c "export PATH=$PATH:/usr/local/go/bin && go install github.com/go-delve/delve/cmd/dlv@latest" || print_warning "Failed to install dlv"
    sudo -u $username bash -c "export PATH=$PATH:/usr/local/go/bin && go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest" || print_warning "Failed to install golangci-lint"
    
    # Install Node.js global packages
    sudo -u $username bash -c "source /home/$username/.nvm/nvm.sh && npm install -g yarn pnpm typescript ts-node nodemon pm2 eslint prettier"

    # Install Claude Code and Gemini CLI
    print_status "Installing Claude Code and Gemini CLI..."
    sudo -u $username bash -c "source /home/$username/.nvm/nvm.sh && npm install -g @anthropic-ai/claude-code"
    sudo -u $username bash -c "source /home/$username/.nvm/nvm.sh && npm install -g @google/gemini-cli"

    # Add aliases to user's bashrc (not root's)
    echo "alias claude-go=\"claude --dangerously-skip-permissions\"" >> "/home/$username/.bashrc"
    echo "alias claude-gores=\"claude --dangerously-skip-permissions --resume\"" >> "/home/$username/.bashrc"
    echo "alias gemini-go=\"GOOGLE_CLOUD_PROJECT=main-416722 gemini --yolo\"" >> "/home/$username/.bashrc"

    print_success "Development tools installed"
    
    # Configure Git
    print_status "Configuring Git..."
    # NOTE: These are personal settings - modify for your own use or use CONFIG variables
    sudo -u $username git config --global user.email "sellitus@gmail.com"
    sudo -u $username git config --global user.name "Sellitus"
    sudo -u $username git config --global push.default simple
    sudo -u $username git config --global init.defaultBranch main
    sudo -u $username git config --global core.editor nvim
    print_success "Git configured"
    
    # Final cleanup
    print_status "Cleaning up..."
    apt autoremove -y
    apt autoclean -y
    print_success "Core system setup complete"
fi

# Security Hardening
if [[ $securityChoice == "y" ]]; then
    print_header "Security Hardening"
    
    # Pre-configure security packages
    preconfigure_packages
    
    # Install security packages using batch installer
    print_status "Installing security tools..."
    securityApps_array=($securityApps)
    batch_install_packages "${securityApps_array[@]}"

    # Fix any broken packages before continuing (prevents subsequent apt failures)
    print_status "Cleaning up package state..."
    apt-get -f install -y 2>/dev/null || true
    dpkg --configure -a 2>/dev/null || true

    # NOTE: Cleanup of incompatible packages (debsecan, apt-listchanges) moved to
    # pre-flight checks (lines 694-699) to prevent failures during apt-get full-upgrade
    # This ensures cleanup happens BEFORE apt operations, not after

    # Configure UFW
    print_status "Configuring firewall..."
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp comment 'SSH'
    ufw limit 22/tcp
    ufw --force enable
    print_success "Firewall configured"
    
    # Configure Fail2ban
    print_status "Configuring Fail2ban..."
    cat > /etc/fail2ban/jail.local << 'EOL'
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
EOL
    
    systemctl enable fail2ban
    systemctl restart fail2ban
    print_success "Fail2ban configured"
    
    # AIDE configuration skipped - initialization takes 10-30+ minutes
    # If you want file integrity monitoring, samhain is configured below
    # To manually initialize AIDE later: sudo aideinit && sudo mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db

    # Configure rkhunter
    print_status "Configuring rkhunter..."

    # Fix rkhunter configuration for reliable updates
    if [ -f /etc/rkhunter.conf ]; then
        # Set proper WEB_CMD with timeout to avoid hangs
        sed -i 's|^WEB_CMD=.*|WEB_CMD="/usr/bin/curl -fsS --connect-timeout 10"|' /etc/rkhunter.conf
        sed -i 's|^#WEB_CMD=.*|WEB_CMD="/usr/bin/curl -fsS --connect-timeout 10"|' /etc/rkhunter.conf
        # Allow package manager updates
        sed -i 's|^#PKGMGR=.*|PKGMGR=DPKG|' /etc/rkhunter.conf
        # Use any available mirror (not just local)
        sed -i 's|^MIRRORS_MODE=.*|MIRRORS_MODE=0|' /etc/rkhunter.conf
        sed -i 's|^#MIRRORS_MODE=.*|MIRRORS_MODE=0|' /etc/rkhunter.conf
        # Enable mirror list updates
        sed -i 's|^UPDATE_MIRRORS=.*|UPDATE_MIRRORS=1|' /etc/rkhunter.conf
        sed -i 's|^#UPDATE_MIRRORS=.*|UPDATE_MIRRORS=1|' /etc/rkhunter.conf
    fi

    # rkhunter updates often fail due to network issues - don't exit script
    set +e
    rkhunter --update 2>/dev/null || print_warning "rkhunter update failed (network issue), continuing..."
    rkhunter --propupd 2>/dev/null || print_warning "rkhunter propupd failed, continuing..."
    set -e

    print_success "rkhunter configured"

    # Configure ClamAV
    print_status "Configuring ClamAV..."
    set +e
    systemctl stop clamav-freshclam 2>/dev/null || true
    print_status "Updating ClamAV virus definitions (this may take a moment)..."
    freshclam 2>/dev/null || print_warning "freshclam update failed, will retry on next run"
    systemctl start clamav-freshclam 2>/dev/null || true
    systemctl enable clamav-daemon 2>/dev/null || true
    set -e
    print_success "ClamAV configured"

    # Configure auditd
    print_status "Configuring auditd..."
    cat >> /etc/audit/rules.d/audit.rules << 'EOL'
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
EOL

    set +e
    service auditd restart 2>/dev/null || print_warning "auditd restart had warnings, rules will apply on next boot"
    set -e
    print_success "Auditd configured"
    
    # Configure automatic security updates
    print_status "Configuring automatic security updates..."
    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOL'
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
EOL
    
    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOL'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOL
    
    print_success "Automatic security updates configured"
    
    # System hardening
    print_status "Applying system hardening..."
    
    # Kernel hardening via sysctl
    cat >> /etc/sysctl.d/99-security.conf << 'EOL'
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

# Ignore ICMP ping requests
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Ignore Directed pings
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Accept ICMP redirects only for gateways listed in default gateway list
net.ipv4.conf.all.secure_redirects = 1

# Do not accept IP source route packets
net.ipv4.conf.all.accept_source_route = 0

# Protect against tcp time-wait assassination hazards
net.ipv4.tcp_rfc1337 = 1

# Decrease the time default value for tcp_fin_timeout connection
net.ipv4.tcp_fin_timeout = 15

# Decrease the time default value for connections to keep alive
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15

# Enable ExecShield protection
kernel.randomize_va_space = 2

# Increase system file descriptor limit
fs.file-max = 65535

# Allow for more PIDs
kernel.pid_max = 65535

# Increase system IP port limits
net.ipv4.ip_local_port_range = 2000 65000
EOL
    
    set +e
    sysctl -p /etc/sysctl.d/99-security.conf 2>/dev/null || print_warning "Some sysctl settings may not have applied"

    # Configure password quality
    # Note: libpam-pwquality should already be installed from batch, but ensure it's there
    apt install -y libpam-pwquality 2>/dev/null || true

    # Configure password quality settings (only if config file exists)
    if [ -f /etc/security/pwquality.conf ]; then
        sed -i 's/# minlen = 8/minlen = 12/' /etc/security/pwquality.conf
        sed -i 's/# ucredit = -1/ucredit = -1/' /etc/security/pwquality.conf
        sed -i 's/# lcredit = -1/lcredit = -1/' /etc/security/pwquality.conf
        sed -i 's/# dcredit = -1/dcredit = -1/' /etc/security/pwquality.conf
        sed -i 's/# ocredit = -1/ocredit = -1/' /etc/security/pwquality.conf
    else
        print_warning "Password quality config not found, skipping configuration"
    fi
    set -e

    print_success "System hardening applied"
    
    # Setup security scanning cron jobs
    print_status "Setting up automated security scans..."
    
    cat > /etc/cron.daily/security-scans << 'EOL'
#!/bin/bash
# Daily security scans

# Update security databases
freshclam > /dev/null 2>&1
rkhunter --update > /dev/null 2>&1

# Run scans
clamscan -r / --quiet --infected --log=/var/log/clamav/daily-scan.log
rkhunter --check --skip-keypress --quiet
lynis audit system --quiet

# Check for security updates
/usr/lib/update-notifier/apt-check --human-readable > /var/log/security-updates.log
EOL
    
    chmod +x /etc/cron.daily/security-scans
    
    print_success "Automated security scans configured"
    
    # Tripwire installation notice
    echo
    print_warning "Note: Tripwire was not installed automatically as it requires interactive configuration."
    print_status "To install Tripwire manually, run:"
    echo -e "${CYAN}    sudo apt install tripwire${NC}"
    echo -e "${CYAN}    # You will be prompted to set site and local passphrases${NC}"
    echo
    
    print_success "Security hardening complete"
fi

# Server Setup
if [[ $serverChoice == "y" ]]; then
    print_header "Server Setup"
    
    print_status "Installing server packages..."
    for package in $serverApps; do
        apt install -y "$package" || print_warning "Failed to install $package"
    done
    
    # SSH Hardening
    print_status "Hardening SSH configuration..."
    
    # Backup original SSH config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
    
    # Generate SSH keys for user
    sudo -u $username mkdir -p "/home/$username/.ssh"
    sudo -u $username chmod 700 "/home/$username/.ssh"

    # Add your public key
    # NOTE: This is a personal SSH key - replace with your own public key
    ssh_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPuPn0cnBDl7BOEecgcbrWvM+dIBuKZZaRYRMqoYv2Aw sellitus@ss-MacBook-Pro.local"
    auth_keys_file="/home/$username/.ssh/authorized_keys"
    if [ -f "$auth_keys_file" ]; then
        # Only add if key doesn't already exist (preserves existing keys)
        if ! grep -qF "AAAAC3NzaC1lZDI1NTE5AAAAIPuPn0cnBDl7BOEecgcbrWvM+dIBuKZZaRYRMqoYv2Aw" "$auth_keys_file"; then
            echo "$ssh_key" >> "$auth_keys_file"
        fi
    else
        echo "$ssh_key" > "$auth_keys_file"
    fi
    chown "$username:$username" "$auth_keys_file"
    chmod 600 "$auth_keys_file"
    
    # Create hardened SSH config
    cat > /etc/ssh/sshd_config.d/99-hardened.conf << EOL
# Hardened SSH Configuration
Port 22
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key

# Authentication
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
AuthenticationMethods publickey
AllowUsers $username

# Security
PermitEmptyPasswords no
X11Forwarding no
IgnoreRhosts yes
HostbasedAuthentication no
PermitUserEnvironment no
StrictModes yes

# Performance
UseDNS no
Compression no

# Logging
SyslogFacility AUTH
LogLevel VERBOSE

# Connection limits
MaxAuthTries 3
MaxSessions 10
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 30

# Ciphers and algorithms
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com,hmac-sha2-512,hmac-sha2-256
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
EOL

    # Create sshd privilege separation directory if missing
    mkdir -p /run/sshd

    # Test SSH config
    set +e  # Don't exit on error, we handle it below
    sshd -t 2>&1
    sshd_test_result=$?
    set -e

    if [ $sshd_test_result -eq 0 ]; then
        set +e
        systemctl restart ssh
        if [ $? -eq 0 ]; then
            print_success "SSH hardened and restarted"
        else
            print_warning "SSH restart failed, changes will apply on next boot"
        fi
        set -e
    else
        print_warning "SSH config test had warnings, but continuing (config applied)"
        # Still restart ssh even with warnings - config is likely fine
        set +e
        systemctl restart ssh 2>/dev/null || print_warning "SSH restart failed, changes will apply on next boot"
        set -e
    fi
    
    # Configure Nginx
    print_status "Configuring Nginx..."

    # Remove existing security.conf to prevent duplicates on rerun
    rm -f /etc/nginx/conf.d/security.conf

    # Create a basic secure Nginx config
    # Note: SSL directives removed as they should be in server blocks, not globally
    cat > /etc/nginx/conf.d/security.conf << 'EOL'
# Security headers
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "no-referrer-when-downgrade" always;
add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'" always;

# Hide Nginx version
server_tokens off;

# Limit request size
client_max_body_size 10M;
EOL

    # Test nginx config and restart (don't exit script on failure)
    set +e
    nginx -t 2>&1
    if [ $? -eq 0 ]; then
        systemctl restart nginx
        print_success "Nginx configured and restarted"
    else
        print_warning "Nginx config test failed, keeping previous configuration"
        rm -f /etc/nginx/conf.d/security.conf
    fi
    set -e
    
    # Setup automatic updates cron
    print_status "Setting up automatic security updates..."

    set +e
    (crontab -l 2>/dev/null || true; echo "0 6 * * * apt update && apt-get -y upgrade && apt-get -y autoremove && apt-get -y autoclean && needrestart -ra") | crontab - || print_warning "Failed to setup automatic updates cron job"
    set -e

    print_success "Server setup complete"
fi

# MATE Desktop Environment
if [[ $mateChoice == "y" ]]; then
    print_header "MATE Desktop Environment"
    
    print_status "Installing MATE desktop packages..."
    mateDesktop_array=($mateDesktop)
    batch_install_packages "${mateDesktop_array[@]}"
    
    # Install additional useful desktop utilities
    desktop_utils="pluma atril eom gnome-system-monitor dconf-editor"
    desktop_utils_array=($desktop_utils)
    batch_install_packages "${desktop_utils_array[@]}"
    
    # Configure MATE for better performance
    sudo -u $username dbus-launch dconf write /org/mate/desktop/interface/gtk-enable-animations false
    sudo -u $username dbus-launch dconf write /org/mate/marco/general/compositing-manager false
    
    print_success "MATE desktop environment installed"
fi

# GUI Applications
if [[ $guiChoice == "y" ]]; then
    print_header "GUI Applications"
    
    # Add repositories
    print_status "Adding application repositories..."

    # Sublime Text
    # Remove any prior keyring location (legacy global trust dir) and write to /usr/share/keyrings for deb822-compatible Signed-By
    rm -f /etc/apt/trusted.gpg.d/sublimehq-archive.gpg /usr/share/keyrings/sublimehq-archive-keyring.gpg
    wget -qO - https://download.sublimetext.com/sublimehq-pub.gpg | gpg --dearmor -o /usr/share/keyrings/sublimehq-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/sublimehq-archive-keyring.gpg] https://download.sublimetext.com/ apt/stable/" | tee /etc/apt/sources.list.d/sublime-text.list > /dev/null
    
    # Install GUI packages
    print_status "Installing GUI applications..."
    guiApps_array=($guiApps)
    batch_install_packages "${guiApps_array[@]}"
    
    # Install additional development IDEs via snap
    print_status "Installing development IDEs..."

    # Skip VS Code in WSL (should use Windows version instead)
    if detect_wsl; then
        print_warning "Running in WSL - skipping VS Code installation"
        print_status "Install VS Code in Windows and use the 'code' command from WSL"
    else
        snap install code --classic
    fi

    snap install pycharm-community --classic
    snap install intellij-idea-community --classic
    snap install goland --classic || print_warning "GoLand requires license"

    # Install VS Code extensions (skip in WSL since we don't install VS Code there)
    if command -v code &> /dev/null && ! detect_wsl; then
        print_status "Installing VS Code extensions..."

        extensions=(
            "anthropic.claude-code"
            "golang.go"
            "google.geminicodeassist"
            "ms-python.debugpy"
            "ms-python.python"
            "ms-python.vscode-pylance"
            "ms-python.vscode-python-envs"
            "rooveterinaryinc.roo-cline"
            "saoudrizwan.claude-dev"
        )

        for ext in "${extensions[@]}"; do
            # Use --force to avoid interactive prompts
            sudo -u $username code --install-extension "$ext" --force 2>/dev/null || print_warning "Failed to install extension: $ext"
        done
        
        # Configure VS Code settings
        mkdir -p "/home/$username/.config/Code/User"
        cat > "/home/$username/.config/Code/User/settings.json" << 'EOL'
{
    "workbench.colorTheme": "Default Dark+",
    "editor.fontSize": 14,
    "editor.fontFamily": "'JetBrains Mono', 'Fira Code', 'Cascadia Code', Consolas, monospace",
    "editor.fontLigatures": true,
    "editor.wordWrap": "on",
    "editor.minimap.enabled": true,
    "editor.formatOnSave": true,
    "editor.formatOnPaste": true,
    "editor.suggestSelection": "first",
    "editor.snippetSuggestions": "top",
    "editor.tabSize": 4,
    "editor.detectIndentation": true,
    "editor.rulers": [80, 120],
    "editor.bracketPairColorization.enabled": true,
    "editor.guides.indentation": true,
    "files.autoSave": "afterDelay",
    "files.autoSaveDelay": 1000,
    "files.trimTrailingWhitespace": true,
    "files.insertFinalNewline": true,
    "workbench.editor.wrapTabs": true,
    "workbench.editor.tabSizing": "shrink",
    "terminal.integrated.fontSize": 13,
    "terminal.integrated.shell.linux": "/bin/bash",
    "git.autofetch": true,
    "git.confirmSync": false,
    "git.enableSmartCommit": true,
    "python.defaultInterpreterPath": "python3",
    "python.linting.enabled": true,
    "python.linting.pylintEnabled": true,
    "python.formatting.provider": "black",
    "go.useLanguageServer": true,
    "go.toolsManagement.autoUpdate": true,
    "[python]": {
        "editor.defaultFormatter": "ms-python.black-formatter"
    },
    "[javascript]": {
        "editor.defaultFormatter": "esbenp.prettier-vscode"
    },
    "[typescript]": {
        "editor.defaultFormatter": "esbenp.prettier-vscode"
    },
    "[json]": {
        "editor.defaultFormatter": "esbenp.prettier-vscode"
    }
}
EOL
        chown -R "$username:$username" "/home/$username/.config/Code"
    fi
    
    # Install fonts for development
    print_status "Installing development fonts..."
    apt install -y fonts-firacode fonts-cascadia-code
    
    # Install JetBrains Mono
    wget -q https://github.com/JetBrains/JetBrainsMono/releases/download/v2.304/JetBrainsMono-2.304.zip -O /tmp/jetbrains-mono.zip
    unzip -q /tmp/jetbrains-mono.zip -d /tmp/jetbrains-mono
    mkdir -p /usr/share/fonts/truetype/jetbrains-mono
    cp /tmp/jetbrains-mono/fonts/ttf/*.ttf /usr/share/fonts/truetype/jetbrains-mono/
    fc-cache -f -v
    rm -rf /tmp/jetbrains-mono*
    
    print_success "GUI applications installed"
fi

# VM Guest Additions
if [[ $vmGuestChoice == "y" ]]; then
    print_header "VM Guest Additions"
    
    print_status "Installing VMware/VirtualBox guest additions..."
    vmGuestAdditions_array=($vmGuestAdditions)
    batch_install_packages "${vmGuestAdditions_array[@]}"
    
    print_success "VM guest additions installed"
fi

# Hyper-V Guest Additions
if [[ $hyperVGuestChoice == "y" ]]; then
    print_header "Hyper-V Guest Additions"
    
    print_status "Installing Hyper-V guest additions..."
    
    # Add Hyper-V modules to initramfs
    for module in hv_utils hv_vmbus hv_storvsc hv_blkvsc hv_netvsc; do
        echo "$module" >> /etc/initramfs-tools/modules
    done
    
    # Install packages
    hyperVGuestAdditions_array=($hyperVGuestAdditions)
    batch_install_packages "${hyperVGuestAdditions_array[@]}"
    
    # Update initramfs
    update-initramfs -u
    
    print_success "Hyper-V guest additions installed"
fi

# Final steps
if [[ $basicChoice == "y" ]] || [[ $securityChoice == "y" ]]; then
    print_header "Final Configuration"
    
    # Configure Docker to respect UFW
    if systemctl is-active docker &>/dev/null && systemctl is-active ufw &>/dev/null; then
        print_status "Configuring Docker firewall rules..."
        
        # Get default network interface
        default_interface=$(ip route | grep default | head -n 1 | awk '{print $5}')
        
        if [[ ! -f /etc/ufw/after.rules.backup ]]; then
            cp /etc/ufw/after.rules /etc/ufw/after.rules.backup
        fi
        
        # Add Docker UFW rules if not already present
        if ! grep -q "DOCKER-USER" /etc/ufw/after.rules; then
            cat >> /etc/ufw/after.rules << EOL

# BEGIN UFW AND DOCKER
*filter
:DOCKER-USER - [0:0]
:ufw-user-input - [0:0]

-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A DOCKER-USER -m conntrack --ctstate INVALID -j DROP
-A DOCKER-USER -i $default_interface -j ufw-user-input
-A DOCKER-USER -i $default_interface -j DROP
COMMIT
# END UFW AND DOCKER
EOL
        fi
        
        systemctl restart ufw
        systemctl restart docker
        print_success "Docker firewall rules configured"
    fi
    
    # Final system cleanup
    print_status "Performing final cleanup..."
    apt-get autoremove -y
    apt-get autoclean -y
    apt-get clean
    
    # Remove unnecessary packages
    apt-get purge -y popularity-contest 2>/dev/null || true

    # Update locate database (if plocate/mlocate is installed)
    if command -v updatedb &> /dev/null; then
        updatedb 2>/dev/null || print_warning "updatedb failed, skipping"
    fi

    # =========================================================================
    # NVIDIA GPU Detection and Driver Installation
    # =========================================================================
    print_status "Checking for NVIDIA GPU..."

    # Disable errexit for this block — driver install is best-effort and must
    # never abort the rest of the setup script.
    set +e

    if lspci 2>/dev/null | grep -qi nvidia; then
        DETECTED_GPU=$(lspci | grep -i nvidia | head -n1 | sed 's/.*: //')
        print_status "NVIDIA GPU detected: $DETECTED_GPU"

        # Check if a driver is already loaded
        if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
            EXISTING_DRIVER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1)
            print_success "NVIDIA driver already installed (version $EXISTING_DRIVER) — skipping installation"
        else
            print_status "No working NVIDIA driver found. Attempting to install latest open kernel module driver..."

            NVIDIA_PKG=""

            # Strategy 1: Use ubuntu-drivers to find the recommended -open driver
            apt-get install -y ubuntu-drivers-common &>/dev/null
            if command -v ubuntu-drivers &>/dev/null; then
                # ubuntu-drivers devices outputs lines like:
                #   nvidia-driver-550-open - distro non-free recommended
                NVIDIA_PKG=$(ubuntu-drivers devices 2>/dev/null \
                    | grep -oP 'nvidia-driver-\d+-open' \
                    | sort -t- -k3 -n \
                    | tail -n1)
                if [[ -n "$NVIDIA_PKG" ]]; then
                    print_status "ubuntu-drivers recommends: $NVIDIA_PKG"
                fi
            fi

            # Strategy 2 (fallback): Query apt-cache for highest-versioned -open package
            if [[ -z "$NVIDIA_PKG" ]]; then
                print_warning "ubuntu-drivers did not find a recommended -open driver, falling back to apt-cache search..."
                NVIDIA_PKG=$(apt-cache pkgnames nvidia-driver- 2>/dev/null \
                    | grep -E '^nvidia-driver-[0-9]+-open$' \
                    | sort -t- -k3 -n \
                    | tail -n1)
                if [[ -n "$NVIDIA_PKG" ]]; then
                    print_status "apt-cache found: $NVIDIA_PKG"
                fi
            fi

            if [[ -n "$NVIDIA_PKG" ]]; then
                print_status "Installing $NVIDIA_PKG ..."
                if apt-get install -y "$NVIDIA_PKG"; then
                    print_success "$NVIDIA_PKG installed successfully. A reboot is required to activate the driver."
                else
                    print_error "Failed to install $NVIDIA_PKG. You may need to install the driver manually after reboot."
                fi
            else
                print_warning "Could not determine an appropriate NVIDIA open driver package. Install manually after reboot."
            fi
        fi
    else
        print_status "No NVIDIA GPU detected — skipping driver installation"
    fi

    set -euo pipefail

    # =========================================================================
    # NVIDIA driver/kernel-module mismatch guard
    # =========================================================================
    # An upgraded userspace driver beside the still-loaded old kernel module
    # breaks NVML/CUDA for every new process ("Driver/library version mismatch")
    # and does not create /var/run/reboot-required, so unattended-upgrades
    # never reboots for it. Hold the driver back from unattended upgrades, and
    # schedule a reboot whenever the loaded and installed modules diverge.
    if lspci 2>/dev/null | grep -qi nvidia; then
        print_status "Installing NVIDIA driver mismatch guard..."

        # Separate file: apt merges list entries across conf files, and the
        # security section rewrites 50unattended-upgrades wholesale.
        cat > /etc/apt/apt.conf.d/51unattended-upgrades-nvidia <<'EOF'
// NVIDIA driver upgrades need a reboot to load the new kernel module; until
// then CUDA fails in every new process. Upgrade the driver by hand, then reboot.
Unattended-Upgrade::Package-Blacklist {
    "(lib)?nvidia-";
    "xserver-xorg-video-nvidia-";
};
EOF

        cat > /etc/default/nvidia-mismatch-reboot <<'EOF'
# When to reboot after the loaded NVIDIA kernel module diverges from the
# installed one: a shutdown(8) time ("04:30", "+5") or "now".
REBOOT_AT=04:30
EOF

        cat > /usr/local/sbin/nvidia-mismatch-reboot <<'EOF'
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

        cat > /etc/systemd/system/nvidia-mismatch-reboot.service <<'EOF'
[Unit]
Description=Reboot when the loaded NVIDIA kernel module differs from the installed driver

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nvidia-mismatch-reboot
EOF
        cat > /etc/systemd/system/nvidia-mismatch-reboot.timer <<'EOF'
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
        print_success "NVIDIA mismatch guard installed (driver held from unattended upgrades; reboot at 04:30 on mismatch)"
    fi

    # Create summary log
    print_status "Creating installation summary..."
    
    cat > "/home/$username/ubuntu-setup-summary.log" << EOL
Ubuntu Ultimate Setup Script - Installation Summary
===================================================
Date: $(date)
Hostname: $(hostname)
IP Address: $(hostname -I | awk '{print $1}')
Ubuntu Version: $(lsb_release -d | cut -f2)
Kernel: $(uname -r)

Installed Components:
$(
    [[ $basicChoice == "y" ]] && echo "✓ Core System Setup"
    [[ $securityChoice == "y" ]] && echo "✓ Security Hardening"
    [[ $serverChoice == "y" ]] && echo "✓ Server Setup"
    [[ $mateChoice == "y" ]] && echo "✓ MATE Desktop Environment"
    [[ $guiChoice == "y" ]] && echo "✓ GUI Applications"
    [[ $vmGuestChoice == "y" ]] && echo "✓ VM Guest Additions"
    [[ $hyperVGuestChoice == "y" ]] && echo "✓ Hyper-V Guest Additions"
)

Key Information:
- Main user: $username
- Python version: $(python3 --version)
- uv version: $(uv --version 2>/dev/null || echo "Not installed")
- Node.js version: $(sudo -u $username bash -c 'source ~/.nvm/nvm.sh && node --version' 2>/dev/null || echo "Not installed")
- Go version: $(go version 2>/dev/null || echo "Not installed")
- Docker version: $(docker --version 2>/dev/null || echo "Not installed")
- NVIDIA GPU: $(lspci 2>/dev/null | grep -i nvidia | head -n1 | sed 's/.*: //' || echo "None detected")
- NVIDIA Driver: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || echo "Not installed")

Security Status:
- Firewall: $(ufw status | grep -q "Status: active" && echo "Active" || echo "Inactive")
- Fail2ban: $(systemctl is-active fail2ban)
- Automatic updates: Enabled

Next Steps:
1. Review security configurations in /etc/ssh/sshd_config.d/99-hardened.conf
2. Test SSH connection before closing current session
3. Run 'lynis audit system' for security audit
4. Configure application-specific settings as needed

Logs:
- Setup log: ${CONFIG[LOG_FILE]}
- Backup location: ${CONFIG[BACKUP_DIR]}
EOL
    
    chown "$username:$username" "/home/$username/ubuntu-setup-summary.log"
    
    print_success "Installation summary created at: /home/$username/ubuntu-setup-summary.log"
    
    # Print detailed installation summary
    print_installation_summary
    
    # Display summary
    echo
    print_header "Setup Complete!"
    
    echo -e "${GREEN}${ROCKET} Ubuntu Ultimate Setup has been completed successfully!${NC}"
    echo
    echo -e "${CYAN}Summary:${NC}"
    cat "/home/$username/ubuntu-setup-summary.log" | grep "✓" | while read line; do
        echo -e "  ${GREEN}$line${NC}"
    done
    
    echo
    echo -e "${YELLOW}${BOLD}Important:${NC}"
    echo -e "  ${ARROW} A summary has been saved to: ${CYAN}/home/$username/ubuntu-setup-summary.log${NC}"
    echo -e "  ${ARROW} System backup created at: ${CYAN}${CONFIG[BACKUP_DIR]}${NC}"
    echo -e "  ${ARROW} Setup log available at: ${CYAN}${CONFIG[LOG_FILE]}${NC}"
    
    if [[ $serverChoice == "y" ]]; then
        echo
        echo -e "${RED}${BOLD}SSH Security Notice:${NC}"
        echo -e "  ${ARROW} SSH has been hardened - only key-based authentication is allowed"
        echo -e "  ${ARROW} Test SSH connection before closing this session!"
        echo -e "  ${ARROW} SSH user: ${CYAN}$username${NC}"
    fi
    
    if [[ $preventRebootChoice != "y" ]]; then
        echo
        echo -e "${YELLOW}${BOLD}System will reboot in 10 seconds...${NC}"
        echo -e "${YELLOW}Press Ctrl+C to cancel${NC}"
        
        for i in {10..1}; do
            echo -ne "\r${YELLOW}Rebooting in $i seconds... ${NC}"
            sleep 1
        done
        
        echo
        print_status "Rebooting system..."
        reboot
    else
        echo
        echo -e "${YELLOW}${BOLD}Please reboot the system manually to ensure all changes take effect.${NC}"
    fi
fi
