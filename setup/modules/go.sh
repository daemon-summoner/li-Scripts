#!/usr/bin/env bash
# setup/modules/go.sh - Go toolchain plus gopls/dlv/golangci-lint. Sourced.

mod_go() {
	case "$(detect_os)" in
	linux | wsl) _go_linux ;;
	macos) _go_macos ;;
	esac
	_go_tools
}

_go_linux() {
	local ver="${LI_GO_VERSION:-1.25.4}" arch tarball
	case "$(detect_arch)" in
	x64) arch=amd64 ;;
	arm64) arch=arm64 ;;
	*) arch=amd64 ;;
	esac
	tarball="go${ver}.linux-${arch}.tar.gz"
	info "Installing Go ${ver} (${arch})"
	if curl -fsSL "https://go.dev/dl/${tarball}" -o /tmp/go.tar.gz; then
		rm -rf /usr/local/go
		tar -C /usr/local -xzf /tmp/go.tar.gz
		rm -f /tmp/go.tar.gz
		if /usr/local/go/bin/go version >/dev/null 2>&1; then
			good "Go ${ver} installed"
		else
			warn "Go install verification failed"
		fi
	else
		warn "failed to download Go ${ver}"
	fi
}

_go_macos() {
	need brew "install Homebrew: https://brew.sh"
	info "Installing Go (brew)"
	pkg_install go
	good "Go installed"
}

# Install the Go dev tools as the target user. Needs go on PATH; as_user already
# puts /usr/local/go/bin there.
_go_tools() {
	command -v go >/dev/null 2>&1 || [[ -x /usr/local/go/bin/go ]] || {
		warn "go not found; skipping Go tools"
		return 0
	}
	info "Installing Go tools (gopls, dlv, golangci-lint)"
	local pkg
	for pkg in \
		golang.org/x/tools/gopls@latest \
		github.com/go-delve/delve/cmd/dlv@latest \
		github.com/golangci/golangci-lint/cmd/golangci-lint@latest; do
		as_user go install "$pkg" || warn "failed to install ${pkg%@*}"
	done
	good "Go tools installed"
}
