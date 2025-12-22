# OTel Collector Memory 負荷テスト環境
# =====================================

.PHONY: help build up down restart logs status clean
.PHONY: load-burst load-sustained load-spike load-rampup load-light load-stop
.PHONY: scenario-1 scenario-2 scenario-3 scenario-4 scenario-5 scenario-6 scenario-7 scenario-8 scenario-9 scenario-10
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
	@echo "=== シナリオ別負荷テスト (scenario.md 参照) ==="
	@echo "  scenario-1      - 下流停止（Jaeger停止 + load-sustained）"
	@echo "  scenario-2      - スパイク（通常↔高負荷を交互）"
	@echo "  scenario-3      - キャパシティ不足（burst全力送信）"
	@echo "  scenario-4      - メモリリーク検出（長時間sustained）"
	@echo "  scenario-5      - 巨大ペイロード（大きな属性）"
	@echo "  scenario-6      - 高カーディナリティ（UUID属性）"
	@echo "  scenario-7      - ネットワーク不安定（Jaeger pause/unpause）"
	@echo "  scenario-8      - CPU制限下テスト"
	@echo "  scenario-9      - ログ大量送信"
	@echo "  scenario-10     - 設定ミス再現（要: Collector設定変更）"
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
# シナリオ別負荷テスト (scenario.md 参照)
# =====================================

# シナリオ1: 下流（バックエンド）の遅延・停止
# 手順: 1) このコマンドを実行 2) 別ターミナルで `docker compose stop jaeger`
scenario-1: build
	@echo "========================================"
	@echo "シナリオ1: 下流（バックエンド）の遅延・停止"
	@echo "========================================"
	@echo "📌 設定ファイルを切り替えています..."
	@cp otel-collector/scenarios/scenario-1.yaml otel-collector/otel-collector.yaml
	@docker compose restart otel-collector
	@echo "✅ 設定ファイル適用完了（Queue Size: 50000, Consumer: 1）"
	@echo ""
	@echo "📌 手順:"
	@echo "  1. このターミナルで負荷が開始されます"
	@echo "  2. 別ターミナルで実行: docker compose stop jaeger"
	@echo "  3. Grafana で Queue Size, Failure Rate を観察"
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

# シナリオ2: 突発的な入力過多（スパイク）
scenario-2: build
	@echo "========================================"
	@echo "シナリオ2: 突発的な入力過多（スパイク）"
	@echo "========================================"
	@echo "📌 10秒ごとに通常負荷と高負荷（10倍）を切り替え"
	@echo "========================================"
	$(LOADGEN) \
		-endpoint $(ENDPOINT) \
		-scenario spike \
		-duration 180s \
		-rate 20000 \
		-workers 20 \
		-attr-size 64 \
		-attr-count 10 \
		-depth 5

# シナリオ3: 慢性的な入力過多（キャパシティ不足）
scenario-3: build
	@echo "========================================"
	@echo "シナリオ3: 慢性的な入力過多（キャパシティ不足）"
	@echo "========================================"
	@echo "📌 設定ファイルを切り替えています..."
	@cp otel-collector/scenarios/scenario-3.yaml otel-collector/otel-collector.yaml
	@docker compose restart otel-collector
	@echo "✅ 設定ファイル適用完了（Memory Limit: 64MiB, Batch Size: 512）"
	@echo ""
	@echo "📌 memory_limiter の limit_mib に到達するまで全力送信"
	@echo "========================================"
	$(LOADGEN) \
		-endpoint $(ENDPOINT) \
		-scenario burst \
		-duration 180s \
		-workers 50 \
		-attr-size 128 \
		-attr-count 15 \
		-depth 8

# シナリオ4: メモリリーク検出（長時間sustained）
scenario-4: build
	@echo "========================================"
	@echo "シナリオ4: メモリリーク（またはProcessorのバグ）検出"
	@echo "========================================"
	@echo "📌 設定ファイルを切り替えています..."
	@cp otel-collector/scenarios/scenario-4.yaml otel-collector/otel-collector.yaml
	@docker compose restart otel-collector
	@echo "✅ 設定ファイル適用完了（Memory Limit: 1024MiB, groupbyattrs Processor追加）"
	@echo ""
	@echo "📌 10分間の安定負荷でRSSの推移を観察"
	@echo "   RSS が右肩上がりなら要調査"
	@echo "========================================"
	$(LOADGEN) \
		-endpoint $(ENDPOINT) \
		-scenario sustained \
		-duration 600s \
		-rate 3000 \
		-workers 10 \
		-attr-size 64 \
		-attr-count 10 \
		-depth 3

# シナリオ5: 巨大なペイロード（Giant Spans/Logs）
scenario-5: build
	@echo "========================================"
	@echo "シナリオ5: 巨大なペイロード（Giant Spans）"
	@echo "========================================"
	@echo "📌 1スパンあたり大きな属性を持つ"
	@echo "   スパン数は少ないがメモリ消費大"
	@echo "========================================"
	$(LOADGEN) \
		-endpoint $(ENDPOINT) \
		-scenario sustained \
		-duration 120s \
		-rate 500 \
		-workers 5 \
		-attr-size 10000 \
		-attr-count 30 \
		-depth 3

# シナリオ6: Attributes爆発（High Cardinality）
scenario-6: build
	@echo "========================================"
	@echo "シナリオ6: Attributes爆発（High Cardinality）"
	@echo "========================================"
	@echo "📌 設定ファイルを切り替えています..."
	@cp otel-collector/scenarios/scenario-6.yaml otel-collector/otel-collector.yaml
	@docker compose restart otel-collector
	@echo "✅ 設定ファイル適用完了（groupbytrace Processor追加, Batch Size: 16384）"
	@echo ""
	@echo "📌 各スパンにユニークなUUIDを含む属性を付与"
	@echo "   groupbytrace Processorで効果大"
	@echo "========================================"
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

# シナリオ7: ネットワーク不安定（Flapping）
# 自動化スクリプト: Jaeger を pause/unpause
scenario-7: build
	@echo "========================================"
	@echo "シナリオ7: ネットワーク不安定（Flapping）"
	@echo "========================================"
	@echo "📌 10秒ごとにJaegerをpause/unpauseして接続不安定を再現"
	@echo "========================================"
	@# バックグラウンドでflappingを実行
	@( \
		for i in 1 2 3 4 5 6 7 8 9 10; do \
			echo "[FLAP] Pausing Jaeger..."; \
			docker compose pause jaeger 2>/dev/null; \
			sleep 10; \
			echo "[FLAP] Unpausing Jaeger..."; \
			docker compose unpause jaeger 2>/dev/null; \
			sleep 10; \
		done \
	) &
	$(LOADGEN) \
		-endpoint $(ENDPOINT) \
		-scenario sustained \
		-duration 200s \
		-rate 5000 \
		-workers 10 \
		-attr-size 64 \
		-attr-count 10 \
		-depth 3

# シナリオ8: CPUスタベーション
# 注意: docker-compose.yaml でCPU制限を設定する必要あり
scenario-8: build
	@echo "========================================"
	@echo "シナリオ8: CPUスタベーション（処理遅延）"
	@echo "========================================"
	@echo "📌 前提: docker-compose.yaml で otel-collector に"
	@echo "        cpus: 0.2 などのCPU制限を設定してください"
	@echo ""
	@echo "例:"
	@echo "  otel-collector:"
	@echo "    deploy:"
	@echo "      resources:"
	@echo "        limits:"
	@echo "          cpus: '0.2'"
	@echo "========================================"
	@sleep 3
	$(LOADGEN) \
		-endpoint $(ENDPOINT) \
		-scenario burst \
		-duration 120s \
		-workers 30 \
		-attr-size 64 \
		-attr-count 10 \
		-depth 5

# シナリオ9: ログ大量送信
scenario-9: build
	@echo "========================================"
	@echo "シナリオ9: ログ大量送信"
	@echo "========================================"
	@echo "📌 Traces + Logs を同時に大量送信"
	@echo "========================================"
	$(LOADGEN) \
		-endpoint $(ENDPOINT) \
		-scenario sustained \
		-duration 180s \
		-rate 5000 \
		-workers 10 \
		-attr-size 256 \
		-attr-count 10 \
		-depth 3 \
		-logs

# シナリオ10: 設定変更ミス（不適切なバッチ設定）
scenario-10: build
	@echo "========================================"
	@echo "シナリオ10: 設定変更ミス（不適切なバッチ設定）"
	@echo "========================================"
	@echo "📌 前提: otel-collector.yaml の batch を以下に変更:"
	@echo ""
	@echo "  batch:"
	@echo "    send_batch_size: 100000"
	@echo "    send_batch_max_size: 200000"
	@echo "    timeout: 60s"
	@echo ""
	@echo "📌 変更後: make restart-collector"
	@echo "========================================"
	@sleep 3
	$(LOADGEN) \
		-endpoint $(ENDPOINT) \
		-scenario sustained \
		-duration 180s \
		-rate 10000 \
		-workers 20 \
		-attr-size 128 \
		-attr-count 15 \
		-depth 5

# =====================================
# 基本負荷テスト (loadgen)
# =====================================

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
# 設定管理
# =====================================

# 設定ファイルのリセット（デフォルトに戻す）
reset-config:
	@echo "📌 設定ファイルをデフォルトに戻しています..."
	@cp otel-collector/otel-collector.yaml.backup otel-collector/otel-collector.yaml
	@docker compose restart otel-collector
	@echo "✅ 設定ファイルリセット完了"

# 現在の設定ファイルを確認
show-config:
	@echo "=== Current Configuration ==="
	@head -20 otel-collector/otel-collector.yaml
	@echo "..."

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
