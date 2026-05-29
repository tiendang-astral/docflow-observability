# README.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Tổng quan

Stack observability dựa trên Docker Compose cho ứng dụng DocFlow/DocAI. Gồm hai stack độc lập:

- **Observability** (`compose/docker-compose.observability.yml`): Prometheus + Grafana + Alertmanager + các exporter
- **ELK** (`compose/docker-compose.elk.yml`): Elasticsearch + Kibana + Filebeat

## Lệnh thường dùng

```bash
# Khởi tạo
cp .env.example .env   # sau đó điền các biến bắt buộc

# Khởi động / tắt
./scripts/up.sh                     # cả hai stack
./scripts/up.sh --observability     # chỉ Prometheus + Grafana + Alertmanager
./scripts/up.sh --elk               # chỉ ELK
./scripts/up.sh --pull              # pull image mới trước khi start
./scripts/down.sh                   # dừng cả hai
./scripts/down.sh --volumes         # dừng và xóa toàn bộ data (có hỏi xác nhận)

# Xem logs
docker compose --env-file .env -f compose/docker-compose.observability.yml logs -f
docker compose --env-file .env -f compose/docker-compose.elk.yml logs -f

# Reload cấu hình Prometheus không cần restart
curl -X POST http://localhost:29111/-/reload
```

## Kiến trúc

### Topology mạng

Stack observability kết nối vào hai network:

- `docflow-observability` (internal): nối Prometheus, Grafana, Alertmanager, node-exporter, postgres-exporter với nhau
- `docflow_network` (external, phải tồn tại trước): cho phép Prometheus và postgres-exporter reach các container của app

**App stack (`docflow_network`) phải chạy trước khi khởi động stack observability.** `up.sh` kiểm tra điều này ở bước preflight.

### Prometheus scrape targets

Khai báo trong `prometheus/prometheus.yml`. Các target (theo tên container trên `docflow_network`):

- `docflow-backend:8000/metrics` — backend API
- `docflow-platform-worker:8001/metrics` — platform worker
- `docprocess-worker:8002/healthz` — doc processing worker
- `node-exporter:9100` — CPU/RAM/disk/network của host
- `postgres-exporter:9187` — thống kê PostgreSQL

### Metrics tùy chỉnh của ứng dụng (dùng trong alert)

Các alert trong `prometheus/prometheus-alerts.yml` yêu cầu app phải expose các metric sau:

- `docai_jobs_failed_total`, `docai_jobs_completed_total` — thông lượng job
- `docai_http_request_duration_seconds` (histogram) — độ trễ HTTP
- `docai_worker_status{worker_type}` — heartbeat worker (0=down, 1=up)
- `docai_queue_depth{stream}` — độ sâu hàng đợi message
- `docai_llm_request_duration_seconds{service, model}` (histogram) — độ trễ LLM

### Cơ chế inject credentials vào Alertmanager

`alertmanager/alertmanager.yml` là file template — `${TELEGRAM_BOT_TOKEN}` và `${TELEGRAM_CHAT_ID}` là placeholder chữ, không phải biến shell. `alertmanager/docker-entrypoint.sh` dùng `sed` lúc container khởi động để thay thế chúng từ biến môi trường vào `/tmp/alertmanager.yml`.

Routing alert: `critical` → Telegram nhắc lại mỗi 1h, `warning` → mỗi 6h. Alert critical sẽ ức chế alert warning cùng tên.

### Pipeline log ELK

Filebeat đọc toàn bộ log Docker container từ `/var/lib/docker/containers/*/*.log`, bổ sung Docker metadata, thử parse JSON trong trường `message` vào namespace `app.*`, rồi đẩy vào index `docflow-logs-YYYY.MM.DD`. Multiline assembly xử lý Python traceback.

Lần đầu khởi động, `kibana-init` (container Alpine chạy một lần) tự tạo data view `docflow-logs-*` trong Kibana.

Elasticsearch yêu cầu `vm.max_map_count=262144` trên host — `up.sh` tự set thông qua một container Alpine privileged.

### Provisioning Grafana

Dashboard trong `grafana/dashboards/*.json` được provision ở chế độ read-only lúc khởi động qua `grafana/provisioning/`. Để cập nhật dashboard, sửa file JSON rồi restart Grafana — không lưu thay đổi qua UI vì sẽ mất sau khi restart.

## Biến môi trường bắt buộc

| Biến | Stack | Ghi chú |
| --- | --- | --- |
| `POSTGRES_PASSWORD` | observability | DSN cho postgres-exporter |
| `POSTGRES_USER` | observability | DSN cho postgres-exporter |
| `POSTGRES_DB` | observability | DSN cho postgres-exporter |
| `TELEGRAM_BOT_TOKEN` | observability | Gửi alert qua Alertmanager |
| `TELEGRAM_CHAT_ID` | observability | Gửi alert qua Alertmanager |
| `GRAFANA_ADMIN_PASSWORD` | observability | Đăng nhập Grafana |
| `KIBANA_ENCRYPTION_KEY` | ELK | Tạo bằng `openssl rand -hex 16` |

Port mặc định: Prometheus `29111`, Grafana `29112`, Alertmanager `29113`, Elasticsearch `29200`, Kibana `29560`.
