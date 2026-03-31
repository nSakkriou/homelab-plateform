#!/usr/bin/env bash
# configure_cluster.sh — Déploiement de la plateforme homelab
#
# Usage :
#   ./configure_cluster.sh
#   ./configure_cluster.sh --tags traefik
#   ./configure_cluster.sh --tags argocd,cert_manager

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

INVENTORY="${INVENTORY:-inventories/homelab.ini}"
PLAYBOOK="${PLAYBOOK:-setup_platform.yml}"
EXTRA_ARGS="${@:-}"

echo "==> Inventory : $INVENTORY"
echo "==> Playbook  : $PLAYBOOK"
echo ""

ansible-playbook -i "$INVENTORY" "$PLAYBOOK" $EXTRA_ARGS
