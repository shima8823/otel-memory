# OTel Collector Memory 負荷テスト環境
# =====================================

# =====================================
# 変数定義
# =====================================

# === 基本設定 ===
LOADGEN := ./loadgen/loadgen
ENDPOINT := localhost:4317
RESTART_COLLECTOR := docker compose up -d --force-recreate otel-collector

# === シナリオ設定 ===
# ベースシナリオ: Trace > Metrics > Logsなので、Traceのみ
# 1スパン: 128 bytes × 8属性 = 1KB
# 1トレース: 1KB × (depth+1) = 4KB （root + 3子スパン）
# rate 12,000 spans/sec → 12MB/sec 流入
BASE_SCENARIO := sustained
BASE_PARAMS := -workers 10 -attr-size 128 -attr-count 8 -depth 3 \
	-metrics=false -logs=false
SCENARIO_FILE_1 := otel-collector/scenarios/scenario-1.yaml
SCENARIO_FILE_2 := otel-collector/scenarios/high-cardinality-spanmetrics.yaml
SCENARIO_FILE_RECEIVER := otel-collector/scenarios/scenario-receiver.yaml
SCENARIO_FILE_TAIL := otel-collector/scenarios/tail-sampling.yaml

# === telemetrygen設定 ===
TELEMETRYGEN_IMAGE := ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest
TGEN := docker run --rm --network host $(TELEMETRYGEN_IMAGE)

# === メトリクスエクスポート設定 ===
DURATION ?= 15
STEP ?= 60
OUTPUT ?= metrics_export

# === pprof設定 ===
CAPTURE_INTERVAL ?= 5
CAPTURE_BASE_DIR ?=
CAPTURE_MAX ?= 0
PPROF_CAPTURE_PID_FILE ?= .pprof_capture.pid
PPROF_DIR ?= pprof
PPROF_LOG_DIR ?= $(PPROF_DIR)/logs
PPROF_CAPTURE_LOG ?= $(PPROF_LOG_DIR)/pprof_capture.log
PPROF_WAIT ?= 60
PPROF_URL ?= http://localhost:1777/debug/pprof/heap
SCENARIO ?= scenario-1
SYNC ?= 1
RESTART ?= 1

# === pprof-peak-diff 位置引数対応 ===
ifneq (,$(filter pprof-peak-diff,$(MAKECMDGOALS)))
DIR ?= $(word 2,$(MAKECMDGOALS))
ifneq ($(DIR),)
$(DIR):
	@:
endif
endif

# =====================================
# マクロ定義
# =====================================

# シナリオ実行マクロ（統合版）
# $(1): シナリオ番号
# $(2): メッセージ
# $(3): loadgenコマンド（BASE_PARAMS除く）
# $(4): 下流停止秒（0=下流停止なし）
# $(5): 観察秒（下流停止時のみ使用）
define run_scenario
	@echo "========================================"
	@echo "シナリオ $(1): $(2)"
	@echo "========================================"
	@echo "📌 シナリオ用設定を適用中..."
	@cp $(if $(6),$(6),otel-collector/scenarios/scenario-$(1).yaml) otel-collector/otel-collector.yaml
	@$(RESTART_COLLECTOR)
	@echo "✅ 設定ファイル適用完了"
	@echo ""
	@if [ "$(4)" -gt 0 ]; then \
		$(3) $(BASE_PARAMS) & PID=$$!; \
		echo "⏳ $(4)秒後にJaeger停止..."; sleep $(4); \
		echo "🛑 Jaeger停止"; docker compose stop jaeger; \
		echo "⏳ $(5)秒間観察..."; sleep $(5); \
		echo "🔄 Jaeger復旧"; docker compose start jaeger; \
		wait $$PID 2>/dev/null || true; \
		git restore otel-collector/otel-collector.yaml; \
		$(RESTART_COLLECTOR); \
		echo "✅ シナリオ完了"; \
	else \
		($(3) $(BASE_PARAMS)) ; \
		EXIT_CODE=$$? ; \
		echo "" ; \
		echo "📌 設定をベストプラクティスに復元中..." ; \
		git restore otel-collector/otel-collector.yaml ; \
		$(RESTART_COLLECTOR) ; \
		echo "✅ 設定の復元完了" ; \
		exit $$EXIT_CODE; \
	fi
endef

# =====================================
# Help
# =====================================
.PHONY: help help-env help-build help-scenario help-load help-tgen help-config help-util help-pprof

help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "詳細: make help-<section>"
	@echo "  help-env       環境操作"
	@echo "  help-build     ビルド"
	@echo "  help-scenario  シナリオテスト"
	@echo "  help-load      負荷テスト (loadgen)"
	@echo "  help-tgen      負荷テスト (telemetrygen)"
	@echo "  help-config    設定管理"
	@echo "  help-util      ユーティリティ"
	@echo "  help-pprof     プロファイリング"
	@echo ""
	@echo "=== 主要ターゲット ==="
	@echo "  up/down/restart     環境操作"
	@echo "  build/clean         ビルド"
	@echo "  scenario-*          シナリオ実行"
	@echo "  load-*              負荷テスト"
	@echo "  pprof-heap          メモリプロファイル"
	@echo ""
	@echo "=== URL ==="
	@echo "  Grafana:    http://localhost:3000"
	@echo "  Prometheus: http://localhost:9090"
	@echo "  Jaeger:     http://localhost:16686"
	@echo "  pprof:      http://localhost:1777/debug/pprof/"

help-env:
	@echo "=== 環境操作 ==="
	@echo "  up                  全サービス起動 (Collector, Prometheus, Jaeger, Grafana)"
	@echo "  down                全サービス停止"
	@echo "  restart             全サービス再起動"
	@echo "  restart-collector   Collector のみ再起動（設定変更後に使用）"
	@echo "  logs                Collector のログを表示"
	@echo "  logs-f              Collector のログをフォロー"
	@echo "  status              サービス状態を表示"

help-build:
	@echo "=== ビルド ==="
	@echo "  build               loadgen をビルド"
	@echo "  clean               ビルド成果物を削除"

help-scenario:
	@echo "=== シナリオテスト (docs/blog/scenario-reports/why-these-scenarios.md 参照) ==="
	@echo "  scenario-1              [参考] 下流停止 (1:負荷開始 -> 2:別ターミナルで jaeger-stop)"
	@echo "  scenario-2              [空間軸] processor 異常系（spanmetricsによる高カーディナリティ爆発）"
	@echo "  scenario-receiver       [流量軸] 受信過多（慢性的なデータドロップ）"
	@echo "  scenario-tail-sampling  [時間軸] Tail Sampling（decision_wait によるメモリ肥大化）"
	@echo "  scenario-high-cardinality-metrics  [空間軸] 王道の高カーディナリティ（メトリクスラベル爆発）"

help-load:
	@echo "=== 負荷テスト (loadgen) ==="
	@echo "  load-burst          burst シナリオ (最大速度で送信)"
	@echo "  load-sustained      sustained シナリオ (一定レートで継続)"
	@echo "  load-spike          spike シナリオ (通常↔スパイクを交互)"
	@echo "  load-rampup         rampup シナリオ (徐々に負荷増加)"
	@echo "  load-light          軽い負荷 (動作確認用)"
	@echo "  load-logs           ログ送信テスト"
	@echo "  load-stop           実行中の loadgen を停止"

help-tgen:
	@echo "=== 負荷テスト (telemetrygen) ==="
	@echo "  tgen-traces         traces を生成"
	@echo "  tgen-metrics        metrics を生成"
	@echo "  tgen-logs           logs を生成"
	@echo "  tgen-burst          高負荷 traces (memory_limiter 発火用)"
	@echo "  tgen-sustained      持続的な負荷"
	@echo "  tgen-all            traces + metrics + logs を同時生成"
	@echo "  tgen-help           telemetrygen のヘルプを表示"

help-config:
	@echo "=== 設定管理 ==="
	@echo "  reset-config        設定ファイルをデフォルトに戻す"
	@echo "  show-config         現在の設定ファイルの内容を表示"

help-util:
	@echo "=== ユーティリティ ==="
	@echo "  check-memory        現在のメモリ消費量とRefusedを確認"
	@echo "  metrics             Collector の内部メトリクス一覧を表示"
	@echo "  export-metrics      Grafanaダッシュボードのメトリクスをエクスポート"
	@echo "  clean-metrics       メトリクスエクスポートディレクトリを削除"
	@echo "  jaeger-stop         Jaeger を停止"
	@echo "  jaeger-start        Jaeger を起動"

help-pprof:
	@echo "=== pprof 基本 ==="
	@echo "  pprof-heap          ヒーププロファイルを取得してブラウザで開く"
	@echo "  pprof-cpu           CPUプロファイルを取得（30秒）してブラウザで開く"
	@echo "  pprof-allocs        allocsプロファイルを取得してブラウザで開く"
	@echo ""
	@echo "=== pprof キャプチャ ==="
	@echo "  pprof-capture       5秒おきにプロファイルを取得"
	@echo "  pprof-capture-bg    バックグラウンドでキャプチャ開始"
	@echo "  pprof-capture-stop  バックグラウンドキャプチャ停止"
	@echo "  pprof-capture-status キャプチャ状態を確認"
	@echo ""
	@echo "=== pprof 分析 ==="
	@echo "  pprof-diff          2つのプロファイルを比較 (BASE=... NEW=...)"
	@echo "  pprof-diff-stop     diff UIを停止"
	@echo "  pprof-list          キャプチャ一覧表示 (DIR=...)"
	@echo "  pprof-diff-auto     ベースラインとピークを自動検出して比較 (DIR=...)"
	@echo "  pprof-peak-diff     ピークと直前を比較 (DIR=...)"
	@echo "  pprof-report        テキストレポート出力 (BASE=... NEW=...)"
	@echo ""
	@echo "=== pprof シナリオ統合 ==="
	@echo "  pprof-scenario-full  Terraform→シナリオ→pprof→diff自動実行"
	@echo "                       (SCENARIO=scenario-1 SYNC=1 RESTART=1)"
	@echo "  pprof-scenario1-full scenario-1 を実行"
	@echo "  pprof-scenario2-full scenario-2 を実行"

# =====================================
# 環境操作
# =====================================
.PHONY: up down restart restart-collector logs logs-f status

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
.PHONY: build clean

build:
	cd loadgen && go build -o loadgen .
	@echo "✅ loadgen built: ./loadgen/loadgen"

clean:
	rm -f loadgen/loadgen
	@echo "✅ Cleaned"

# =====================================
# シナリオテスト
# =====================================
.PHONY: scenario-1 scenario-2 scenario-receiver scenario-tail-sampling scenario-high-cardinality-metrics

scenario-1: build
	$(call run_scenario,1,下流停止,\
		$(LOADGEN) -endpoint $(ENDPOINT) -scenario $(BASE_SCENARIO) \
		-duration 180s -rate 12000,30,60,$(SCENARIO_FILE_1))

scenario-2: build
	$(call run_scenario,2,processor高カーディナリティ,\
		$(LOADGEN) -endpoint $(ENDPOINT) -scenario $(BASE_SCENARIO) \
		-duration 240s -rate 12000 -high-cardinality,0,0,$(SCENARIO_FILE_2))

scenario-receiver: build
	$(call run_scenario,receiver,受信過多（流量軸）,\
		$(LOADGEN) -endpoint $(ENDPOINT) -scenario $(BASE_SCENARIO) \
		-duration 180s -rate 35000,0,0,$(SCENARIO_FILE_RECEIVER))

scenario-tail-sampling: build
	$(call run_scenario,tail-sampling,Tail Sampling（時間軸の罠）,\
		$(LOADGEN) -endpoint $(ENDPOINT) -scenario $(BASE_SCENARIO) \
		-duration 180s -rate 10000,0,0,$(SCENARIO_FILE_TAIL))

# 王道の高カーディナリティメトリクス シナリオ（空間軸）
# メトリクスラベルに request_id, user_id 等を含めると時系列が爆発
# spanmetrics を使わない「最も一般的な」高カーディナリティ問題
scenario-high-cardinality-metrics:
	@if [ -z "$(PROJECT_ID)" ]; then \
		echo "❌ PROJECT_ID is not set. Run: export PROJECT_ID=\$$(gcloud config get-value project)"; \
		exit 1; \
	fi
	PROJECT_ID="$(PROJECT_ID)" $(MAKE) -C terraform sync
	PROJECT_ID="$(PROJECT_ID)" $(MAKE) -C terraform prepare-high-cardinality-metrics
	PROJECT_ID="$(PROJECT_ID)" $(MAKE) -C terraform restart
	PROJECT_ID="$(PROJECT_ID)" $(MAKE) -C terraform scenario-high-cardinality-metrics

# =====================================
# 負荷テスト (loadgen)
# =====================================
.PHONY: load-burst load-sustained load-spike load-rampup load-light load-logs load-stop

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
.PHONY: tgen-traces tgen-metrics tgen-logs tgen-burst tgen-sustained tgen-all tgen-help

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
.PHONY: reset-config show-config

reset-config:
	@git restore otel-collector/otel-collector.yaml
	@docker compose restart otel-collector
	@echo "✅ Config restored to best-practice (Git HEAD) and Collector restarted"

show-config:
	@cat otel-collector/otel-collector.yaml

# =====================================
# ユーティリティ
# =====================================
.PHONY: check-memory metrics jaeger-stop jaeger-start

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
.PHONY: export-metrics clean-metrics

# GrafanaダッシュボードのメトリクスをLLM/人間向けにエクスポート
# 使用例:
#   make export-metrics                    # デフォルト: 直近15分、60秒間隔
#   make export-metrics DURATION=60        # 直近60分
#   make export-metrics STEP=30            # 30秒間隔
#   make export-metrics OUTPUT=my_export   # 出力先を変更
export-metrics:
	@echo "=== Grafana メトリクスエクスポート ==="
	python3 scripts/export_grafana_metrics.py --duration $(DURATION) --step $(STEP) --output $(OUTPUT)
	@echo ""
	@echo "✅ エクスポート完了: $(OUTPUT)/"

clean-metrics:
	rm -rf metrics_export
	@echo "✅ メトリクスエクスポートディレクトリ削除完了"

# =====================================
# pprof - 基本
# =====================================
.PHONY: pprof-heap pprof-cpu pprof-allocs

pprof-heap:
	@echo "🔍 Fetching Heap Profile..."
	go tool pprof -http=:8080 http://localhost:1777/debug/pprof/heap

pprof-allocs:
	@echo "🔍 Fetching Allocs Profile..."
	go tool pprof -http=:8080 http://localhost:1777/debug/pprof/allocs

pprof-cpu:
	@echo "🔍 Profiling CPU for 30s..."
	go tool pprof -http=:8080 http://localhost:1777/debug/pprof/profile?seconds=30

# =====================================
# pprof - キャプチャ
# =====================================
.PHONY: pprof-capture pprof-capture-bg pprof-capture-stop pprof-capture-status pprof-wait

pprof-capture:
	@bash scripts/capture_pprof.sh 5

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
	@mkdir -p $(PPROF_LOG_DIR)
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

# =====================================
# pprof - 分析
# =====================================
.PHONY: pprof-diff pprof-diff-stop pprof-list pprof-diff-auto pprof-peak-diff pprof-report

pprof-diff:
	@if [ -z "$(BASE)" ] || [ -z "$(NEW)" ]; then \
		echo "❌ Usage: make pprof-diff BASE=path/to/old.pprof NEW=path/to/new.pprof"; \
		exit 1; \
	fi
	go tool pprof -http=:8081 --diff_base $(BASE) $(NEW)

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

pprof-list:
	@if [ -z "$(DIR)" ]; then echo "❌ Usage: make pprof-list DIR=path/to/captures/XXXXXX"; exit 1; fi
	@for f in $(DIR)/*.pprof; do \
		[ -s "$$f" ] || continue; \
		printf "%1s " "$$(basename $$f):"; \
		python3 scripts/pprof_total_mb.py "$$f"; \
	done

pprof-diff-auto:
	@if [ -z "$(DIR)" ]; then echo "❌ Usage: make pprof-diff-auto DIR=path/to/captures/XXXXXX"; exit 1; fi
	@bash scripts/pprof_diff_auto.sh "$(DIR)"

pprof-peak-diff:
	@if [ -z "$(DIR)" ]; then echo "❌ Usage: make pprof-peak-diff DIR=path/to/captures/XXXXXX"; exit 1; fi
	@bash scripts/pprof_peak_diff.sh "$(DIR)"

pprof-report:
	@echo "=== Top 50 Memory Increases ==="
	@go tool pprof -top -nodecount=50 --diff_base $(BASE) $(NEW)
	@echo "\n=== Call Tree ==="
	@go tool pprof -tree -nodecount=30 --diff_base $(BASE) $(NEW)

# =====================================
# pprof - シナリオ統合
# =====================================
.PHONY: pprof-scenario-full pprof-scenario1-full pprof-scenario2-full

pprof-scenario-full:
	@if [ -z "$(PROJECT_ID)" ]; then \
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
	PPROF_WAIT=0 make pprof-capture-bg || { \
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
	LOG_FILE="$(PPROF_CAPTURE_LOG)"; \
	if [ ! -f "$$LOG_FILE" ]; then \
		echo "❌ pprof capture log not found: $$LOG_FILE"; \
		exit 1; \
	fi; \
	DIR=$$(grep -m1 "保存先:" "$$LOG_FILE" | sed 's/.*保存先: //'); \
	if [ -z "$$DIR" ]; then \
		echo "❌ Failed to parse output dir from $$LOG_FILE"; \
		exit 1; \
	fi; \
	echo "=== Open diff (peak vs previous) ==="; \
	make pprof-peak-diff DIR="$$DIR"

# 互換用（既存の呼び出しを維持）
pprof-scenario1-full: pprof-scenario-full

pprof-scenario2-full:
	$(MAKE) pprof-scenario-full SCENARIO=scenario-2
