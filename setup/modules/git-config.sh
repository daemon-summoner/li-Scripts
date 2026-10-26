#!/usr/bin/env bash
# setup/modules/git-config.sh - global git config from config.env. Sourced.

mod_git_config() {
	info "Configuring Git for $LI_TARGET_USER"
	# Non-identity defaults are always safe to set.
	as_user git config --global push.default simple
	as_user git config --global init.defaultBranch main
	as_user git config --global core.editor "${LI_GIT_EDITOR:-nvim}"

	# Identity comes from config.env. Never write the shipped sample values onto
	# a machine, so a run off config.env.example sets everything but name/email.
	if [[ "${LI_CONFIG_IS_EXAMPLE:-}" == 1 ]]; then
		warn "using sample config; skipping git identity (set it in config/config.env)"
	else
		as_user git config --global user.name "${LI_GIT_NAME:?set LI_GIT_NAME in config.env}"
		as_user git config --global user.email "${LI_GIT_EMAIL:?set LI_GIT_EMAIL in config.env}"
	fi
	good "Git configured"
}
