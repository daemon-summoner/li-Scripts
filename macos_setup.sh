#!/bin/bash



# User editable options
brewApps="python@3.13 neovim lazygit coreutils"
brewTools="wget curl jq yq tree htop tmux watch gh uv"
devApps="go cmake protobuf postgresql redis sqlite ffmpeg watchman"
vramLimitMB="114688"


# Initialization
basicChoice=""
serverChoice=""


userInput=$1
if [[ $userInput == "" ]]; then
	echo ""
	echo "Choose some or all of the options below. Separate your choices by comma with no spaces."
	echo "EXAMPLE: 1,2,3"
	echo "1 - Basic Updates and Config"
	echo "    ($brewApps $brewTools $devApps)"
	echo "2 - Increase VRAM Limit"
	echo "    (Set iogpu.wired_limit_mb=$vramLimitMB)"
	echo ""
	read -p ":: " userInput
fi



IFS=',' read -ra ADDR <<< "$userInput"
for i in "${ADDR[@]}"; do
	if [[ $i == "1" ]]; then
		basicChoice="y"
	fi
	if [[ $i == "2" ]]; then
		serverChoice="y"
	fi
done


# Install Homebrew first if needed (handles its own sudo internally, may call sudo -k after)
if [[ $basicChoice == "y" ]]; then
	if ! command -v brew &>/dev/null; then
		NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
		eval "$(/opt/homebrew/bin/brew shellenv)"
	fi
fi

# Cache sudo credentials ONCE for the entire script (after Homebrew, which may invalidate)
if [[ $basicChoice == "y" ]] || [[ $serverChoice == "y" ]]; then
	sudo -v
	# Background keepalive: refresh sudo every 30s until script exits
	(while kill -0 $$ 2>/dev/null; do sleep 30; sudo -n -v 2>/dev/null; done) &
fi


if [[ $basicChoice == "y" ]]; then

	echo ""
	echo ""
	echo "------------------ Basic Updates and Config A ( 1 / 2 ) ---------------------"
	echo ""
	echo ""

	# Make wifi connect to the strongest AP for wifi AP roaming
	if ! sudo crontab -l 2>/dev/null | grep -q 'airport prefs joinMode'; then
		(sudo crontab -l 2>/dev/null; echo "@reboot sudo /System/Library/PrivateFrameworks/Apple80211.framework/Versions/A/Resources/airport prefs joinMode=Strongest") | sudo crontab -
	fi

	# Increase VRAM limit via crontab
	if ! sudo crontab -l 2>/dev/null | grep -q 'iogpu.wired_limit_mb'; then
		(sudo crontab -l 2>/dev/null; echo "@reboot sudo sysctl iogpu.wired_limit_mb=90112") | sudo crontab -
	fi

	# Create ~/.bashrc file
	touch ~/.bashrc

	# source ~/.bashrc in ~/.zshrc
	grep -qxF 'source ~/.bashrc' ~/.zshrc 2>/dev/null || echo "source ~/.bashrc" >> ~/.zshrc

	# Brew install system apps
	for currPackage in $brewApps
	do
		printf "\n\n ----- Installing: %s ----- \n\n" "$currPackage"
		brew install $currPackage
	done

	# Brew install common CLI tools
	for currPackage in $brewTools
	do
		printf "\n\n ----- Installing: %s ----- \n\n" "$currPackage"
		brew install $currPackage
	done

	# Brew install development packages
	for currPackage in $devApps
	do
		printf "\n\n ----- Installing: %s ----- \n\n" "$currPackage"
		brew install $currPackage
	done

	# Upgrade all existing brew packages
	brew upgrade

	# Link gtimeout to timeout for Linux compatibility
	sudo ln -sf /usr/local/bin/gtimeout /usr/local/bin/timeout

	# Switch to using python3.13 installed by brew
	grep -qxF 'alias python=/opt/homebrew/bin/python3.13' ~/.bashrc 2>/dev/null || echo "alias python=/opt/homebrew/bin/python3.13" >> ~/.bashrc
	grep -qxF 'alias pip=/opt/homebrew/bin/pip3.13' ~/.bashrc 2>/dev/null || echo "alias pip=/opt/homebrew/bin/pip3.13" >> ~/.bashrc
	grep -qxF 'alias python3=/opt/homebrew/bin/python3.13' ~/.bashrc 2>/dev/null || echo "alias python3=/opt/homebrew/bin/python3.13" >> ~/.bashrc
	grep -qxF 'alias pip3=/opt/homebrew/bin/pip3.13' ~/.bashrc 2>/dev/null || echo "alias pip3=/opt/homebrew/bin/pip3.13" >> ~/.bashrc

	# Install faster-whisper CLI (whisper-ctranslate2) as an isolated uv tool.
	# Pinned to Python 3.12 for ctranslate2 wheel availability; uv fetches it if missing.
	# Apple Silicon runs CPU-only (CTranslate2 has no Metal/GPU backend).
	uv tool install --python 3.12 whisper-ctranslate2

	# faster-whisper (library) helper: create a local .venv here with faster-whisper via uv
	whisperLibFn='whisper-lib() { uv venv --python 3.12 && uv pip install faster-whisper "$@" && echo "faster-whisper ready in .venv -- activate with: source .venv/bin/activate"; }'
	grep -qxF "$whisperLibFn" ~/.bashrc 2>/dev/null || echo "$whisperLibFn" >> ~/.bashrc

	# Install LunarVim Prereqs
	brew install python node
	curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
	brew install ripgrep

	# Install LunarVim (Neovim 0.10+)
	bash <(curl -s https://raw.githubusercontent.com/lunarvim/lunarvim/master/utils/installer/install.sh) --no-install-dependencies
	grep -qxF 'export PATH=~/.local/bin:$PATH' ~/.bashrc 2>/dev/null || echo 'export PATH=~/.local/bin:$PATH' >> ~/.bashrc

	# Replace vim with lvim
	grep -qxF 'alias vim1=/usr/bin/vim' ~/.bashrc 2>/dev/null || echo "alias vim1=/usr/bin/vim" >> ~/.bashrc
	grep -qxF 'alias vim=lvim' ~/.bashrc 2>/dev/null || echo "alias vim=lvim" >> ~/.bashrc

	# Install VS Code
	CODE="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
	brew install --cask visual-studio-code 2>/dev/null || true

	# Install VSCode plugins
	"$CODE" --install-extension anthropic.claude-code
	"$CODE" --install-extension golang.go
	"$CODE" --install-extension google.geminicodeassist
	"$CODE" --install-extension ms-python.debugpy
	"$CODE" --install-extension ms-python.python
	"$CODE" --install-extension ms-python.vscode-pylance
	"$CODE" --install-extension ms-python.vscode-python-envs
	"$CODE" --install-extension rooveterinaryinc.roo-cline
	"$CODE" --install-extension saoudrizwan.claude-dev

	# Add new settings
	mkdir -p "$HOME/Library/Application Support/Code/User"
	cat > "$HOME/Library/Application Support/Code/User/settings.json" <<-'VSCODE_SETTINGS'
	{
	    "workbench.editor.wrapTabs": true,
	    "workbench.editor.tabSizing": "shrink",
	    "files.autoSave": "afterDelay",
	    "editor.wordWrap": "on"
	}
	VSCODE_SETTINGS

	# Install Docker via Colima (lightweight Docker runtime for macOS)
	brew install docker colima docker-compose
	# Memory is a cap the VM grows into and keeps until it restarts: a quarter of RAM, at
	# most 16 GB, and half the CPUs, at most 8, as install_docker_colima.sh sizes it.
	colima_cpu=$(( $(sysctl -n hw.ncpu) / 2 ))
	(( colima_cpu > 8 )) && colima_cpu=8
	(( colima_cpu < 2 )) && colima_cpu=2
	colima_memory=$(( $(sysctl -n hw.memsize) / 4294967296 ))
	(( colima_memory > 16 )) && colima_memory=16
	(( colima_memory < 4 )) && colima_memory=4
	colima start --cpu "$colima_cpu" --memory "$colima_memory"

fi


# Increase VRAM limit
if [[ $serverChoice == "y" ]]; then

	if ! grep -q "iogpu.wired_limit_mb" /etc/sysctl.conf 2>/dev/null; then
		sudo sh -c "echo \"iogpu.wired_limit_mb=$vramLimitMB\" >> /etc/sysctl.conf"
	fi
	sudo sysctl iogpu.wired_limit_mb=$vramLimitMB
	echo "VRAM limit set to ${vramLimitMB}MB (applied immediately and persisted to /etc/sysctl.conf)."

fi


if [[ $basicChoice == "y" ]]; then

	echo ""
	echo ""
	echo "------------------ Basic Updates and Config B ( 2 / 2 ) ---------------------"
	echo ""
	echo ""


	echo ""
	echo ""
	echo "TO COMPLETE SETUP: Run LunarVim and then run ':LvimSyncCorePlugins' to sync plugins"
	echo ""
	echo ""

fi
