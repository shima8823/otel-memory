# OTel Collector Memory 負荷テスト環境
# =====================================
SHELL := /bin/bash

# =====================================
# 変数定義
# =====================================

# === Python 実行環境 ===
# .venv が存在すればそちらを優先（ローカル venv 対応）
PYTHON := $(shell [ -x .venv/bin/python3 ] && echo .venv/bin/python3 || echo python3)

# === 基本設定 ===
ENDPOINT := localhost:4317
RESTART_COLLECTOR := docker compose up -d --force-recreate otel-collector
COMPOSE_BQ := docker compose -f docker-compose.yaml -f docker-compose.batch-queue.yaml

SCENARIO_FILE_SPANMETRICS := otel-collector/scenarios/high-cardinality-spanmetrics.yaml
SCENARIO_FILE_SPANMETRICS_OPT := otel-collector/scenarios/high-cardinality-spanmetrics-optimized.yaml
SCENARIO_FILE_TAIL := otel-collector/scenarios/tail-sampling.yaml
SCENARIO_FILE_BQ := otel-collector/scenarios/batch-queue-amplification.yaml
SCENARIO_FILE_BQ_OPT := otel-collector/scenarios/batch-queue-amplification-optimized.yaml

# === telemetrygen設定 ===
TELEMETRYGEN_IMAGE := ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest
TGEN := docker run --rm --network host $(TELEMETRYGEN_IMAGE)

# === telemetrygen シナリオレート設定（config.mk から読み込み） ===
include config.mk
TGEN_BQ_ATTRS := --telemetry-attributes 'padding="$(TGEN_BQ_PADDING)"'

# === メトリクスエクスポート設定 ===
DURATION ?= 15
STEP ?= 60
OUTPUT ?= metrics_export

# === pprof設定 ===
CAPTURE_INTERVAL ?= 5
CAPTURE_BASE_DIR ?=
CAPTURE_MAX ?= 0
PPROF_CAPTURE_PID_FILE ?= .pprof_capture.pid
CAPTURE_DIR ?= captures
CAPTURE_LOG_DIR ?= $(CAPTURE_DIR)/logs
PPROF_CAPTURE_LOG ?= $(CAPTURE_LOG_DIR)/pprof_capture.log
PPROF_FORWARD_LOG ?= $(CAPTURE_LOG_DIR)/port_forward_pprof.log
CAPTURE_LAST_DIR_FILE ?= $(CAPTURE_DIR)/last_capture.txt
PPROF_TUNNEL_PORT ?= 1777
PPROF_PORT ?= 8080
PPROF_DIFF_PORT ?= 8081
PPROF_CAPTURE_READY_WAIT ?= 60
PPROF_WAIT ?= 60
PPROF_URL ?= http://localhost:$(PPROF_TUNNEL_PORT)/debug/pprof/heap
SCENARIO ?= scenario-tail-sampling
SYNC ?= 1
RESTART ?= 1
APPLY ?= 1

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

# telemetrygen シナリオ実行マクロ
# $(1): シナリオ名, $(2): メッセージ, $(3): telemetrygenコマンド（完全形）
# $(4): Jaeger停止秒, $(5): 観察秒, $(6): シナリオファイルパス
define run_scenario
	@echo "========================================"
	@echo "シナリオ $(1): $(2) [telemetrygen]"
	@echo "========================================"
	@echo "📌 シナリオ用設定を適用中..."
	@cp $(if $(6),$(6),otel-collector/scenarios/scenario-$(1).yaml) otel-collector/otel-collector.yaml
	@$(RESTART_COLLECTOR)
	@echo "✅ 設定ファイル適用完了"
	@echo ""
	@if [ "$(4)" -gt 0 ]; then \
		$(3) & PID=$$!; \
		echo "⏳ $(4)秒後にJaeger停止..."; sleep $(4); \
		echo "🛑 Jaeger停止"; docker compose stop jaeger; \
		echo "⏳ $(5)秒間観察..."; sleep $(5); \
		echo "🔄 Jaeger復旧"; docker compose start jaeger; \
		wait $$PID 2>/dev/null || true; \
		git restore otel-collector/otel-collector.yaml; \
		$(RESTART_COLLECTOR); \
		echo "✅ シナリオ完了"; \
	else \
		($(3)) ; \
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
.PHONY: help help-env help-scenario help-config help-util help-pprof

help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "詳細: make help-<section>"
	@echo "  help-env       環境操作"
	@echo "  help-scenario  シナリオテスト"
	@echo "  help-config    設定管理"
	@echo "  help-util      ユーティリティ"
	@echo "  help-pprof     プロファイリング"
	@echo ""
	@echo "=== 主要ターゲット ==="
	@echo "  up/down/restart     環境操作"
	@echo "  scenario-*          シナリオ実行"
	@echo "  run-*               GCP統合シナリオ実行"
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

help-scenario:
	@echo "=== シナリオテスト ==="
	@echo "  scenario-tail-sampling           [時間軸] Tail Sampling [telemetrygen]"
	@echo "  scenario-tail-sampling-optimized  [時間軸] Tail Sampling 最適化版 [telemetrygen]"
	@echo "  scenario-spanmetrics                       [空間軸] spanmetrics 高カーディナリティ [Python + OTel SDK]"
	@echo "  scenario-spanmetrics-optimized              [空間軸] spanmetrics 最適化版 [Python + OTel SDK]"
	@echo "  scenario-batch-queue              [流量軸] Batch × Queue メモリ増幅 [telemetrygen]"
	@echo "  scenario-batch-queue-optimized    [流量軸] Batch × Queue 最適化版 [telemetrygen]"

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
	@echo "  pprof-ui            単一のプロファイルを表示 (FILE=...)"
	@echo "  pprof-report        テキストレポート出力 (BASE=... NEW=...)"
	@echo ""
	@echo "=== ローカル統合実行 ==="
	@echo "  run-local SCENARIO=scenario-xxx    ローカルでシナリオ実行 + pprof + メトリクス自動収集"
	@echo ""
	@echo "=== シナリオ統合実行 ==="
	@echo "  run-scenario                全自動実行 (SCENARIO=scenario-tail-sampling SYNC=1 RESTART=1)"
	@echo "  run-tail-sampling           tail-sampling を実行"
	@echo "  run-tail-sampling-optimized tail-sampling 最適化版を実行"
	@echo "  run-scenario-spanmetrics              scenario-spanmetrics Python版を実行"
	@echo "  run-scenario-spanmetrics-optimized    scenario-spanmetrics 最適化版を実行"
	@echo "  run-batch-queue             batch-queue メモリ増幅を実行"
	@echo "  run-batch-queue-optimized   batch-queue 最適化版を実行"

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
# シナリオテスト
# =====================================
.PHONY: scenario-tail-sampling scenario-tail-sampling-optimized scenario-spanmetrics scenario-spanmetrics-optimized scenario-batch-queue scenario-batch-queue-optimized

# Tail Sampling（時間軸: 保持遅延型）
# telemetrygen 1500 traces/s × (1 root + 5 child) = 約9,000 spans/s
scenario-tail-sampling:
	$(call run_scenario,tail-sampling,Tail Sampling（時間軸の罠）,\
		$(TGEN) traces --otlp-endpoint $(ENDPOINT) --otlp-insecure \
		--rate $(TGEN_TAIL_RATE) --duration $(TGEN_TAIL_DURATION) \
		--workers $(TGEN_TAIL_WORKERS) --child-spans $(TGEN_TAIL_CHILD_SPANS),0,0,$(SCENARIO_FILE_TAIL))

# Tail Sampling 最適化版（decision_wait短縮）
scenario-tail-sampling-optimized:
	$(call run_scenario,tail-sampling-optimized,Tail Sampling 最適化版,\
		$(TGEN) traces --otlp-endpoint $(ENDPOINT) --otlp-insecure \
		--rate $(TGEN_TAIL_RATE) --duration $(TGEN_TAIL_DURATION) \
		--workers $(TGEN_TAIL_WORKERS) --child-spans $(TGEN_TAIL_CHILD_SPANS),0,0,otel-collector/scenarios/tail-sampling-optimized.yaml)

# 高カーディナリティ spanmetrics [Python + OTel SDK]
# telemetrygen ではランダム属性生成ができないため Python を使用
scenario-spanmetrics:
	$(call run_scenario,2,高カーディナリティ spanmetrics [Python],\
		$(PYTHON) pyloadgen/high_cardinality_traces.py \
		--endpoint $(ENDPOINT) --rate $(TGEN_SM_RATE) --duration $(TGEN_SM_DURATION) \
		--workers $(TGEN_SM_WORKERS) --attr-count $(TGEN_SM_ATTR_COUNT),0,0,$(SCENARIO_FILE_SPANMETRICS))

# 高カーディナリティ spanmetrics 最適化版 [Python + OTel SDK]
# 問題版と同じ負荷だが、dimensions から高カーディナリティ属性を除外
scenario-spanmetrics-optimized:
	$(call run_scenario,2-optimized,高カーディナリティ spanmetrics 最適化版 [Python],\
		$(PYTHON) pyloadgen/high_cardinality_traces.py \
		--endpoint $(ENDPOINT) --rate $(TGEN_SM_RATE) --duration $(TGEN_SM_DURATION) \
		--workers $(TGEN_SM_WORKERS) --attr-count $(TGEN_SM_ATTR_COUNT),0,0,$(SCENARIO_FILE_SPANMETRICS_OPT))

# Jaeger に CPU 制限をかけてバックエンドのスローダウンを模擬
scenario-batch-queue:
	@echo "========================================"
	@echo "シナリオ batch-queue: Batch × Queue メモリ増幅（流量軸の罠） [telemetrygen]"
	@echo "========================================"
	@echo "📌 Collector 設定を適用中..."
	@cp $(SCENARIO_FILE_BQ) otel-collector/otel-collector.yaml
	@$(RESTART_COLLECTOR)
	@echo "✅ Collector 設定適用完了"
	@echo "📌 Jaeger CPU 制限を適用中（バックエンドスローダウン模擬）..."
	@$(COMPOSE_BQ) up -d jaeger
	@echo "✅ Jaeger CPU 制限適用完了"
	@echo ""
	@$(TGEN) traces --otlp-endpoint $(ENDPOINT) --otlp-insecure \
		--rate $(TGEN_BQ_RATE) --duration $(TGEN_BQ_DURATION) \
		--workers $(TGEN_BQ_WORKERS) --child-spans $(TGEN_BQ_CHILD_SPANS) \
		$(TGEN_BQ_ATTRS) || true
	@echo ""
	@echo "📌 設定を復元中..."
	@docker compose up -d jaeger
	@git restore otel-collector/otel-collector.yaml
	@$(RESTART_COLLECTOR)
	@echo "✅ 設定の復元完了"

# Batch × Queue 最適化版（send_batch_size + queue_size 縮小）
# 同じ Jaeger CPU 制限下で最適化版の設定がメモリ内に収まることを示す
scenario-batch-queue-optimized:
	@echo "========================================"
	@echo "シナリオ batch-queue-optimized: Batch × Queue 最適化版 [telemetrygen]"
	@echo "========================================"
	@echo "📌 Collector 設定を適用中..."
	@cp $(SCENARIO_FILE_BQ_OPT) otel-collector/otel-collector.yaml
	@$(RESTART_COLLECTOR)
	@echo "✅ Collector 設定適用完了"
	@echo "📌 Jaeger CPU 制限を適用中（バックエンドスローダウン模擬）..."
	@$(COMPOSE_BQ) up -d jaeger
	@echo "✅ Jaeger CPU 制限適用完了"
	@echo ""
	@$(TGEN) traces --otlp-endpoint $(ENDPOINT) --otlp-insecure \
		--rate $(TGEN_BQ_RATE) --duration $(TGEN_BQ_DURATION) \
		--workers $(TGEN_BQ_WORKERS) --child-spans $(TGEN_BQ_CHILD_SPANS) \
		$(TGEN_BQ_ATTRS) || true
	@echo ""
	@echo "📌 設定を復元中..."
	@docker compose up -d jaeger
	@git restore otel-collector/otel-collector.yaml
	@$(RESTART_COLLECTOR)
	@echo "✅ 設定の復元完了"

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
	go tool pprof -http=:$(PPROF_PORT) http://localhost:$(PPROF_TUNNEL_PORT)/debug/pprof/heap

pprof-allocs:
	@echo "🔍 Fetching Allocs Profile..."
	go tool pprof -http=:$(PPROF_PORT) http://localhost:$(PPROF_TUNNEL_PORT)/debug/pprof/allocs

pprof-cpu:
	@echo "🔍 Profiling CPU for 30s..."
	go tool pprof -http=:$(PPROF_PORT) http://localhost:$(PPROF_TUNNEL_PORT)/debug/pprof/profile?seconds=30

# =====================================
# pprof - キャプチャ
# =====================================
.PHONY: pprof-capture pprof-capture-bg pprof-capture-stop pprof-capture-status pprof-wait pprof-capture-wait

pprof-capture:
	@PPROF_URL="$(PPROF_URL)" PPROF_TUNNEL_PORT="$(PPROF_TUNNEL_PORT)" \
		bash scripts/capture_pprof.sh 5

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

pprof-capture-wait:
	@READY=0; \
	for i in $$(seq 1 $(PPROF_CAPTURE_READY_WAIT)); do \
		if [ -f "$(CAPTURE_LAST_DIR_FILE)" ]; then \
			DIR=$$(cat "$(CAPTURE_LAST_DIR_FILE)"); \
			if [ -n "$$DIR" ] && [ -f "$$DIR/.ready" ]; then \
				READY=1; \
				break; \
			fi; \
		fi; \
		sleep 1; \
	done; \
	if [ "$$READY" -ne 1 ]; then \
		echo "❌ pprof capture not ready (no successful capture within $(PPROF_CAPTURE_READY_WAIT)s)"; \
		if [ -f "$(PPROF_CAPTURE_LOG)" ]; then \
			echo "---- pprof_capture.log (tail) ----"; \
			tail -n 20 "$(PPROF_CAPTURE_LOG)" || true; \
		fi; \
		if [ -f "$(PPROF_FORWARD_LOG)" ]; then \
			echo "---- port_forward.log (tail) ----"; \
			tail -n 20 "$(PPROF_FORWARD_LOG)" || true; \
		fi; \
		exit 1; \
	fi

pprof-capture-bg:
	@mkdir -p $(CAPTURE_LOG_DIR)
	@mkdir -p $(CAPTURE_DIR)
	@if [ -f "$(PPROF_CAPTURE_PID_FILE)" ] && kill -0 "$$(cat $(PPROF_CAPTURE_PID_FILE))" 2>/dev/null; then \
		echo "✅ pprof capture already running (pid=$$(cat $(PPROF_CAPTURE_PID_FILE)))"; \
		exit 0; \
	fi
	@$(MAKE) pprof-wait
	@CAPTURE_LAST_DIR_FILE="$(CAPTURE_LAST_DIR_FILE)" OUTPUT_FILE="$(CAPTURE_LAST_DIR_FILE)" \
		PPROF_URL="$(PPROF_URL)" PPROF_TUNNEL_PORT="$(PPROF_TUNNEL_PORT)" \
		nohup bash scripts/capture_pprof.sh $(CAPTURE_INTERVAL) "$(CAPTURE_BASE_DIR)" $(CAPTURE_MAX) \
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
.PHONY: pprof-diff pprof-diff-stop pprof-list pprof-diff-auto pprof-peak-diff pprof-ui pprof-report

pprof-ui:
	@if [ -z "$(FILE)" ]; then echo "❌ Usage: make pprof-ui FILE=path/to/captures/MM-DD/HHMMSS/pprof/profile.pprof"; exit 1; fi
	go tool pprof -http=:$(PPROF_PORT) $(FILE)

pprof-diff:
	@if [ -z "$(BASE)" ] || [ -z "$(NEW)" ]; then \
		echo "❌ Usage: make pprof-diff BASE=path/to/old.pprof NEW=path/to/new.pprof"; \
		exit 1; \
	fi
	go tool pprof -http=:$(PPROF_DIFF_PORT) --diff_base $(BASE) $(NEW)

pprof-diff-stop:
	@PID=$$(lsof -ti tcp:$(PPROF_DIFF_PORT) 2>/dev/null); \
	if [ -z "$$PID" ]; then \
		echo "ℹ️  No process is listening on :$(PPROF_DIFF_PORT)"; \
		exit 0; \
	fi; \
	kill $$PID 2>/dev/null || true; \
	for i in 1 2 3; do \
		if ! kill -0 $$PID 2>/dev/null; then \
			echo "✅ Stopped :$(PPROF_DIFF_PORT) (pid=$$PID)"; \
			exit 0; \
		fi; \
		sleep 1; \
	done; \
	kill -9 $$PID 2>/dev/null || true; \
	if ! kill -0 $$PID 2>/dev/null; then \
		echo "✅ Stopped :$(PPROF_DIFF_PORT) (pid=$$PID)"; \
		exit 0; \
	fi; \
	echo "❌ Failed to stop :$(PPROF_DIFF_PORT) (pid=$$PID)"; \
	exit 1

pprof-list:
	@if [ -z "$(DIR)" ]; then echo "❌ Usage: make pprof-list DIR=path/to/captures/XXXXXX"; exit 1; fi
	@python3 scripts/pprof_list.py "$(DIR)/pprof"

pprof-diff-auto:
	@if [ -z "$(DIR)" ]; then echo "❌ Usage: make pprof-diff-auto DIR=path/to/captures/XXXXXX"; exit 1; fi
	@bash scripts/pprof_diff_auto.sh "$(DIR)"

pprof-peak-diff:
	@if [ -z "$(DIR)" ]; then echo "❌ Usage: make pprof-peak-diff DIR=path/to/captures/XXXXXX"; exit 1; fi
	@bash scripts/pprof_peak_diff.sh "$(DIR)/pprof"

pprof-report:
	@echo "=== Top 50 Memory Increases ==="
	@go tool pprof -top -nodecount=50 --diff_base $(BASE) $(NEW)
	@echo "\n=== Call Tree ==="
	@go tool pprof -tree -nodecount=30 --diff_base $(BASE) $(NEW)

# =====================================
# ローカル統合実行 (run-local)
# =====================================

run-local:
	@echo "=== Start pprof capture (background) ==="; \
	$(MAKE) pprof-capture-bg || { \
		echo "❌ pprof capture failed to start"; \
		exit 1; \
	}; \
	$(MAKE) pprof-capture-wait || { \
		echo "❌ pprof capture not ready"; \
		$(MAKE) pprof-capture-stop; \
		exit 1; \
	}; \
	OUT_FILE="$(CAPTURE_LAST_DIR_FILE)"; \
	if [ ! -f "$$OUT_FILE" ]; then \
		echo "❌ pprof output dir file not found: $$OUT_FILE"; \
		$(MAKE) pprof-capture-stop; \
		exit 1; \
	fi; \
	DIR=$$(cat "$$OUT_FILE"); \
	if [ -z "$$DIR" ]; then \
		echo "❌ pprof output dir file is empty: $$OUT_FILE"; \
		$(MAKE) pprof-capture-stop; \
		exit 1; \
	fi; \
	echo "=== Run $(SCENARIO) ==="; \
	$(MAKE) "$(SCENARIO)" 2>&1 | tee "$$DIR/scenario.log"; \
	SCENARIO_EXIT=$${PIPESTATUS[0]}; \
	if [ "$$SCENARIO_EXIT" -ne 0 ]; then \
		echo "❌ Scenario failed (exit=$$SCENARIO_EXIT)"; \
		$(MAKE) pprof-capture-stop; \
		exit 1; \
	fi; \
	echo "=== Stop pprof capture ==="; \
	$(MAKE) pprof-capture-stop; \
	echo "=== Export metrics & images ==="; \
	python3 scripts/export_grafana_metrics.py \
		--duration $(EXPORT_DURATION) --step 15 --images \
		--output "$$DIR/metrics" \
		--image-output "$$DIR/images"; \
	echo "=== Peak profile ==="; \
	PRINT_ONLY=1 bash scripts/pprof_peak_diff.sh "$$DIR/pprof"

# =====================================
# シナリオ統合実行 (run-*)
# =====================================
.PHONY: run-local run-scenario run-scenario-spanmetrics run-scenario-spanmetrics-optimized run-tail-sampling run-tail-sampling-optimized run-batch-queue run-batch-queue-optimized

run-scenario:
	@if [ -z "$(PROJECT_ID)" ]; then \
		echo "❌ PROJECT_ID is not set. Run: export PROJECT_ID=\$$(gcloud config get-value project)"; \
		exit 1; \
	fi; \
	if [ "$(APPLY)" = "1" ]; then \
		echo "=== Terraform apply ==="; \
		PROJECT_ID="$(PROJECT_ID)" make -C terraform apply; \
	else \
		echo "=== Skipping Terraform apply (APPLY=0) ==="; \
	fi; \
	if [ "$(SYNC)" = "1" ]; then \
		echo "=== Sync project to VM ==="; \
		PROJECT_ID="$(PROJECT_ID)" make -C terraform sync; \
	fi; \
	if [ "$(RESTART)" = "1" ]; then \
		echo "=== Restart services on VM ==="; \
		PROJECT_ID="$(PROJECT_ID)" make -C terraform restart; \
	fi; \
	if [ "$(SCENARIO)" = "scenario-spanmetrics" ] || [ "$(SCENARIO)" = "scenario-spanmetrics-optimized" ]; then \
		echo "=== Prepare pyloadgen (pip install) ==="; \
		PROJECT_ID="$(PROJECT_ID)" make -C terraform prepare-pyloadgen; \
	fi; \
	echo "=== Start port-forward (background) ==="; \
	echo "    Grafana:    http://localhost:3000"; \
	echo "    Prometheus: http://localhost:9090"; \
	echo "    Jaeger:     http://localhost:16686"; \
	echo "    pprof:      http://localhost:$(PPROF_TUNNEL_PORT)/debug/pprof/"; \
	PROJECT_ID="$(PROJECT_ID)" make -C terraform forward-bg PPROF_TUNNEL_PORT="$(PPROF_TUNNEL_PORT)"; \
	echo "=== Start pprof capture (background) ==="; \
	make pprof-capture-bg || { \
		echo "❌ pprof capture failed to start"; \
		PROJECT_ID="$(PROJECT_ID)" make -C terraform forward-stop; \
		exit 1; \
	}; \
	make pprof-capture-wait || { \
		echo "❌ pprof capture not ready"; \
		make pprof-capture-stop; \
		PROJECT_ID="$(PROJECT_ID)" make -C terraform forward-stop; \
		exit 1; \
	}; \
	DIR=$$(cat "$(CAPTURE_LAST_DIR_FILE)"); \
	DSTATS_LOG="$$DIR/docker-stats-capture.log"; \
	echo "=== Start docker stats capture ===" | tee "$$DSTATS_LOG"; \
	PROJECT_ID="$(PROJECT_ID)" make -C terraform docker-stats-start 2>&1 | tee -a "$$DSTATS_LOG" || echo "⚠️  docker stats capture start failed" | tee -a "$$DSTATS_LOG"; \
	echo "=== Run $(SCENARIO) ==="; \
	PROJECT_ID="$(PROJECT_ID)" make -C terraform "$(SCENARIO)" 2>&1 | tee "$$DIR/scenario.log"; \
	SCENARIO_EXIT=$${PIPESTATUS[0]}; \
	if [ "$$SCENARIO_EXIT" -ne 0 ]; then \
		echo "❌ Scenario failed (exit=$$SCENARIO_EXIT)"; \
		PROJECT_ID="$(PROJECT_ID)" make -C terraform docker-stats-stop 2>&1 | tee -a "$$DSTATS_LOG" || true; \
		make pprof-capture-stop; \
		PROJECT_ID="$(PROJECT_ID)" make -C terraform forward-stop; \
		exit 1; \
	fi; \
	echo "=== Stop docker stats capture ===" | tee -a "$$DSTATS_LOG"; \
	PROJECT_ID="$(PROJECT_ID)" make -C terraform docker-stats-stop 2>&1 | tee -a "$$DSTATS_LOG" || echo "⚠️  docker stats capture stop failed" | tee -a "$$DSTATS_LOG"; \
	if [ -n "$$DIR" ]; then \
		PROJECT_ID="$(PROJECT_ID)" make -C terraform docker-stats-fetch DOCKER_STATS_DEST="$(CURDIR)/$$DIR" 2>&1 | tee -a "$$DSTATS_LOG" || echo "⚠️  docker stats fetch failed" | tee -a "$$DSTATS_LOG"; \
	fi; \
	echo "=== Stop background processes ==="; \
	make pprof-capture-stop; \
	echo "=== Export metrics & images ==="; \
	DIR=$$(cat "$(CAPTURE_LAST_DIR_FILE)"); \
	if [ -n "$$DIR" ]; then \
		python3 scripts/export_grafana_metrics.py \
			--duration $(EXPORT_DURATION) --step 15 --images \
			--output "$$DIR/metrics" \
			--image-output "$$DIR/images"; \
	else \
		echo "⚠️  pprof output dir not found, skipping metrics export"; \
	fi; \
	PROJECT_ID="$(PROJECT_ID)" make -C terraform forward-stop; \
	OUT_FILE="$(CAPTURE_LAST_DIR_FILE)"; \
	if [ ! -f "$$OUT_FILE" ]; then \
		echo "❌ pprof output dir file not found: $$OUT_FILE"; \
		exit 1; \
	fi; \
	DIR=$$(cat "$$OUT_FILE"); \
	if [ -z "$$DIR" ]; then \
		echo "❌ pprof output dir file is empty: $$OUT_FILE"; \
		exit 1; \
	fi; \
	echo "=== Peak profile ==="; \
	PRINT_ONLY=1 bash scripts/pprof_peak_diff.sh "$$DIR/pprof"

run-scenario-spanmetrics:
	$(MAKE) run-scenario SCENARIO=scenario-spanmetrics

run-scenario-spanmetrics-optimized:
	$(MAKE) run-scenario SCENARIO=scenario-spanmetrics-optimized

run-tail-sampling:
	$(MAKE) run-scenario SCENARIO=scenario-tail-sampling

run-tail-sampling-optimized:
	$(MAKE) run-scenario SCENARIO=scenario-tail-sampling-optimized

run-batch-queue:
	$(MAKE) run-scenario SCENARIO=scenario-batch-queue EXPORT_DURATION=$(EXPORT_DURATION_BQ)

run-batch-queue-optimized:
	$(MAKE) run-scenario SCENARIO=scenario-batch-queue-optimized EXPORT_DURATION=$(EXPORT_DURATION_BQ)
