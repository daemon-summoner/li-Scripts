#!/usr/bin/env bash
# setup/modules/desktop.sh - MATE desktop (mod_mate) and GUI apps (mod_gui). Sourced.

_LI_MATE="mate-desktop-environment mate-desktop-environment-extras ubuntu-mate-themes"
_LI_DESKTOP_UTILS="pluma atril eom gnome-system-monitor dconf-editor"
_LI_GUI_APPS="qbittorrent sublime-text sublime-merge tilix firefox chromium-browser git-cola gitg meld"

mod_mate() {
	require_os linux
	info "Installing MATE desktop"
	# shellcheck disable=SC2086  # intentional word-splitting of the package lists
	pkg_install $_LI_MATE
	# shellcheck disable=SC2086
	pkg_install $_LI_DESKTOP_UTILS
	# Lighter defaults: no animations, no compositing.
	best_effort as_user dbus-launch dconf write /org/mate/desktop/interface/gtk-enable-animations false
	best_effort as_user dbus-launch dconf write /org/mate/marco/general/compositing-manager false
	good "MATE desktop installed"
}

mod_gui() {
	require_os linux
	info "Adding Sublime Text repository"
	rm -f /etc/apt/trusted.gpg.d/sublimehq-archive.gpg /usr/share/keyrings/sublimehq-archive-keyring.gpg
	wget -qO - https://download.sublimetext.com/sublimehq-pub.gpg | gpg --dearmor -o /usr/share/keyrings/sublimehq-archive-keyring.gpg
	echo "deb [signed-by=/usr/share/keyrings/sublimehq-archive-keyring.gpg] https://download.sublimetext.com/ apt/stable/" \
		>/etc/apt/sources.list.d/sublime-text.list

	info "Installing GUI applications"
	# shellcheck disable=SC2086  # intentional word-splitting of the package list
	pkg_install $_LI_GUI_APPS

	info "Installing JetBrains IDEs (snap)"
	best_effort snap install pycharm-community --classic
	best_effort snap install intellij-idea-community --classic
	best_effort snap install goland --classic
	good "GUI applications installed"
}
