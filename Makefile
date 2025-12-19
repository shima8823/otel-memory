# OTel Collector Memory 負荷テスト環境
# =====================================

.PHONY: help build up down restart logs load-burst load-sustained load-spike load-rampup load-stop clean

# デフォルトターゲット
help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "=== 環境操作 ==="
	@echo "  up              - 全サービス起動 (Collector, Prometheus, Jaeger, Grafana)"
	@echo "  down            - 全サービス停止"
	@echo "  restart         - 全サービス再起動"
	@echo "  restart-collector - Collector のみ再起動（設定変更後に使用）"
	@echo "  logs            - Collector のログを表示"
	@echo "  logs-f          - Collector のログをフォロー"
	@echo ""
	@echo "=== ビルド ==="
	@echo "  build           - loadgen をビルド"
	@echo "  clean           - ビルド成果物を削除"
	@echo ""
	@echo "=== 負荷テスト ==="
	@echo "  load-burst      - burst シナリオ (最大速度で送信)"
	@echo "  load-sustained  - sustained シナリオ (一定レートで継続)"
	@echo "  load-spike      - spike シナリオ (通常↔スパイクを交互)"
	@echo "  load-rampup     - rampup シナリオ (徐々に負荷増加)"
	@echo "  load-light      - 軽い負荷 (動作確認用)"
	@echo "  load-logs       - ログ送信テスト"
	@echo "  load-stop       - 実行中の loadgen を停止"
	@echo ""
	@echo "=== 負荷テスト (telemetrygen) ==="
	@echo "  tgen-traces     - traces を生成"
	@echo "  tgen-metrics    - metrics を生成"
	@echo "  tgen-logs       - logs を生成"
	@echo "  tgen-burst      - 高負荷 traces (memory_limiter 発火用)"
	@echo "  tgen-all        - traces + metrics + logs を同時生成"
	@echo ""
	@echo "=== URL ==="
	@echo "  Grafana:    http://localhost:3000"
	@echo "  Prometheus: http://localhost:9090"
	@echo "  Jaeger:     http://localhost:16686"

# =====================================
# 環境操作
# =====================================

up:
	docker compose up -d
	@echo ""
	@echo "✅ Services started"
	@echo "   Grafana:    http://localhost:3000"
	@echo "   Prometheus: http://localhost:9090"
	@echo "   Jaeger:     http://localhost:16686"

down:
	docker compose down

restart:
	docker compose restart

restart-collector:
	docker compose restart otel-collector
	@echo "✅ Collector restarted"

logs:
	docker compose logs otel-collector --tail=100

logs-f:
	docker compose logs -f otel-collector

status:
	docker compose ps

# =====================================
# ビルド
# =====================================

build:
	cd loadgen && go build -o loadgen .
	@echo "✅ loadgen built: ./loadgen/loadgen"

clean:
	rm -f loadgen/loadgen
	@echo "✅ Cleaned"

# =====================================
# 負荷テスト
# =====================================

# 共通パラメータ
LOADGEN := ./loadgen/loadgen
ENDPOINT := localhost:4317

# burst: 最大速度で送信（memory_limiter を確実に発火させる）
load-burst: build
	$(LOADGEN) \
		-endpoint $(ENDPOINT) \
		-scenario burst \
		-duration 120s \
		-workers 50 \
		-attr-size 128 \
		-attr-count 15 \
		-depth 8

# sustained: 一定レートで継続（定常状態を観察）
load-sustained: build
	$(LOADGEN) \
		-endpoint $(ENDPOINT) \
		-scenario sustained \
		-duration 180s \
		-rate 10000 \
		-workers 20 \
		-attr-size 64 \
		-attr-count 10 \
		-depth 5

# spike: 通常↔スパイクを交互（memory_limiter の発火・回復を観察）
load-spike: build
	$(LOADGEN) \
		-endpoint $(ENDPOINT) \
		-scenario spike \
		-duration 180s \
		-rate 15000 \
		-workers 20 \
		-attr-size 64 \
		-attr-count 10 \
		-depth 5

# rampup: 徐々に負荷増加（限界点を探る）
load-rampup: build
	$(LOADGEN) \
		-endpoint $(ENDPOINT) \
		-scenario rampup \
		-duration 120s \
		-rate 20000 \
		-workers 20 \
		-attr-size 64 \
		-attr-count 10 \
		-depth 5

# light: 軽い負荷（動作確認用）
load-light: build
	$(LOADGEN) \
		-endpoint $(ENDPOINT) \
		-scenario sustained \
		-duration 30s \
		-rate 1000 \
		-workers 5 \
		-attr-size 32 \
		-attr-count 5 \
		-depth 3

# logs: ログ送信テスト
load-logs: build
	$(LOADGEN) \
		-endpoint $(ENDPOINT) \
		-scenario sustained \
		-duration 60s \
		-rate 2000 \
		-workers 5 \
		-attr-size 128 \
		-attr-count 10 \
		-depth 3 \
		-logs

# 負荷テスト停止
load-stop:
	-pkill -f "loadgen" 2>/dev/null || true
	@echo "✅ loadgen stopped"

# =====================================
# 負荷テスト (telemetrygen)
# =====================================
# 公式ツール: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/cmd/telemetrygen

TELEMETRYGEN_IMAGE := ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest
TGEN := docker run --rm --network host $(TELEMETRYGEN_IMAGE)

# traces: 基本的なトレース生成
tgen-traces:
	$(TGEN) traces \
		--otlp-endpoint $(ENDPOINT) \
		--otlp-insecure \
		--rate 100 \
		--duration 60s \
		--workers 1

# metrics: 基本的なメトリクス生成
tgen-metrics:
	$(TGEN) metrics \
		--otlp-endpoint $(ENDPOINT) \
		--otlp-insecure \
		--rate 100 \
		--duration 60s \
		--workers 1

# logs: 基本的なログ生成
tgen-logs:
	$(TGEN) logs \
		--otlp-endpoint $(ENDPOINT) \
		--otlp-insecure \
		--rate 100 \
		--duration 60s \
		--workers 1

# burst: 高負荷トレース生成（memory_limiter 発火用）
tgen-burst:
	$(TGEN) traces \
		--otlp-endpoint $(ENDPOINT) \
		--otlp-insecure \
		--rate 10000 \
		--duration 120s \
		--workers 10 \
		--span-duration 100ms \
		--child-spans 5 \
		--otlp-attributes 'load_test="burst"'

# sustained: 一定レートでのトレース生成
tgen-sustained:
	$(TGEN) traces \
		--otlp-endpoint $(ENDPOINT) \
		--otlp-insecure \
		--rate 5000 \
		--duration 180s \
		--workers 5 \
		--child-spans 3 \
		--otlp-attributes 'load_test="sustained"'

# all: traces + metrics + logs を同時に生成（バックグラウンド実行）
tgen-all:
	@echo "Starting telemetrygen (traces + metrics + logs)..."
	@$(TGEN) traces \
		--otlp-endpoint $(ENDPOINT) \
		--otlp-insecure \
		--rate 1000 \
		--duration 60s \
		--workers 2 &
	@$(TGEN) metrics \
		--otlp-endpoint $(ENDPOINT) \
		--otlp-insecure \
		--rate 500 \
		--duration 60s \
		--workers 2 &
	@$(TGEN) logs \
		--otlp-endpoint $(ENDPOINT) \
		--otlp-insecure \
		--rate 500 \
		--duration 60s \
		--workers 2 &
	@echo "✅ telemetrygen started in background"

# telemetrygen のヘルプ表示
tgen-help:
	$(TGEN) traces --help

# =====================================
# 開発用
# =====================================

# メトリクス確認（Heap メモリ）
check-memory:
	@echo "=== Heap Memory ==="
	@curl -s "http://localhost:9090/api/v1/query?query=otelcol_process_runtime_heap_alloc_bytes" | \
		jq -r '.data.result[0].value[1] | tonumber / 1024 / 1024 | round | tostring + " MiB"'
	@echo ""
	@echo "=== Refused Spans (memory_limiter) ==="
	@curl -s "http://localhost:9090/api/v1/query?query=otelcol_processor_refused_spans_total" | \
		jq -r '.data.result[] | "\(.metric.processor): \(.value[1])"' 2>/dev/null || echo "None"

# Collector の内部メトリクス一覧
metrics:
	curl -s http://localhost:8888/metrics | grep -E "^otelcol_" | cut -d'{' -f1 | sort -u

# Jaeger操作（シナリオ用）
jaeger-stop:
	docker compose stop jaeger
	@echo "✅ Jaeger stopped"

jaeger-start:
	docker compose start jaeger
	@echo "✅ Jaeger started"

jaeger-pause:
	docker compose pause jaeger
	@echo "✅ Jaeger paused"

jaeger-unpause:
	docker compose unpause jaeger
	@echo "✅ Jaeger unpaused"
