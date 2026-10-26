#!/usr/bin/env bash
# setup/modules/kubernetes.sh - kubectl, minikube, helm, k9s (Linux). Sourced.

mod_kubernetes() {
	require_os linux
	local arch
	case "$(detect_arch)" in
	x64) arch=amd64 ;;
	arm64) arch=arm64 ;;
	*) arch=amd64 ;;
	esac

	info "Installing kubectl"
	rm -f /etc/apt/sources.list.d/kubernetes.list \
		/usr/share/keyrings/kubernetes-archive-keyring.gpg \
		/usr/share/keyrings/kubernetes-apt-keyring.gpg
	if curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.33/deb/Release.key | gpg --dearmor -o /usr/share/keyrings/kubernetes-apt-keyring.gpg 2>/dev/null; then
		echo "deb [signed-by=/usr/share/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.33/deb/ /" \
			>/etc/apt/sources.list.d/kubernetes.list
		best_effort apt-get update
		pkg_install kubectl
	else
		warn "failed to add the Kubernetes repository key"
	fi

	info "Installing minikube"
	if curl -fsSLO "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-${arch}"; then
		install -m 0755 "minikube-linux-${arch}" /usr/local/bin/minikube
		rm -f "minikube-linux-${arch}"
	else
		warn "minikube download failed"
	fi

	info "Installing Helm"
	best_effort bash -c 'curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash'

	info "Installing k9s"
	if curl -fsSL "https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_${arch}.tar.gz" -o /tmp/k9s.tar.gz; then
		tar -xzf /tmp/k9s.tar.gz -C /tmp/ k9s && install -m 0755 /tmp/k9s /usr/local/bin/k9s
		rm -f /tmp/k9s.tar.gz /tmp/k9s
	else
		warn "k9s download failed"
	fi
	good "Kubernetes tools installed"
}
