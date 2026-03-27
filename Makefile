# OTel Collector Memory 負荷テスト環境
# =====================================
SHELL := /bin/bash

# =====================================
# 変数定義
# =====================================

include config.mk

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
DESTROY ?= 1

# === pprof-peak-diff 位置引数対応 ===
ifneq (,$(filter pprof-peak-diff,$(MAKECMDGOALS)))
DIR ?= $(word 2,$(MAKECMDGOALS))
ifneq ($(DIR),)
$(DIR):
	@:
endif
endif

# =====================================
# Help
# =====================================
.PHONY: help help-run help-util help-pprof

help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "詳細: make help-<section>"
	@echo "  help-run       GCP 実行"
	@echo "  help-util      ユーティリティ"
	@echo "  help-pprof     プロファイリング"
	@echo ""
	@echo "=== 主要ターゲット ==="
	@echo "  run-*               GCP 統合シナリオ実行"
	@echo "  pprof-*             プロファイル取得・比較"
	@echo "  export-metrics      Grafana メトリクスと画像をエクスポート"
	@echo ""

help-run:
	@echo "=== GCP 統合実行 ==="
	@echo "  run-scenario                       全自動実行 (SCENARIO=... PROJECT_ID=...)"
	@echo "  run-tail-sampling                  Tail Sampling を実行"
	@echo "  run-tail-sampling-optimized        Tail Sampling 最適化版を実行"
	@echo "  run-scenario-spanmetrics           SpanMetrics 高カーディナリティを実行"
	@echo "  run-scenario-spanmetrics-optimized SpanMetrics 最適化版を実行"
	@echo "  run-batch-queue                    Batch × Queue を実行"
	@echo "  run-batch-queue-optimized          Batch × Queue 最適化版を実行"

help-util:
	@echo "=== ユーティリティ ==="
	@echo "  export-metrics      Grafanaダッシュボードのメトリクスをエクスポート"
	@echo "  clean-metrics       メトリクスエクスポートディレクトリを削除"

help-pprof:
	@echo "=== pprof 基本（ポートフォワード前提） ==="
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
	@echo "  pprof-peak-diff     ピークと直前を比較 (DIR=...)"
	@echo "  pprof-ui            単一のプロファイルを表示 (FILE=...)"
	@echo "  pprof-report        テキストレポート出力 (BASE=... NEW=...)"
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
.PHONY: pprof-diff pprof-diff-stop pprof-list pprof-peak-diff pprof-ui pprof-report

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


pprof-peak-diff:
	@if [ -z "$(DIR)" ]; then echo "❌ Usage: make pprof-peak-diff DIR=path/to/captures/XXXXXX"; exit 1; fi
	@bash scripts/pprof_peak_diff.sh "$(DIR)/pprof"

pprof-report:
	@echo "=== Top 50 Memory Increases ==="
	@go tool pprof -top -nodecount=50 --diff_base $(BASE) $(NEW)
	@echo "\n=== Call Tree ==="
	@go tool pprof -tree -nodecount=30 --diff_base $(BASE) $(NEW)

# =====================================
# シナリオ統合実行 (run-*)
# =====================================
.PHONY: run-scenario run-scenario-spanmetrics run-scenario-spanmetrics-optimized run-tail-sampling run-tail-sampling-optimized run-batch-queue run-batch-queue-optimized

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
		if [ "$(DESTROY)" = "1" ]; then \
			echo "=== Terraform destroy (cleanup after failure) ==="; \
			PROJECT_ID="$(PROJECT_ID)" make -C terraform destroy || true; \
		fi; \
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
	PRINT_ONLY=1 bash scripts/pprof_peak_diff.sh "$$DIR/pprof"; \
	echo "=== Generate pprof call graph ==="; \
	bash scripts/pprof_graph.sh "$$DIR/pprof" "$$DIR/images" || echo "⚠️  pprof graph generation failed (non-fatal)"; \
	if [ "$(DESTROY)" = "1" ]; then \
		echo "=== Terraform destroy ==="; \
		PROJECT_ID="$(PROJECT_ID)" make -C terraform destroy; \
		echo "✅ Infrastructure destroyed."; \
	else \
		echo "=== Skipping Terraform destroy (DESTROY=0) ==="; \
	fi

run-scenario-spanmetrics:
	$(MAKE) run-scenario SCENARIO=scenario-spanmetrics

run-scenario-spanmetrics-optimized:
	$(MAKE) run-scenario SCENARIO=scenario-spanmetrics-optimized

run-tail-sampling:
	$(MAKE) run-scenario SCENARIO=scenario-tail-sampling-buffered EXPORT_DURATION=$(EXPORT_DURATION_TAIL)

run-tail-sampling-optimized:
	$(MAKE) run-scenario SCENARIO=scenario-tail-sampling-buffered-optimized EXPORT_DURATION=$(EXPORT_DURATION_TAIL)

run-batch-queue:
	$(MAKE) run-scenario SCENARIO=scenario-batch-queue EXPORT_DURATION=$(EXPORT_DURATION_BQ)

run-batch-queue-optimized:
	$(MAKE) run-scenario SCENARIO=scenario-batch-queue-optimized EXPORT_DURATION=$(EXPORT_DURATION_BQ)
