# OTel Collector Memory 負荷テスト環境
# =====================================

.PHONY: help build up down restart logs status clean
.PHONY: load-burst load-sustained load-spike load-rampup load-light load-stop
.PHONY: scenario-1 scenario-2 scenario-3a scenario-3b reset-config show-config
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
	@echo "  scenario-3a     - [3a] groupbyattrs 正常系（ベースライン）"
	@echo "  scenario-3b     - [3b] groupbyattrs 異常系（高カーディナリティ爆発）"
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
	$(RESTART_COLLECTOR)
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

# Collector再起動（WSL + Docker Desktop環境でのマウント問題回避）
RESTART_COLLECTOR := docker compose up -d --force-recreate otel-collector

# ベース
BASE_SCENARIO := sustained
# Trace > Metrics > Logsなので、Traceのみ
# === loadgenパラメータ ===
# 1スパン: 128 bytes × 8属性 = 1KB
# 1トレース: 1KB × (depth+1) = 4KB （root + 3子スパン）
# rate 12,000 spans/sec → 12MB/sec 流入
BASE_PARAMS := -workers 10 -attr-size 128 -attr-count 8 -depth 3 \
	-metrics=false -logs=false

# 共通のシナリオ実行マクロ
# $(1): シナリオ番号, $(2): メッセージ, $(3): loadgenコマンド
define run_scenario
	@echo "========================================"
	@echo "シナリオ $(1): $(2)"
	@echo "========================================"
	@echo "📌 シナリオ用設定を適用中..."
	@cp otel-collector/scenarios/scenario-$(1).yaml otel-collector/otel-collector.yaml
	@$(RESTART_COLLECTOR)
	@echo "✅ 設定ファイル適用完了"
	@echo ""
	@# 負荷テスト実行後、必ず設定を復元する
	@($(3) $(BASE_PARAMS)) ; \
	EXIT_CODE=$$? ; \
	echo "" ; \
	echo "📌 設定をベストプラクティスに復元中..." ; \
	git restore otel-collector/otel-collector.yaml ; \
	$(RESTART_COLLECTOR) ; \
	echo "✅ 設定の復元完了" ; \
	exit $$EXIT_CODE
endef

# 下流停止シナリオ用マクロ（Jaeger自動停止/復旧付き）
# $(1): シナリオ番号, $(2): メッセージ, $(3): loadgenコマンド（BASE_PARAMS除く）
# $(4): Jaeger停止までの待機秒, $(5): 停止中の観察秒
define run_scenario_downstream
	@echo "========================================"
	@echo "シナリオ $(1): $(2)"
	@echo "========================================"
	@cp otel-collector/scenarios/scenario-$(1).yaml otel-collector/otel-collector.yaml
	@$(RESTART_COLLECTOR)
	@echo "✅ 設定適用完了"
	@$(3) $(BASE_PARAMS) & PID=$$!; \
	echo "⏳ $(4)秒後にJaeger停止..."; sleep $(4); \
	echo "🛑 Jaeger停止"; docker compose stop jaeger; \
	echo "⏳ $(5)秒間観察..."; sleep $(5); \
	echo "🔄 Jaeger復旧"; docker compose start jaeger; \
	wait $$PID 2>/dev/null || true; \
	git restore otel-collector/otel-collector.yaml; \
	$(RESTART_COLLECTOR); \
	echo "✅ シナリオ完了"
endef

scenario-1: build
	$(call run_scenario_downstream,1,下流停止,\
		$(LOADGEN) -endpoint $(ENDPOINT) -scenario $(BASE_SCENARIO) \
		-duration 180s -rate 12000,30,60)

scenario-2: build
	$(call run_scenario,2,キャパシティ不足,\
		$(LOADGEN) -endpoint $(ENDPOINT) -scenario $(BASE_SCENARIO) \
		-duration 180s -rate 35000 \
	)

scenario-3a: build
	$(call run_scenario,3,groupbyattrs正常系,\
		$(LOADGEN) -endpoint $(ENDPOINT) -scenario $(BASE_SCENARIO) \
		-duration 300s -rate 8000 \
	)

scenario-3b: build
	$(call run_scenario,3,groupbyattrs高カーディナリティ,\
		$(LOADGEN) -endpoint $(ENDPOINT) -scenario $(BASE_SCENARIO) \
		-duration 300s -rate 8000 -high-cardinality \
	)

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
	@git restore otel-collector/otel-collector.yaml
	@docker compose restart otel-collector
	@echo "✅ Config restored to best-practice (Git HEAD) and Collector restarted"

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
