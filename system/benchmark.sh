#!/usr/bin/env bash
# benchmark.sh - quick CPU, memory and disk I/O benchmark for a Linux host.
# Prints system info, runs five dd write passes, a sysbench CPU test at 1 and
# 32 threads, and an internet speed test.
#   benchmark.sh            run the full benchmark
#   benchmark.sh -h         this help
# --- end usage ---
set -Eeuo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
LIB_DIR="$(cd "$HERE/../lib" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/platform.sh
source "$LIB_DIR/platform.sh"

[[ "${1:-}" == -h || "${1:-}" == --help ]] && usage 0
require_os linux

step "System info"
info "CPU model   : $(awk -F: '/model name/ {name=$2} END {print name}' /proc/cpuinfo)"
info "Cores       : $(awk -F: '/model name/ {c++} END {print c}' /proc/cpuinfo)"
info "CPU MHz     : $(awk -F: '/cpu MHz/ {f=$2} END {print f}' /proc/cpuinfo)"
info "RAM (MB)    : $(free -m | awk 'NR==2 {print $2}')"
info "Swap (MB)   : $(free -m | awk 'NR==4 {print $2}')"
info "Uptime      :$(uptime | awk '{$1=$2="";print}')"

step "Disk I/O (5 passes)"
for _ in 1 2 3 4 5; do
	io=$( (dd if=/dev/zero of="test_$$" bs=64k count=16k conv=fdatasync && rm -f "test_$$") 2>&1 | awk -F, '{io=$NF} END {print io}')
	info "I/O speed : $io"
done

step "Installing sysbench"
pkg_install sysbench

step "Sysbench CPU"
info "1 thread:"
best_effort sysbench --test=cpu --cpu-max-prime=20000 --num-threads=1 run
info "32 threads:"
best_effort sysbench --test=cpu --cpu-max-prime=20000 --num-threads=32 run

step "Internet speed test"
if ! command -v speedtest-cli >/dev/null 2>&1; then
	pkg_install speedtest-cli
fi
best_effort speedtest-cli
good "Benchmark complete."
