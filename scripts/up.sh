#!/usr/bin/env bash
# =============================================================================
# DocFlow Monitor Stack — Deploy
# =============================================================================
# Usage:
#   ./up.sh                   # khởi động cả observability lẫn ELK
#   ./up.sh --observability   # chỉ Prometheus + Grafana + Alertmanager
#   ./up.sh --elk             # chỉ Elasticsearch + Kibana + Filebeat
#   ./up.sh --pull            # pull images mới trước khi start
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

ENV_FILE=".env"
COMPOSE_OBS="compose/docker-compose.observability.yml"
COMPOSE_ELK="compose/docker-compose.elk.yml"

# ── Text helpers ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }

# ── Parse flags ───────────────────────────────────────────────────────────────
RUN_OBS=true
RUN_ELK=true
PULL=false

for arg in "$@"; do
  case "$arg" in
    --observability) RUN_ELK=false ;;
    --elk)           RUN_OBS=false ;;
    --pull)          PULL=true ;;
  esac
done

# =============================================================================
# STEP 1 – Validate .env
# =============================================================================
echo -e "\n${BOLD}=== Step 1: Checking ${ENV_FILE} ===${NC}\n"

if [ ! -f "$ENV_FILE" ]; then
  error "File '${ENV_FILE}' not found."
  error "Create it: cp .env.example .env && nano .env"
  exit 1
fi
success "${ENV_FILE} exists"

REQUIRED_VARS=()
if [ "$RUN_OBS" = true ]; then
  REQUIRED_VARS+=("POSTGRES_PASSWORD" "TELEGRAM_BOT_TOKEN" "TELEGRAM_CHAT_ID" "GRAFANA_ADMIN_PASSWORD")
fi
if [ "$RUN_ELK" = true ]; then
  REQUIRED_VARS+=("KIBANA_ENCRYPTION_KEY")
fi

MISSING=()
for var in "${REQUIRED_VARS[@]}"; do
  value=$(grep -E "^${var}=" "$ENV_FILE" | head -n1 | cut -d'=' -f2- | tr -d '[:space:]' || true)
  if [ -z "$value" ]; then
    MISSING+=("$var")
    error "Missing or empty: ${var}"
  else
    success "${var} ✓"
  fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
  echo ""
  error "Aborting — fill in the variables above in '${ENV_FILE}'."
  exit 1
fi

# =============================================================================
# STEP 2 – Check docflow_network + required app containers
# =============================================================================
if [ "$RUN_OBS" = true ]; then
  echo -e "\n${BOLD}=== Step 2: Checking app stack prerequisites ===${NC}\n"

  # 2a. Network must exist
  if ! docker network inspect docflow_network &>/dev/null; then
    error "Network 'docflow_network' not found."
    error "App stack phải chạy trước:"
    error "  cd ../compose && docker compose -f docker-compose.prod.yml up -d"
    exit 1
  fi
  success "docflow_network is available"

  # 2b. postgres must be running (postgres-exporter depends on it)
  POSTGRES_CTR=$(docker network inspect docflow_network \
    --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null \
    | tr ' ' '\n' | grep -E '^postgres$|^docflow-postgres$|^docflow-prod-postgres' | head -n1 || true)

  if [ -z "$POSTGRES_CTR" ]; then
    error "postgres container not found on docflow_network."
    error "postgres-exporter sẽ không kết nối được."
    error "  cd ../compose && docker compose -f docker-compose.prod.yml up -d postgres"
    exit 1
  fi
  success "postgres container found: ${POSTGRES_CTR}"

  # 2c. docflow-backend must be running (prometheus scrapes /metrics)
  BACKEND_CTR=$(docker network inspect docflow_network \
    --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null \
    | tr ' ' '\n' | grep -E '^docflow-backend$|^docflow-prod-docflow-backend' | head -n1 || true)

  if [ -z "$BACKEND_CTR" ]; then
    warn "docflow-backend not found on docflow_network."
    warn "Prometheus sẽ start nhưng scrape target 'docflow-backend' sẽ DOWN."
    warn "Start backend khi sẵn sàng, Prometheus sẽ tự scrape lại."
  else
    success "docflow-backend container found: ${BACKEND_CTR}"
  fi
fi

# =============================================================================
# STEP 3 – Elasticsearch kernel requirement
# =============================================================================
if [ "$RUN_ELK" = true ]; then
  echo -e "\n${BOLD}=== Step 3: Setting vm.max_map_count for Elasticsearch ===${NC}\n"

  CURRENT_MAP=$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo 0)
  if [ "$CURRENT_MAP" -lt 262144 ]; then
    info "Setting vm.max_map_count=262144..."
    docker run --rm --privileged alpine sysctl -w vm.max_map_count=262144
    success "vm.max_map_count set."
  else
    success "vm.max_map_count=${CURRENT_MAP} (OK)"
  fi
fi

# =============================================================================
# STEP 4 – Pull images (optional)
# =============================================================================
if [ "$PULL" = true ]; then
  echo -e "\n${BOLD}=== Step 4: Pulling latest images ===${NC}\n"
  [ "$RUN_OBS" = true ] && docker compose --env-file "$ENV_FILE" -f "$COMPOSE_OBS" pull
  [ "$RUN_ELK" = true ] && docker compose --env-file "$ENV_FILE" -f "$COMPOSE_ELK" pull
  success "Images updated."
fi

# =============================================================================
# STEP 5 – Start stacks
# =============================================================================
echo -e "\n${BOLD}=== Step 5: Starting stacks ===${NC}\n"

if [ "$RUN_ELK" = true ]; then
  info "Starting ELK stack..."
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_ELK" up -d --remove-orphans
  success "ELK stack started."
fi

if [ "$RUN_OBS" = true ]; then
  info "Starting observability stack..."
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_OBS" up -d --remove-orphans
  success "Observability stack started."
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
[ "$RUN_ELK" = true ]  && docker compose --env-file "$ENV_FILE" -f "$COMPOSE_ELK" ps
[ "$RUN_OBS" = true ]  && docker compose --env-file "$ENV_FILE" -f "$COMPOSE_OBS" ps

HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
PROM_PORT=$(grep -E '^PROMETHEUS_PORT=' "$ENV_FILE" | cut -d'=' -f2- | tr -d '[:space:]' || echo "29111")
GRAFANA_PORT=$(grep -E '^GRAFANA_PORT=' "$ENV_FILE" | cut -d'=' -f2- | tr -d '[:space:]' || echo "29112")
ALERTMANAGER_PORT=$(grep -E '^ALERTMANAGER_PORT=' "$ENV_FILE" | cut -d'=' -f2- | tr -d '[:space:]' || echo "29113")
KIBANA_PORT=$(grep -E '^KIBANA_PORT=' "$ENV_FILE" | cut -d'=' -f2- | tr -d '[:space:]' || echo "29560")
ELASTIC_PORT=$(grep -E '^ELASTIC_PORT=' "$ENV_FILE" | cut -d'=' -f2- | tr -d '[:space:]' || echo "29200")

echo ""
info "Access points:"
[ "$RUN_OBS" = true ] && echo "  Prometheus   : http://${HOST_IP}:${PROM_PORT}"
[ "$RUN_OBS" = true ] && echo "  Grafana      : http://${HOST_IP}:${GRAFANA_PORT}"
[ "$RUN_OBS" = true ] && echo "  Alertmanager : http://${HOST_IP}:${ALERTMANAGER_PORT}"
[ "$RUN_ELK" = true ] && echo "  Kibana       : http://${HOST_IP}:${KIBANA_PORT}"
[ "$RUN_ELK" = true ] && echo "  Elasticsearch: http://${HOST_IP}:${ELASTIC_PORT}"
echo ""
info "Useful commands:"
echo "  Stop all    : ./scripts/down.sh"
echo "  Stop obs    : ./scripts/down.sh --observability"
echo "  Stop elk    : ./scripts/down.sh --elk"
echo "  Logs (obs)  : docker compose --env-file .env -f ${COMPOSE_OBS} logs -f"
echo "  Logs (elk)  : docker compose --env-file .env -f ${COMPOSE_ELK} logs -f"
