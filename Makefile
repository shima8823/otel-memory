# OTel Collector Memory 負荷テスト環境
# =====================================

.PHONY: help build up down restart logs status clean
.PHONY: load-burst load-sustained load-spike load-rampup load-light load-stop
.PHONY: scenario-1 scenario-2 scenario-3a scenario-3b scenario-4 reset-config show-config
.PHONY: tgen-traces tgen-metrics tgen-logs tgen-burst tgen-sustained tgen-all tgen-help
.PHONY: export-metrics
.PHONY: pprof-heap pprof-cpu pprof-goroutine pprof-allocs
.PHONY: pprof-peak-diff
.PHONY: pprof-scenario-full pprof-scenario1-full
.PHONY: pprof-capture-bg pprof-capture-stop pprof-capture-status
.PHONY: pprof-wait
.PHONY: pprof-diff-stop

# Allow positional DIR for pprof-peak-diff (e.g., `make pprof-peak-diff notes/...`)
ifneq (,$(filter pprof-peak-diff,$(MAKECMDGOALS)))
DIR ?= $(word 2,$(MAKECMDGOALS))
ifneq ($(DIR),)
$(DIR):
	@:
endif
endif
.PHONY: pprof-wait
.PHONY: set-project-id ssh-port ssh-grafana

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
	@echo "  scenario-4      - [4] batchバースト処理（スパイク負荷の耐性）"
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
	@echo "  export-metrics  - Grafanaダッシュボードのメトリクスをエクスポート"
	@echo "  jaeger-stop     - Jaeger を停止"
	@echo "  jaeger-start    - Jaeger を起動"
	@echo ""
	@echo "=== pprof (プロファイリング) ==="
	@echo "  pprof-heap      - ヒーププロファイルを取得してブラウザで開く"
	@echo "  pprof-cpu       - CPUプロファイルを取得（30秒）してブラウザで開く"
	@echo "  pprof-goroutine - goroutineプロファイルを取得してブラウザで開く"
	@echo "  pprof-allocs    - allocsプロファイルを取得してブラウザで開く"
	@echo "  pprof-diff-auto - ベースライン（最小）とピーク（最大）を自動検出して比較"
	@echo ""
	@echo "=== URL ==="
	@echo "  Grafana:    http://localhost:3000"
	@echo "  Prometheus: http://localhost:9090"
	@echo "  Jaeger:     http://localhost:16686"
	@echo "  pprof:      http://localhost:1777/debug/pprof/"

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
	@echo "   pprof:      http://localhost:1777/debug/pprof/"

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

scenario-4: build
	$(call run_scenario,4,batchバースト処理,\
		$(LOADGEN) -endpoint $(ENDPOINT) -scenario spike \
		-duration 180s -rate 15000 \
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

# =====================================
# メトリクスエクスポート
# =====================================

# GrafanaダッシュボードのメトリクスをLLM/人間向けにエクスポート
# 使用例:
#   make export-metrics                    # デフォルト: 直近15分、60秒間隔
#   make export-metrics DURATION=60        # 直近60分
#   make export-metrics STEP=30            # 30秒間隔
#   make export-metrics OUTPUT=my_export   # 出力先を変更
DURATION ?= 15
STEP ?= 60
OUTPUT ?= metrics_export

export-metrics:
	@echo "=== Grafana メトリクスエクスポート ==="
	python3 scripts/export_grafana_metrics.py --duration $(DURATION) --step $(STEP) --output $(OUTPUT)
	@echo ""
	@echo "✅ エクスポート完了: $(OUTPUT)/"

clean-metrics:
	rm -rf metrics_export
	@echo "✅ メトリクスエクスポートディレクトリ削除完了"

# =====================================
# Profiling (pprof)
# =====================================

# ヒープメモリ（現在使用中）のプロファイルを取得し、ブラウザで可視化
# 実行後、自動的にブラウザが開きます (http://localhost:8080)
# 終了するには Ctrl+C
pprof-heap:
	@echo "🔍 Fetching Heap Profile..."
	go tool pprof -http=:8080 http://localhost:1777/debug/pprof/heap

# メモリ割り当て累積（GC圧力の原因特定）
pprof-allocs:
	@echo "🔍 Fetching Allocs Profile..."
	go tool pprof -http=:8080 http://localhost:1777/debug/pprof/allocs

# CPU使用率（30秒間計測）
pprof-cpu:
	@echo "🔍 Profiling CPU for 30s..."
	go tool pprof -http=:8080 http://localhost:1777/debug/pprof/profile?seconds=30

# --- 分析・調査用 ---

# 5秒おきにプロファイルを自動キャプチャ
# 使用例: make pprof-capture
pprof-capture:
	@bash scripts/capture_pprof.sh 5

# 2つのプロファイルを比較してブラウザで開く (diff_base)
# 使用例: make pprof-diff BASE=path/to/old.pprof NEW=path/to/new.pprof
pprof-diff:
	@if [ -z "$(BASE)" ] || [ -z "$(NEW)" ]; then \
		echo "❌ Usage: make pprof-diff BASE=path/to/old.pprof NEW=path/to/new.pprof"; \
		exit 1; \
	fi
	go tool pprof -http=:8081 --diff_base $(BASE) $(NEW)


# キャプチャした全プロファイルのメモリ使用量を一覧表示
# 使用例: make pprof-list DIR=notes/01-23/captures/175921
pprof-list:
	@if [ -z "$(DIR)" ]; then echo "❌ Usage: make pprof-list DIR=path/to/captures/XXXXXX"; exit 1; fi
	@for f in $(DIR)/*.pprof; do \
		[ -s "$$f" ] || continue; \
		printf "%1s " "$$(basename $$f):"; \
		python3 scripts/pprof_total_mb.py "$$f"; \
	done

# 最小メモリ（ベースライン）と最大メモリ（ピーク）を自動検出して比較
# 使用例: make pprof-diff-auto DIR=notes/01-23/captures/175921
pprof-diff-auto:
	@if [ -z "$(DIR)" ]; then echo "❌ Usage: make pprof-diff-auto DIR=path/to/captures/XXXXXX"; exit 1; fi
	@bash scripts/pprof_diff_auto.sh "$(DIR)"

# ピーク（最大メモリ）とその直前のプロファイルを比較して UI を開く
# 使用例: make pprof-peak-diff DIR=notes/01-23/captures/175921
pprof-peak-diff:
	@if [ -z "$(DIR)" ]; then echo "❌ Usage: make pprof-peak-diff DIR=path/to/captures/XXXXXX"; exit 1; fi
	@bash scripts/pprof_peak_diff.sh "$(DIR)"

# pprof diff のローカルUI(8081)を停止
pprof-diff-stop:
	@PID=$$(lsof -ti tcp:8081 2>/dev/null); \
	if [ -z "$$PID" ]; then \
		echo "ℹ️  No process is listening on :8081"; \
		exit 0; \
	fi; \
	kill $$PID 2>/dev/null || true; \
	for i in 1 2 3; do \
		if ! kill -0 $$PID 2>/dev/null; then \
			echo "✅ Stopped :8081 (pid=$$PID)"; \
			exit 0; \
		fi; \
		sleep 1; \
	done; \
	kill -9 $$PID 2>/dev/null || true; \
	if ! kill -0 $$PID 2>/dev/null; then \
		echo "✅ Stopped :8081 (pid=$$PID)"; \
		exit 0; \
	fi; \
	echo "❌ Failed to stop :8081 (pid=$$PID)"; \
	exit 1

# Terraform作成 → シナリオ実行 → pprof取得 → ピークdiff起動
# 使用例: make pprof-scenario-full
#       : make pprof-scenario-full SCENARIO=scenario-2
SCENARIO ?= scenario-1
SYNC ?= 1
RESTART ?= 1
pprof-scenario-full:
	@OUT_FILE=".pprof_last_dir"; \
	rm -f "$$OUT_FILE"; \
	if [ -z "$(PROJECT_ID)" ]; then \
		echo "❌ PROJECT_ID is not set. Run: export PROJECT_ID=\$$(gcloud config get-value project)"; \
		exit 1; \
	fi; \
	echo "=== Terraform apply ==="; \
	PROJECT_ID="$(PROJECT_ID)" make -C terraform tf-apply; \
	if [ "$(SYNC)" = "1" ]; then \
		echo "=== Sync project to VM ==="; \
		PROJECT_ID="$(PROJECT_ID)" make -C terraform sync; \
	fi; \
	if [ "$(RESTART)" = "1" ]; then \
		echo "=== Restart services on VM ==="; \
		PROJECT_ID="$(PROJECT_ID)" make -C terraform restart; \
	fi; \
	echo "=== Start port-forward (background) ==="; \
	PROJECT_ID="$(PROJECT_ID)" make -C terraform forward-bg; \
	echo "=== Start pprof capture (background) ==="; \
	OUTPUT_FILE="$$OUT_FILE" PPROF_WAIT=0 make pprof-capture-bg || { \
		echo "❌ pprof capture failed to start"; \
		PROJECT_ID="$(PROJECT_ID)" make -C terraform forward-stop; \
		exit 1; \
	}; \
	echo "=== Run $(SCENARIO) ==="; \
	PROJECT_ID="$(PROJECT_ID)" make -C terraform "$(SCENARIO)" || { \
		echo "❌ Scenario failed"; \
		make pprof-capture-stop; \
		PROJECT_ID="$(PROJECT_ID)" make -C terraform forward-stop; \
		exit 1; \
	}; \
	echo "=== Stop background processes ==="; \
	make pprof-capture-stop; \
	PROJECT_ID="$(PROJECT_ID)" make -C terraform forward-stop; \
	if [ ! -f "$$OUT_FILE" ]; then \
		echo "❌ Failed to capture output dir. Check logs above."; \
		exit 1; \
	fi; \
	DIR=$$(cat "$$OUT_FILE"); \
	if [ -z "$$DIR" ]; then \
		echo "❌ Output dir is empty."; \
		exit 1; \
	fi; \
	echo "=== Open diff (peak vs previous) ==="; \
	make pprof-peak-diff DIR="$$DIR"

# 互換用（既存の呼び出しを維持）
pprof-scenario1-full: pprof-scenario-full

# pprof capture: background start/stop
CAPTURE_INTERVAL ?= 5
CAPTURE_BASE_DIR ?=
CAPTURE_MAX ?= 0
PPROF_CAPTURE_PID_FILE ?= .pprof_capture.pid
PPROF_CAPTURE_LOG ?= notes/pprof-logs/pprof_capture.log
PPROF_WAIT ?= 60
PPROF_URL ?= http://localhost:1777/debug/pprof/heap

pprof-wait:
	@if [ "$(PPROF_WAIT)" -le 0 ]; then exit 0; fi; \
	READY=0; \
	for i in $$(seq 1 $(PPROF_WAIT)); do \
		if curl -s --fail "$(PPROF_URL)" >/dev/null 2>&1; then \
			READY=1; \
			break; \
		fi; \
		sleep 1; \
	done; \
	if [ "$$READY" -ne 1 ]; then \
		echo "❌ pprof not ready at $(PPROF_URL) (waited $(PPROF_WAIT)s)"; \
		exit 1; \
	fi

pprof-capture-bg:
	@mkdir -p notes/pprof-logs
	@if [ -f "$(PPROF_CAPTURE_PID_FILE)" ] && kill -0 "$$(cat $(PPROF_CAPTURE_PID_FILE))" 2>/dev/null; then \
		echo "✅ pprof capture already running (pid=$$(cat $(PPROF_CAPTURE_PID_FILE)))"; \
		exit 0; \
	fi
	@$(MAKE) pprof-wait
	@nohup bash scripts/capture_pprof.sh $(CAPTURE_INTERVAL) "$(CAPTURE_BASE_DIR)" $(CAPTURE_MAX) \
		> "$(PPROF_CAPTURE_LOG)" 2>&1 & echo $$! > "$(PPROF_CAPTURE_PID_FILE)"
	@sleep 1; \
	if [ ! -f "$(PPROF_CAPTURE_PID_FILE)" ] || ! kill -0 "$$(cat $(PPROF_CAPTURE_PID_FILE))" 2>/dev/null; then \
		echo "❌ pprof capture failed to start. Check log: $(PPROF_CAPTURE_LOG)"; \
		exit 1; \
	fi
	@echo "✅ pprof capture started (pid=$$(cat $(PPROF_CAPTURE_PID_FILE)))"

pprof-capture-stop:
	@if [ ! -f "$(PPROF_CAPTURE_PID_FILE)" ]; then \
		echo "ℹ️  pprof capture not running (no pid file)"; \
		exit 0; \
	fi
	@PID=$$(cat "$(PPROF_CAPTURE_PID_FILE)"); \
	if kill -0 $$PID 2>/dev/null; then \
		kill $$PID; \
		for i in 1 2 3 4 5; do \
			kill -0 $$PID 2>/dev/null || break; \
			sleep 1; \
		done; \
		if kill -0 $$PID 2>/dev/null; then \
			kill -9 $$PID 2>/dev/null || true; \
			sleep 1; \
		fi; \
		if kill -0 $$PID 2>/dev/null; then \
			echo "❌ pprof capture still running (pid=$$PID)"; \
			exit 1; \
		fi; \
		echo "✅ pprof capture stopped (pid=$$PID)"; \
	else \
		echo "ℹ️  pprof capture pid not running (pid=$$PID)"; \
	fi
	@rm -f "$(PPROF_CAPTURE_PID_FILE)"

pprof-capture-status:
	@if [ -f "$(PPROF_CAPTURE_PID_FILE)" ] && kill -0 "$$(cat $(PPROF_CAPTURE_PID_FILE))" 2>/dev/null; then \
		echo "✅ pprof capture running (pid=$$(cat $(PPROF_CAPTURE_PID_FILE)))"; \
		echo "   log: $(PPROF_CAPTURE_LOG)"; \
	else \
		echo "ℹ️  pprof capture not running"; \
	fi

# 調査結果をテキストレポートとして保存
# 使用例: make pprof-report BASE=... NEW=... > report.txt
pprof-report:
	@echo "=== Top 50 Memory Increases ==="
	@go tool pprof -top -nodecount=50 --diff_base $(BASE) $(NEW)
	@echo "\n=== Call Tree ==="
	@go tool pprof -tree -nodecount=30 --diff_base $(BASE) $(NEW)
