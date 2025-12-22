# OTel Collector Memory 負荷テスト環境
# =====================================

.PHONY: help build up down restart logs status clean
.PHONY: load-burst load-sustained load-spike load-rampup load-light load-stop
.PHONY: scenario-1 scenario-2 scenario-3 scenario-4 reset-config show-config
.PHONY: tgen-traces tgen-metrics tgen-logs tgen-burst tgen-sustained tgen-all tgen-help

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
	@echo "=== 設定管理 ==="
	@echo "  reset-config    - 設定ファイルをデフォルトに戻す"
	@echo "  show-config     - 現在の設定ファイルの内容を表示"
	@echo ""
	@echo "=== 重要シナリオテスト (scenario.md 参照) ==="
	@echo "  scenario-1      - [1] 下流停止 (1:負荷開始 -> 2:別ターミナルで jaeger-stop)"
	@echo "  scenario-2      - [2] キャパシティ不足（慢性的なデータドロップ）"
	@echo "  scenario-3      - [3] メモリリーク（RSS 右肩上がり）"
	@echo "  scenario-4      - [4] 高カーディナリティ（属性爆発）"
	@echo ""
	@echo "=== 基本負荷テスト (loadgen) ==="
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
	@echo "=== ユーティリティ ==="
	@echo "  check-memory    - 現在のメモリ消費量とRefusedを確認"
	@echo "  metrics         - Collector の内部メトリクス一覧を表示"
	@echo "  jaeger-stop     - Jaeger を停止"
	@echo "  jaeger-start    - Jaeger を起動"
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
# 共通パラメータ
# =====================================

LOADGEN := ./loadgen/loadgen
ENDPOINT := localhost:4317

# =====================================
# 重要シナリオテスト (scenario.md 参照)
# =====================================

# シナリオ1: 下流停止
scenario-1: build
	@echo "========================================"
	@echo "シナリオ1: 下流（バックエンド）の遅延・停止"
	@echo "========================================"
	@echo "📌 設定ファイルを切り替えています..."
	@cp otel-collector/scenarios/scenario-1.yaml otel-collector/otel-collector.yaml
	@docker compose restart otel-collector
	@echo "✅ 設定ファイル適用完了"
	@echo ""
	@echo "📌 手順:"
	@echo "  1. このターミナルで負荷が開始されます"
	@echo "  2. 別ターミナルで実行: docker compose stop jaeger"
	@echo "  3. Grafana で Queue Usage 100% を観察"
	@echo "========================================"
	@sleep 3
	$(LOADGEN) \
		-endpoint $(ENDPOINT) \
		-scenario sustained \
		-duration 180s \
		-rate 20000 \
		-workers 10 \
		-attr-size 64 \
		-attr-count 10 \
		-depth 3

# シナリオ2: キャパシティ不足
scenario-2: build
	@echo "========================================"
	@echo "シナリオ2: 慢性的な入力過多（キャパシティ不足）"
	@echo "========================================"
	@echo "📌 設定ファイルを切り替えています..."
	@cp otel-collector/scenarios/scenario-2.yaml otel-collector/otel-collector.yaml
	@docker compose restart otel-collector
	@echo "✅ 設定ファイル適用完了"
	@echo ""
	@echo "📌 memory_limiter の limit_mib に到達するまで全力送信"
	@echo "========================================"
	@sleep 3
	$(LOADGEN) \
		-endpoint $(ENDPOINT) \
		-scenario burst \
		-duration 180s \
		-workers 50 \
		-attr-size 128 \
		-attr-count 15 \
		-depth 8

# シナリオ3: メモリリーク検出
scenario-3: build
	@echo "========================================"
	@echo "シナリオ3: メモリリーク（またはProcessorのバグ）検出"
	@echo "========================================"
	@echo "📌 設定ファイルを切り替えています..."
	@cp otel-collector/scenarios/scenario-3.yaml otel-collector/otel-collector.yaml
	@docker compose restart otel-collector
	@echo "✅ 設定ファイル適用完了"
	@echo ""
	@echo "📌 10分間の安定負荷でRSSの推移を観察"
	@echo "========================================"
	@sleep 3
	$(LOADGEN) \
		-endpoint $(ENDPOINT) \
		-scenario sustained \
		-duration 600s \
		-rate 3000 \
		-workers 10 \
		-attr-size 64 \
		-attr-count 10 \
		-depth 3

# シナリオ4: 高カーディナリティ
scenario-4: build
	@echo "========================================"
	@echo "シナリオ4: Attributes爆発（High Cardinality）"
	@echo "========================================"
	@echo "📌 設定ファイルを切り替えています..."
	@cp otel-collector/scenarios/scenario-4.yaml otel-collector/otel-collector.yaml
	@docker compose restart otel-collector
	@echo "✅ 設定ファイル適用完了"
	@echo ""
	@echo "📌 各スパンにユニークなUUIDを含む属性を付与"
	@echo "========================================"
	@sleep 3
	$(LOADGEN) \
		-endpoint $(ENDPOINT) \
		-scenario sustained \
		-duration 180s \
		-rate 5000 \
		-workers 10 \
		-attr-size 64 \
		-attr-count 15 \
		-depth 3 \
		-high-cardinality

# =====================================
# 基本負荷テスト (loadgen)
# =====================================

load-burst: build
	$(LOADGEN) -endpoint $(ENDPOINT) -scenario burst -duration 120s -workers 50 -attr-size 128 -attr-count 15 -depth 8

load-sustained: build
	$(LOADGEN) -endpoint $(ENDPOINT) -scenario sustained -duration 180s -rate 10000 -workers 20 -attr-size 64 -attr-count 10 -depth 5

load-spike: build
	$(LOADGEN) -endpoint $(ENDPOINT) -scenario spike -duration 180s -rate 15000 -workers 20 -attr-size 64 -attr-count 10 -depth 5

load-rampup: build
	$(LOADGEN) -endpoint $(ENDPOINT) -scenario rampup -duration 120s -rate 20000 -workers 20 -attr-size 64 -attr-count 10 -depth 5

load-light: build
	$(LOADGEN) -endpoint $(ENDPOINT) -scenario sustained -duration 30s -rate 1000 -workers 5 -attr-size 32 -attr-count 5 -depth 3

load-logs: build
	$(LOADGEN) -endpoint $(ENDPOINT) -scenario sustained -duration 60s -rate 2000 -workers 5 -attr-size 128 -attr-count 10 -depth 3 -logs

load-stop:
	-pkill -f "loadgen" 2>/dev/null || true
	@echo "✅ loadgen stopped"

# =====================================
# 負荷テスト (telemetrygen)
# =====================================

TELEMETRYGEN_IMAGE := ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest
TGEN := docker run --rm --network host $(TELEMETRYGEN_IMAGE)

tgen-traces:
	$(TGEN) traces --otlp-endpoint $(ENDPOINT) --otlp-insecure --rate 100 --duration 60s --workers 1

tgen-metrics:
	$(TGEN) metrics --otlp-endpoint $(ENDPOINT) --otlp-insecure --rate 100 --duration 60s --workers 1

tgen-logs:
	$(TGEN) logs --otlp-endpoint $(ENDPOINT) --otlp-insecure --rate 100 --duration 60s --workers 1

tgen-burst:
	$(TGEN) traces --otlp-endpoint $(ENDPOINT) --otlp-insecure --rate 10000 --duration 120s --workers 10 --span-duration 100ms --child-spans 5

tgen-sustained:
	$(TGEN) traces --otlp-endpoint $(ENDPOINT) --otlp-insecure --rate 5000 --duration 180s --workers 5 --child-spans 3

tgen-all:
	@$(TGEN) traces --otlp-endpoint $(ENDPOINT) --otlp-insecure --rate 1000 --duration 60s --workers 2 &
	@$(TGEN) metrics --otlp-endpoint $(ENDPOINT) --otlp-insecure --rate 500 --duration 60s --workers 2 &
	@$(TGEN) logs --otlp-endpoint $(ENDPOINT) --otlp-insecure --rate 500 --duration 60s --workers 2 &
	@echo "✅ telemetrygen started in background"

tgen-help:
	$(TGEN) traces --help

# =====================================
# 設定管理
# =====================================

reset-config:
	@cp otel-collector/otel-collector.yaml.backup otel-collector/otel-collector.yaml
	@docker compose restart otel-collector
	@echo "✅ Config reset to default"

show-config:
	@cat otel-collector/otel-collector.yaml

# =====================================
# 開発用
# =====================================

check-memory:
	@echo "=== Heap Memory ==="
	@curl -s "http://localhost:9090/api/v1/query?query=otelcol_process_runtime_heap_alloc_bytes" | jq -r '.data.result[0].value[1] | tonumber / 1024 / 1024 | round | tostring + " MiB"'
	@echo "=== Receiver Refused ==="
	@curl -s "http://localhost:9090/api/v1/query?query=sum(otelcol_receiver_refused_spans_total)" | jq -r '.data.result[0].value[1]'

metrics:
	curl -s http://localhost:8888/metrics | grep -E "^otelcol_" | cut -d'{' -f1 | sort -u

jaeger-stop:
	docker compose stop jaeger

jaeger-start:
	docker compose start jaeger
