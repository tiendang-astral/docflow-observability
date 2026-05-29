#!/usr/bin/env bash
# =============================================================================
# DocFlow Monitor Stack — Teardown
# =============================================================================
# Usage:
#   ./down.sh                   # dừng cả 2 stack
#   ./down.sh --observability   # chỉ dừng Prometheus + Grafana + Alertmanager
#   ./down.sh --elk             # chỉ dừng ELK
#   ./down.sh --volumes         # dừng tất cả VÀ xóa volumes (xóa data!)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

ENV_FILE=".env"
COMPOSE_OBS="compose/docker-compose.observability.yml"
COMPOSE_ELK="compose/docker-compose.elk.yml"

YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }

RUN_OBS=true
RUN_ELK=true
REMOVE_VOLUMES=false

for arg in "$@"; do
  case "$arg" in
    --observability) RUN_ELK=false ;;
    --elk)           RUN_OBS=false ;;
    --volumes)       REMOVE_VOLUMES=true ;;
  esac
done

if [ "$REMOVE_VOLUMES" = true ]; then
  warn "Flag --volumes: sẽ xóa toàn bộ data (Prometheus, Grafana, Alertmanager, Elasticsearch)."
  read -r -p "Xác nhận xóa volumes? [y/N] " confirm
  [[ "$confirm" =~ ^[yY]$ ]] || { info "Hủy."; exit 0; }
  DOWN_ARGS="down --volumes"
else
  DOWN_ARGS="down"
fi

if [ "$RUN_OBS" = true ]; then
  info "Stopping observability stack..."
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_OBS" $DOWN_ARGS
  success "Observability stack stopped."
fi

if [ "$RUN_ELK" = true ]; then
  info "Stopping ELK stack..."
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_ELK" $DOWN_ARGS
  success "ELK stack stopped."
fi

[ "$REMOVE_VOLUMES" = true ] && info "Volumes removed." || info "Volumes preserved."
