#!/usr/bin/env bash
# setup/modules/editors.sh - VS Code, shared extensions and settings. Sourced.

_LI_VSCODE_EXTS=(
	anthropic.claude-code
	golang.go
	google.geminicodeassist
	ms-python.debugpy
	ms-python.python
	ms-python.vscode-pylance
	ms-python.vscode-python-envs
	rooveterinaryinc.roo-cline
	saoudrizwan.claude-dev
)

mod_editors() {
	case "$(detect_os)" in
	linux | wsl) _editors_linux ;;
	macos) _editors_macos ;;
	esac
}

_editors_linux() {
	if is_wsl; then
		warn "WSL detected; install VS Code on Windows and use the 'code' command from WSL"
	else
		info "Installing VS Code"
		best_effort snap install code --classic
	fi

	if command -v code >/dev/null 2>&1 && ! is_wsl; then
		_editors_install_exts as_user code
		local dir="$LI_TARGET_HOME/.config/Code/User"
		as_user install -d "$dir"
		install_atomic 0644 "$SETUP_FILES/vscode-settings.json" "$dir/settings.json"
		own_target "$LI_TARGET_HOME/.config/Code"
	fi
	_editors_fonts_linux
	good "Editor setup complete"
}

_editors_macos() {
	need brew "install Homebrew: https://brew.sh"
	info "Installing VS Code (brew cask)"
	best_effort brew install --cask visual-studio-code
	local code="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
	if [[ -x "$code" ]]; then
		_editors_install_exts "$code"
		local dir="$LI_TARGET_HOME/Library/Application Support/Code/User"
		install -d "$dir"
		install_atomic 0644 "$SETUP_FILES/vscode-settings.json" "$dir/settings.json"
	else
		warn "VS Code CLI not found at $code; skipping extensions/settings"
	fi
	good "Editor setup complete"
}

# Install the shared extension set using the given command prefix (e.g.
# "as_user code" on Linux, or the absolute code path on macOS).
_editors_install_exts() {
	info "Installing VS Code extensions"
	local ext
	for ext in "${_LI_VSCODE_EXTS[@]}"; do
		"$@" --install-extension "$ext" --force >/dev/null 2>&1 || warn "failed to install extension: $ext"
	done
}

_editors_fonts_linux() {
	info "Installing development fonts"
	pkg_install fonts-firacode fonts-cascadia-code
	if curl -fsSL https://github.com/JetBrains/JetBrainsMono/releases/download/v2.304/JetBrainsMono-2.304.zip -o /tmp/jetbrains-mono.zip; then
		rm -rf /tmp/jetbrains-mono
		unzip -q /tmp/jetbrains-mono.zip -d /tmp/jetbrains-mono
		install -d /usr/share/fonts/truetype/jetbrains-mono
		cp /tmp/jetbrains-mono/fonts/ttf/*.ttf /usr/share/fonts/truetype/jetbrains-mono/
		fc-cache -f >/dev/null 2>&1 || true
		rm -rf /tmp/jetbrains-mono /tmp/jetbrains-mono.zip
		good "Fonts installed"
	else
		warn "JetBrains Mono download failed"
	fi
}
