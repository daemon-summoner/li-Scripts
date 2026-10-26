#!/usr/bin/env bash
# setup/modules/guests.sh - VM (mod_vm_guest) and Hyper-V (mod_hyperv_guest) additions. Sourced.

mod_vm_guest() {
	require_os linux
	info "Installing VMware/VirtualBox guest additions"
	pkg_install open-vm-tools open-vm-tools-desktop
	good "VM guest additions installed"
}

mod_hyperv_guest() {
	require_os linux
	info "Installing Hyper-V guest additions"
	local module
	for module in hv_utils hv_vmbus hv_storvsc hv_blkvsc hv_netvsc; do
		append_once /etc/initramfs-tools/modules "$module"
	done
	pkg_install linux-virtual linux-cloud-tools-virtual linux-tools-virtual
	update-initramfs -u
	good "Hyper-V guest additions installed"
}
