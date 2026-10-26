#!/usr/bin/env bash
# setup/modules/server.sh - OpenSSH (hardened), Nginx, auto-updates. Sourced.

mod_server() {
	require_os linux
	info "Installing server packages"
	pkg_install openssh-server nginx certbot python3-certbot-nginx

	_server_ssh
	_server_nginx
	_server_update_cron
	good "Server setup complete"
}

_server_ssh() {
	info "Hardening SSH"
	cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

	as_user install -d -m 700 "$LI_TARGET_HOME/.ssh"
	_server_authorized_key

	# Hardened drop-in. AllowUsers is restricted to the target login.
	cat >/etc/ssh/sshd_config.d/99-hardened.conf <<-EOF
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
		AllowUsers ${LI_TARGET_USER}

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
	EOF

	install -d /run/sshd
	if sshd -t 2>&1; then
		best_effort systemctl restart ssh
		good "SSH hardened and restarted"
	else
		warn "sshd -t reported warnings; applying config and restarting anyway"
		best_effort systemctl restart ssh
	fi
}

# Append the operator's public key to authorized_keys, from config.env only --
# never the shipped sample, so a fresh clone adds no key it does not own.
_server_authorized_key() {
	local key="${LI_SSH_AUTHORIZED_KEY:-}" file="$LI_TARGET_HOME/.ssh/authorized_keys"
	if [[ -z "$key" ]]; then
		warn "LI_SSH_AUTHORIZED_KEY is empty; skipping authorized_keys"
		return 0
	fi
	if [[ "${LI_CONFIG_IS_EXAMPLE:-}" == 1 ]]; then
		warn "using sample config; skipping authorized_keys (set LI_SSH_AUTHORIZED_KEY in config/config.env)"
		return 0
	fi
	# Match on the key body so we never add a duplicate.
	local body
	body="$(awk '{print $2}' <<<"$key")"
	if [[ -f "$file" ]] && grep -qF -- "$body" "$file"; then
		hint "authorized key already present"
	else
		as_user bash -c "printf '%s\n' '$key' >> '$file'"
	fi
	as_user chmod 600 "$file"
}

_server_nginx() {
	info "Configuring Nginx security headers"
	rm -f /etc/nginx/conf.d/security.conf
	cat >/etc/nginx/conf.d/security.conf <<-'EOF'
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
	EOF
	if nginx -t 2>&1; then
		best_effort systemctl restart nginx
		good "Nginx configured and restarted"
	else
		warn "nginx -t failed; keeping previous config"
		rm -f /etc/nginx/conf.d/security.conf
	fi
}

_server_update_cron() {
	info "Scheduling nightly package updates"
	best_effort bash -c '(crontab -l 2>/dev/null || true; echo "0 6 * * * apt update && apt-get -y upgrade && apt-get -y autoremove && apt-get -y autoclean && needrestart -ra") | crontab -'
}
