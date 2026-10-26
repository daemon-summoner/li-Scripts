#!/usr/bin/env bash
# kasm-uninstall.sh - stop and completely remove a Kasm Workspaces install.
# Removes containers, images, network, volume, /opt/kasm and the service users.
# Version-pinned image/volume tags are overridable with KASM_VERSION.
#   kasm-uninstall.sh [--yes]
# --- end usage ---
set -Eeuo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/../lib/common.sh"

[[ "${1:-}" == -h || "${1:-}" == --help ]] && usage 0
need docker
ver="${KASM_VERSION:-1.14.0}"

if [[ "${1:-}" != --yes ]]; then
	confirm "Remove Kasm, its containers, images, volume and the kasm users?" n || die "aborted"
fi

best_effort sudo /opt/kasm/current/bin/stop

mapfile -t kasm_containers < <(sudo docker container ls -qa --filter="label=kasm.kasmid")
((${#kasm_containers[@]})) && best_effort sudo docker rm -f "${kasm_containers[@]}"

KASM_UID="$(id kasm -u 2>/dev/null || echo)"
KASM_GID="$(id kasm -g 2>/dev/null || echo)"
export KASM_UID KASM_GID
best_effort sudo -E docker compose -f /opt/kasm/current/docker/docker-compose.yaml rm

best_effort sudo docker network rm kasm_default_network
best_effort sudo docker volume rm "kasm_db_${ver}"

for img in redis:5-alpine postgres:9.5-alpine kasmweb/nginx:latest \
	"kasmweb/share:${ver}" "kasmweb/agent:${ver}" "kasmweb/manager:${ver}" "kasmweb/api:${ver}"; do
	best_effort sudo docker rmi "$img"
done

mapfile -t kasm_images < <(sudo docker images --filter "label=com.kasmweb.image=true" -q)
((${#kasm_images[@]})) && best_effort sudo docker rmi "${kasm_images[@]}"

best_effort sudo rm -rf /opt/kasm/
best_effort sudo deluser kasm_db
best_effort sudo deluser kasm
good "Kasm removed."
