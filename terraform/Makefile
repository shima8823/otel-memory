# 現在のフロー
# make re
# make sync
# make restart
# make scenario-tail-sampling
# make grafana
# make pprof
# cd ../ && make pprof-heap

.PHONY: set-project-id ssh forward forward-bg forward-stop forward-status sync sync-loadgen restart prepare-telemetrygen prepare-pyloadgen loadgen-ssh docker-stats-start docker-stats-stop docker-stats-fetch scenario-spanmetrics scenario-spanmetrics-optimized scenario-tail-sampling scenario-tail-sampling-optimized wait-collector wait-loadgen scenario-batch-queue scenario-batch-queue-optimized

# --- terraform ---

# --- 設定 ---
ZONE = asia-northeast1-a
INSTANCE_NAME = otel-collector
GIT_BRANCH = $(shell git rev-parse --abbrev-ref HEAD)
TAR_PATH ?= /tmp/otel-memory-project.tar.gz
WAIT_RETRIES ?= 30
WAIT_INTERVAL ?= 5
PPROF_TUNNEL_PORT ?= 1777
SCENARIO_FILE_SPANMETRICS := high-cardinality-spanmetrics.yaml
SCENARIO_FILE_SPANMETRICS_OPT := high-cardinality-spanmetrics-optimized.yaml
SCENARIO_FILE_TAIL := tail-sampling.yaml
SCENARIO_FILE_TAIL_OPT := tail-sampling-optimized.yaml
SCENARIO_FILE_BQ := batch-queue-amplification.yaml
SCENARIO_FILE_BQ_OPT := batch-queue-amplification-optimized.yaml
include ../config.mk
LOAD_CMD_TAIL = telemetrygen traces --otlp-endpoint $$IP:4317 --otlp-insecure --rate $(TGEN_TAIL_RATE) --duration $(TGEN_TAIL_DURATION) --workers $(TGEN_TAIL_WORKERS) --child-spans $(TGEN_TAIL_CHILD_SPANS)
LOAD_CMD_SPANMETRICS = cd /home/ubuntu/otel-memory && python3 pyloadgen/high_cardinality_traces.py --endpoint $$IP:4317 --rate $(TGEN_SM_RATE) --duration $(TGEN_SM_DURATION) --workers $(TGEN_SM_WORKERS) --attr-count $(TGEN_SM_ATTR_COUNT)
LOAD_CMD_BQ = telemetrygen traces --otlp-endpoint $$IP:4317 --otlp-insecure --rate $(TGEN_BQ_RATE) --duration $(TGEN_BQ_DURATION) --workers $(TGEN_BQ_WORKERS) --child-spans $(TGEN_BQ_CHILD_SPANS) --telemetry-attributes 'padding=\"$(TGEN_BQ_PADDING)\"'
TELEMETRYGEN_VERSION ?= v0.146.0
TELEMETRYGEN_IMAGE := ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:$(TELEMETRYGEN_VERSION)
DOCKER_STATS_LOG := /tmp/docker-stats.log
DOCKER_STATS_PID := /tmp/docker-stats.pid

set-project-id:
	@if [ -z "$(PROJECT_ID)" ]; then \
		echo "PROJECT_ID is not set. Please run the following command to set it:"; \
		echo "export PROJECT_ID=\$$(gcloud config get-value project)"; \
		exit 1; \
	fi

# Terraform実行時にブランチ名を渡す
# 使用例: make re (再構築) または make apply (適用)
apply: set-project-id
	terraform apply -var="project_id=$(PROJECT_ID)" -var="git_branch=$(GIT_BRANCH)" -auto-approve
destroy: set-project-id
	terraform destroy -var="project_id=$(PROJECT_ID)" -auto-approve

re: set-project-id
	terraform destroy -var="project_id=$(PROJECT_ID)" -auto-approve && \
	terraform apply -var="project_id=$(PROJECT_ID)" -var="git_branch=$(GIT_BRANCH)" -auto-approve

ssh: set-project-id
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE)

# Grafana / Prometheus / Jaeger / pprof をまとめてポートフォワード
forward: set-project-id
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		-NL 3000:localhost:3000 \
		-NL 9090:localhost:9090 \
		-NL 16686:localhost:16686 \
		-NL $(PPROF_TUNNEL_PORT):localhost:1777

# バックグラウンドでまとめてポートフォワード
FORWARD_PID_FILE ?= ../.forward.pid
FORWARD_LOG_FILE ?= ../captures/logs/port_forward.log

forward-bg: set-project-id
	@mkdir -p ../captures/logs
	@PORT_PID=$$(lsof -ti tcp:$(PPROF_TUNNEL_PORT) 2>/dev/null || true); \
	if [ -n "$$PORT_PID" ]; then \
		echo "⚠️  Local port $(PPROF_TUNNEL_PORT) is in use (pid=$$PORT_PID). Killing..."; \
		kill $$PORT_PID 2>/dev/null || true; \
		sleep 1; \
	fi
	@if [ -f "$(FORWARD_PID_FILE)" ] && kill -0 "$$(cat $(FORWARD_PID_FILE))" 2>/dev/null; then \
		echo "✅ Port-forward already running (pid=$$(cat $(FORWARD_PID_FILE)))"; \
		exit 0; \
	fi
	@nohup gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		-o ExitOnForwardFailure=yes \
		-o ServerAliveInterval=30 \
		-o ServerAliveCountMax=3 \
		-NL 3000:localhost:3000 \
		-NL 9090:localhost:9090 \
		-NL 16686:localhost:16686 \
		-NL $(PPROF_TUNNEL_PORT):localhost:1777 \
		> "$(FORWARD_LOG_FILE)" 2>&1 & echo $$! > "$(FORWARD_PID_FILE)"
	@sleep 1; \
	PID=$$(cat "$(FORWARD_PID_FILE)"); \
	if ! kill -0 $$PID 2>/dev/null; then \
		echo "❌ Port-forward failed to start"; \
		if [ -f "$(FORWARD_LOG_FILE)" ]; then tail -n 20 "$(FORWARD_LOG_FILE)"; fi; \
		exit 1; \
	fi
	@echo "✅ Port-forward started (pid=$$(cat $(FORWARD_PID_FILE)))"

forward-stop:
	@if [ ! -f "$(FORWARD_PID_FILE)" ]; then \
		echo "ℹ️  Port-forward not running (no pid file)"; \
		exit 0; \
	fi
	@PID=$$(cat "$(FORWARD_PID_FILE)"); \
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
			echo "❌ Port-forward still running (pid=$$PID)"; \
			exit 1; \
		fi; \
		echo "✅ Port-forward stopped (pid=$$PID)"; \
	else \
		echo "ℹ️  Port-forward pid not running (pid=$$PID)"; \
	fi
	@rm -f "$(FORWARD_PID_FILE)"

forward-status:
	@if [ -f "$(FORWARD_PID_FILE)" ] && kill -0 "$$(cat $(FORWARD_PID_FILE))" 2>/dev/null; then \
		echo "✅ Port-forward running (pid=$$(cat $(FORWARD_PID_FILE)))"; \
	else \
		echo "ℹ️  Port-forward not running"; \
	fi

# --- 開発・デバッグ用コマンド ---

# プロジェクト全体を VM に同期（Gitの状態に関わらず、手元の最新ファイルを反映）
sync: set-project-id wait-collector
	@echo "🚀 Syncing local project to VM..."
	@rm -f "$(TAR_PATH)"
	# macOS の ._* ファイル（AppleDouble）を除外
	COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 tar --no-mac-metadata --no-xattrs -czf "$(TAR_PATH)" \
		--exclude='.git' \
		--exclude='.terraform' \
		--exclude='*.tfstate*' \
		--exclude='._*' \
		-C .. .
	gcloud compute scp "$(TAR_PATH)" $(INSTANCE_NAME):~/project.tar.gz --project $(PROJECT_ID) --zone $(ZONE)
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"sudo mkdir -p /home/ubuntu/otel-memory && \
		 sudo tar --warning=no-unknown-keyword -xzf ~/project.tar.gz -C /home/ubuntu/otel-memory && \
		 sudo chown -R ubuntu:ubuntu /home/ubuntu/otel-memory && \
		 rm ~/project.tar.gz"
	@rm -f "$(TAR_PATH)" project.tar.gz
	@echo "✅ Sync completed!"

# VM ready wait (startup-script 完了待ち)
wait-collector: set-project-id
	@echo "⏳ Waiting for collector VM to be ready..."
	@for i in $$(seq 1 $(WAIT_RETRIES)); do \
		if gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) --command "test -f /home/ubuntu/setup_status.txt" >/dev/null 2>&1; then \
			echo "✅ Collector VM ready"; \
			exit 0; \
		fi; \
		echo "  ...waiting ($$i/$(WAIT_RETRIES))"; \
		sleep $(WAIT_INTERVAL); \
	done; \
	echo "❌ Collector VM not ready (setup_status.txt missing)"; \
	exit 1

wait-loadgen: set-project-id
	@echo "⏳ Waiting for loadgen VM to be ready..."
	@for i in $$(seq 1 $(WAIT_RETRIES)); do \
		if gcloud compute ssh otel-loadgen --project $(PROJECT_ID) --zone $(ZONE) --command "test -f /home/ubuntu/setup_status.txt" >/dev/null 2>&1; then \
			echo "✅ Loadgen VM ready"; \
			exit 0; \
		fi; \
		echo "  ...waiting ($$i/$(WAIT_RETRIES))"; \
		sleep $(WAIT_INTERVAL); \
	done; \
	echo "❌ Loadgen VM not ready (setup_status.txt missing)"; \
	exit 1

# コンテナを再起動（設定変更やポートの追加を反映）
restart: wait-collector
	@echo "🔄 Recreating containers to apply changes..."
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"cd /home/ubuntu/otel-memory && sudo docker compose up -d --force-recreate"
	@echo "✅ All services are up-to-date and running!"

# Loadgen VMにプロジェクトを同期（syncはCollector VMのみなので別途必要）
sync-loadgen: set-project-id wait-loadgen
	@echo "🚀 Syncing local project to Loadgen VM..."
	@rm -f "$(TAR_PATH)"
	COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 tar --no-mac-metadata --no-xattrs -czf "$(TAR_PATH)" \
		--exclude='.git' \
		--exclude='.terraform' \
		--exclude='*.tfstate*' \
		--exclude='._*' \
		-C .. .
	gcloud compute scp "$(TAR_PATH)" otel-loadgen:~/project.tar.gz --project $(PROJECT_ID) --zone $(ZONE)
	gcloud compute ssh otel-loadgen --project $(PROJECT_ID) --zone $(ZONE) -- \
		"sudo mkdir -p /home/ubuntu/otel-memory && \
		 sudo tar --warning=no-unknown-keyword -xzf ~/project.tar.gz -C /home/ubuntu/otel-memory && \
		 sudo chown -R ubuntu:ubuntu /home/ubuntu/otel-memory && \
		 rm ~/project.tar.gz"
	@rm -f "$(TAR_PATH)" project.tar.gz
	@echo "✅ Loadgen sync completed!"

# telemetrygen を Loadgen VM にインストール（未インストールの場合のみ）
prepare-telemetrygen: wait-loadgen
	@echo "📦 Ensuring telemetrygen is installed on Loadgen VM..."
	@gcloud compute ssh otel-loadgen --project $(PROJECT_ID) --zone $(ZONE) -- \
		"if command -v telemetrygen &>/dev/null; then \
			echo '✅ telemetrygen already installed'; \
		else \
			echo 'Installing telemetrygen $(TELEMETRYGEN_VERSION) from Docker image...'; \
			sudo docker pull $(TELEMETRYGEN_IMAGE) && \
			sudo docker create --name tgen-tmp $(TELEMETRYGEN_IMAGE) && \
			sudo docker cp tgen-tmp:/telemetrygen /usr/local/bin/telemetrygen && \
			sudo docker rm tgen-tmp && \
			sudo chmod +x /usr/local/bin/telemetrygen && \
			sudo docker rmi $(TELEMETRYGEN_IMAGE) || true && \
			echo '✅ telemetrygen $(TELEMETRYGEN_VERSION) installed'; \
		fi"

# Python loadgen (pyloadgen) の準備
prepare-pyloadgen: sync-loadgen
	@echo "🐍 Installing Python dependencies on Loadgen VM..."
	gcloud compute ssh otel-loadgen --project $(PROJECT_ID) --zone $(ZONE) -- \
		"sudo apt-get install -y python3-pip > /dev/null 2>&1 && \
		 pip3 install --break-system-packages -r /home/ubuntu/otel-memory/pyloadgen/requirements.txt"
	@echo "✅ Python loadgen prep completed!"

# --- 負荷試験のヘルパー ---
GET_COLLECTOR_IP = gcloud compute instances describe $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) --format='get(networkInterfaces[0].networkIP)'

# $(1): シナリオ表示名, $(2): シナリオ設定ファイル名, $(3): Loadgen VM上の負荷コマンド
define run_remote_scenario
	@echo "=== Scenario: $(1) ==="
	@IP=$$($(GET_COLLECTOR_IP)); \
	echo "1. Applying $(2) config to Collector VM (IP: $$IP)..."; \
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"sudo chown -R ubuntu:ubuntu /home/ubuntu/otel-memory && \
		 if [ -f /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml ]; then \
		   sudo cp /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml.bak; \
		 fi && \
		 sudo cp /home/ubuntu/otel-memory/otel-collector/scenarios/$(2) /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml && \
		 cd /home/ubuntu/otel-memory && sudo docker compose up -d --force-recreate otel-collector"; \
	echo "2. Starting load command on Loadgen VM..."; \
	gcloud compute ssh otel-loadgen --project $(PROJECT_ID) --zone $(ZONE) -- \
		"$(3) || true"; \
	echo "3. Restoring Collector config..."; \
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"sudo chown -R ubuntu:ubuntu /home/ubuntu/otel-memory && \
		 if [ -f /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml.bak ]; then \
		   sudo mv /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml.bak /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml; \
		 fi && \
		 cd /home/ubuntu/otel-memory && sudo docker compose up -d --force-recreate otel-collector"; \
	echo "✅ Scenario $(1) completed."
endef

# $(1): シナリオ表示名, $(2): シナリオ設定ファイル名, $(3): Loadgen VM上の負荷コマンド
define run_remote_scenario_bq
	@echo "=== Scenario: $(1) ==="
	@IP=$$($(GET_COLLECTOR_IP)); \
	echo "1. Applying $(2) config to Collector VM (IP: $$IP)..."; \
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"sudo chown -R ubuntu:ubuntu /home/ubuntu/otel-memory && \
		 if [ -f /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml ]; then \
		   sudo cp /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml.bak; \
		 fi && \
		 sudo cp /home/ubuntu/otel-memory/otel-collector/scenarios/$(2) /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml && \
		 cd /home/ubuntu/otel-memory && sudo docker compose up -d --force-recreate otel-collector"; \
	echo "2. Applying Jaeger CPU limit (simulating backend slowdown)..."; \
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"cd /home/ubuntu/otel-memory && sudo docker compose -f docker-compose.yaml -f docker-compose.batch-queue.yaml up -d jaeger"; \
	echo "3. Starting load command on Loadgen VM..."; \
	gcloud compute ssh otel-loadgen --project $(PROJECT_ID) --zone $(ZONE) -- \
		"$(3) || true"; \
	echo "4. Removing Jaeger CPU limit..."; \
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"cd /home/ubuntu/otel-memory && sudo docker compose up -d jaeger"; \
	echo "5. Restoring Collector config..."; \
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"sudo chown -R ubuntu:ubuntu /home/ubuntu/otel-memory && \
		 if [ -f /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml.bak ]; then \
		   sudo mv /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml.bak /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml; \
		 fi && \
		 cd /home/ubuntu/otel-memory && sudo docker compose up -d --force-recreate otel-collector"; \
	echo "✅ Scenario $(1) completed."
endef

loadgen-ssh: set-project-id
	gcloud compute ssh otel-loadgen --project $(PROJECT_ID) --zone $(ZONE)

# --- シナリオ実行 (Distributed) ---

scenario-tail-sampling: wait-collector prepare-telemetrygen
	$(call run_remote_scenario,Tail Sampling,$(SCENARIO_FILE_TAIL),$(LOAD_CMD_TAIL))

scenario-tail-sampling-optimized: wait-collector prepare-telemetrygen
	$(call run_remote_scenario,Tail Sampling Optimized,$(SCENARIO_FILE_TAIL_OPT),$(LOAD_CMD_TAIL))

scenario-spanmetrics: wait-collector prepare-pyloadgen
	$(call run_remote_scenario,SpanMetrics High Cardinality,$(SCENARIO_FILE_SPANMETRICS),$(LOAD_CMD_SPANMETRICS))

scenario-spanmetrics-optimized: wait-collector prepare-pyloadgen
	$(call run_remote_scenario,SpanMetrics Optimized,$(SCENARIO_FILE_SPANMETRICS_OPT),$(LOAD_CMD_SPANMETRICS))

# Docker stats キャプチャ
DOCKER_STATS_DEST ?= .

# VM上で docker stats を2秒間隔でバックグラウンド記録開始
docker-stats-start:
	@echo "📊 Starting docker stats capture on VM..."
	@gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"rm -f $(DOCKER_STATS_LOG) $(DOCKER_STATS_PID) && \
		 nohup bash -c 'while true; do \
		   echo \"=== \$$(date -u +%%Y-%%m-%%dT%%H:%%M:%%S) ===\"; \
		   sudo docker stats --no-stream --format \"table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}\"; \
		   echo; \
		   sleep 2; \
		 done' > $(DOCKER_STATS_LOG) 2>&1 < /dev/null & \
		 echo \$$! > $(DOCKER_STATS_PID) && sleep 1 && \
		 echo \"PID: \$$(cat $(DOCKER_STATS_PID)), lines: \$$(wc -l < $(DOCKER_STATS_LOG))\""
	@echo "✅ docker stats capture started"

# VM上の docker stats キャプチャを停止
docker-stats-stop:
	@echo "📊 Stopping docker stats capture on VM..."
	@gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"if [ -f $(DOCKER_STATS_PID) ]; then \
		   kill \$$(cat $(DOCKER_STATS_PID)) 2>/dev/null || true; \
		   rm -f $(DOCKER_STATS_PID); \
		 fi"
	@echo "✅ docker stats capture stopped"

# VM上の docker stats ログをローカルにコピー
# 使い方: make docker-stats-fetch DOCKER_STATS_DEST=path/to/dir
docker-stats-fetch:
	@echo "📊 Fetching docker stats log from VM..."
	@gcloud compute scp $(INSTANCE_NAME):$(DOCKER_STATS_LOG) $(DOCKER_STATS_DEST)/docker-stats.log \
		--project $(PROJECT_ID) --zone $(ZONE)
	@echo "✅ docker stats log saved to $(DOCKER_STATS_DEST)/docker-stats.log"

scenario-batch-queue: wait-collector prepare-telemetrygen
	$(call run_remote_scenario_bq,Batch x Queue,$(SCENARIO_FILE_BQ),$(LOAD_CMD_BQ))

scenario-batch-queue-optimized: wait-collector prepare-telemetrygen
	$(call run_remote_scenario_bq,Batch x Queue Optimized,$(SCENARIO_FILE_BQ_OPT),$(LOAD_CMD_BQ))
