#!/usr/bin/env bash
# setup/modules/shell.sh - install the shared ~/.bashrc. Sourced by orchestrators.

# Install the managed bashrc for the target user. On macOS also source it from
# ~/.zshrc (the default login shell there), matching the old macos_setup.sh.
mod_shell() {
	info "Installing managed ~/.bashrc for $LI_TARGET_USER"
	install_atomic 0644 "$SETUP_FILES/bashrc" "$LI_TARGET_HOME/.bashrc"
	own_target "$LI_TARGET_HOME/.bashrc"

	if [[ "$(detect_os)" == macos ]]; then
		# zsh is the macOS default; have it source the shared bashrc.
		local zshrc="$LI_TARGET_HOME/.zshrc"
		[[ -f "$zshrc" ]] || as_user touch "$zshrc"
		as_user bash -c "grep -qxF 'source ~/.bashrc' '$zshrc' || printf '%s\n' 'source ~/.bashrc' >> '$zshrc'"
	fi
	good "Shell environment configured"
}
