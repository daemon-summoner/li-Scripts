#!/usr/bin/env bash
# setup/modules/lunarvim.sh - LunarVim (Neovim 0.10+ IDE layer). Sourced.
# The shared ~/.bashrc already aliases vim -> lvim when lvim is present.

mod_lunarvim() {
	info "Installing LunarVim prerequisites (rustup, ripgrep)"
	as_user bash -c "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y" ||
		warn "rustup install may have failed"
	pkg_install ripgrep

	info "Installing LunarVim"
	if as_user bash -c "bash <(curl -s https://raw.githubusercontent.com/lunarvim/lunarvim/master/utils/installer/install.sh) --no-install-dependencies"; then
		good "LunarVim installed (run lvim, then :LvimSyncCorePlugins to sync plugins)"
	else
		warn "LunarVim install failed"
	fi
}
