#!/usr/bin/env bash
# setup/modules/python.sh - Python toolchain: interpreter, uv, whisper CLI. Sourced.

mod_python() {
	case "$(detect_os)" in
	linux | wsl) _python_linux ;;
	macos) _python_macos ;;
	esac
	_python_whisper_cli
}

_python_linux() {
	local ver="${LI_PYTHON_VERSION:-3.13}" codename url
	info "Installing Python ${ver}"
	codename="$(lsb_release -cs)"
	url="https://ppa.launchpadcontent.net/deadsnakes/ppa/ubuntu"

	# add-apt-repository breaks when the default python lacks apt_pkg, so add the
	# deadsnakes PPA by hand. Skip it when deadsnakes has no build for this release.
	if curl -fsSL --max-time 15 -o /dev/null "${url}/dists/${codename}/InRelease"; then
		rm -f /usr/share/keyrings/deadsnakes-ppa-keyring.gpg
		if gpg --keyserver keyserver.ubuntu.com --recv-keys F23C5A6CF475977595C89F51BA6932366A755776 2>/dev/null; then
			gpg --export F23C5A6CF475977595C89F51BA6932366A755776 | gpg --dearmor -o /usr/share/keyrings/deadsnakes-ppa-keyring.gpg
		else
			warn "keyserver import failed; fetching the PPA key over HTTPS"
			curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xBA6932366A755776" | gpg --dearmor -o /usr/share/keyrings/deadsnakes-ppa-keyring.gpg
		fi
		echo "deb [signed-by=/usr/share/keyrings/deadsnakes-ppa-keyring.gpg] ${url} ${codename} main" >/etc/apt/sources.list.d/deadsnakes-ppa.list
		good "deadsnakes PPA added"
	else
		local f
		for f in /etc/apt/sources.list.d/deadsnakes-ppa.list /etc/apt/sources.list.d/deadsnakes-ppa.sources; do
			[[ -f "$f" ]] && mv "$f" "${f}.disabled"
		done
		warn "deadsnakes has no packages for '${codename}'; using the system Python ${ver}"
	fi

	best_effort apt-get update -qq
	pkg_install "python${ver}" "python${ver}-venv" "python${ver}-dev"

	if [[ -x "/usr/bin/python${ver}" ]]; then
		update-alternatives --install /usr/bin/python3 python3 "/usr/bin/python${ver}" 1
		update-alternatives --set python3 "/usr/bin/python${ver}"
	fi

	if ! command -v pip3 >/dev/null 2>&1; then
		info "Bootstrapping pip"
		if curl -fsS https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py; then
			python3 /tmp/get-pip.py --user 2>/dev/null ||
				python3 /tmp/get-pip.py 2>/dev/null ||
				python3 /tmp/get-pip.py --break-system-packages 2>/dev/null ||
				warn "pip bootstrap failed"
			rm -f /tmp/get-pip.py
		fi
	fi

	_python_install_uv_linux
	good "Python ${ver} ready"
}

# uv is installed for the target user via the official installer, then copied to
# /usr/local/bin so every login sees it (mirrors zoxide/starship exposure).
_python_install_uv_linux() {
	info "Installing uv"
	as_user env INSTALLER_NO_MODIFY_PATH=1 bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh' ||
		warn "uv install may have failed"
	local bindir="$LI_TARGET_HOME/.local/bin" b
	for b in uv uvx; do
		[[ -x "$bindir/$b" ]] && install -m 0755 "$bindir/$b" "/usr/local/bin/$b"
	done
	command -v uv >/dev/null 2>&1 && good "uv installed ($(uv --version 2>/dev/null))"
}

_python_macos() {
	local ver="${LI_PYTHON_VERSION:-3.13}"
	need brew "install Homebrew: https://brew.sh"
	info "Installing Python ${ver} and uv (brew)"
	pkg_install "python@${ver}" uv
	good "Python ${ver} ready"
}

# whisper-ctranslate2 as an isolated uv tool, pinned to Python 3.12 for the
# ctranslate2 wheels. CPU works everywhere; GPU needs CUDA 12 + cuDNN 9.
_python_whisper_cli() {
	command -v uv >/dev/null 2>&1 || as_user bash -lc 'command -v uv' >/dev/null 2>&1 || {
		warn "uv not found; skipping whisper-ctranslate2"
		return 0
	}
	info "Installing faster-whisper CLI (whisper-ctranslate2) via uv"
	if as_user uv tool install --python 3.12 whisper-ctranslate2; then
		good "whisper-ctranslate2 installed (run: whisper-ctranslate2 --help)"
	else
		warn "whisper-ctranslate2 install failed (check network / Python build)"
	fi
}
