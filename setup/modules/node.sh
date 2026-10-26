#!/usr/bin/env bash
# setup/modules/node.sh - Node.js, global npm tools, Claude Code + Gemini CLI. Sourced.

_LI_NPM_GLOBALS="yarn pnpm typescript ts-node nodemon pm2 eslint prettier"

mod_node() {
	case "$(detect_os)" in
	linux | wsl) _node_linux ;;
	macos) _node_macos ;;
	esac
}

# Linux: Node via nvm for the target user. npm runs inside a login shell that
# sources nvm first, since nvm is not on a non-interactive PATH.
_node_linux() {
	info "Installing Node.js via nvm"
	as_user bash -c 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash' ||
		warn "nvm install may have failed"
	if [[ -d "$LI_TARGET_HOME/.nvm" ]]; then good "nvm installed"; else warn "nvm directory not found"; fi

	_node_run "nvm install --lts && nvm use --lts && nvm alias default node"
	local v
	if v="$(_node_run 'node --version' 2>/dev/null)"; then
		good "Node.js $v installed"
	else
		warn "Node.js install may have failed"
	fi

	info "Installing global npm tools and AI CLIs"
	_node_run "npm install -g $_LI_NPM_GLOBALS"
	_node_run "npm install -g @anthropic-ai/claude-code"
	_node_run "npm install -g @google/gemini-cli"
	_node_aliases
	good "Node tooling installed"
}

# Run a command in a login bash that has sourced the target user's nvm.
_node_run() {
	as_user bash -c "source \"$LI_TARGET_HOME/.nvm/nvm.sh\" && $1"
}

_node_macos() {
	need brew "install Homebrew: https://brew.sh"
	info "Installing Node.js (brew)"
	pkg_install node
	info "Installing global npm tools and AI CLIs"
	# shellcheck disable=SC2086  # intentional word-splitting of the tool list
	as_user npm install -g $_LI_NPM_GLOBALS
	as_user npm install -g @anthropic-ai/claude-code
	as_user npm install -g @google/gemini-cli
	_node_aliases
	good "Node tooling installed"
}

# Convenience aliases in the target's ~/.bashrc. The gemini alias pins a Google
# Cloud project only when the operator's own config.env supplies one -- never
# the sample value, so a fresh clone writes no personal project id.
_node_aliases() {
	local rc="$LI_TARGET_HOME/.bashrc"
	append_once "$rc" 'alias claude-go="claude --dangerously-skip-permissions"'
	append_once "$rc" 'alias claude-gores="claude --dangerously-skip-permissions --resume"'
	if [[ -n "${LI_GCP_PROJECT:-}" && "${LI_CONFIG_IS_EXAMPLE:-}" != 1 ]]; then
		append_once "$rc" "alias gemini-go=\"GOOGLE_CLOUD_PROJECT=${LI_GCP_PROJECT} gemini --yolo\""
	else
		append_once "$rc" 'alias gemini-go="gemini --yolo"'
	fi
	own_target "$rc"
}
