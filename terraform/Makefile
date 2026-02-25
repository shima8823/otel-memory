# 現在のフロー
# make re
# make sync
# make restart
# make scenario-tail-sampling
# make grafana
# make pprof
# cd ../ && make pprof-heap

.PHONY: set-project-id ssh forward forward-bg forward-stop forward-status sync sync-loadgen restart prepare-telemetrygen prepare-pyloadgen loadgen-ssh scenario-spanmetrics scenario-spanmetrics-optimized scenario-tail-sampling scenario-tail-sampling-optimized wait-collector wait-loadgen scenario-batch-queue scenario-batch-queue-optimized

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
TELEMETRYGEN_VERSION ?= v0.146.0
TELEMETRYGEN_IMAGE := ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:$(TELEMETRYGEN_VERSION)

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

loadgen-ssh: set-project-id
	gcloud compute ssh otel-loadgen --project $(PROJECT_ID) --zone $(ZONE)

# --- シナリオ実行 (Distributed) ---

# Tail Sampling（telemetrygen版）
scenario-tail-sampling: wait-collector prepare-telemetrygen
	@echo "=== [tgen] Scenario: Tail Sampling (Time-axis Memory Growth) ==="
	@IP=$$($(GET_COLLECTOR_IP)); \
	echo "1. Applying tail-sampling config to Collector VM (IP: $$IP)..."; \
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"sudo chown -R ubuntu:ubuntu /home/ubuntu/otel-memory && \
		 if [ -f /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml ]; then \
		   sudo cp /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml.bak; \
		 fi && \
		 sudo cp /home/ubuntu/otel-memory/otel-collector/scenarios/$(SCENARIO_FILE_TAIL) /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml && \
		 cd /home/ubuntu/otel-memory && sudo docker compose up -d --force-recreate otel-collector"; \
	echo "2. Starting telemetrygen from Loadgen VM (1500 traces/s)..."; \
	gcloud compute ssh otel-loadgen --project $(PROJECT_ID) --zone $(ZONE) -- \
		"telemetrygen traces --otlp-endpoint $$IP:4317 --otlp-insecure --rate 1500 --duration 120s --workers 10 --child-spans 5 || true"; \
	echo "3. Restoring Collector config..."; \
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"sudo chown -R ubuntu:ubuntu /home/ubuntu/otel-memory && \
		 if [ -f /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml.bak ]; then \
		   sudo mv /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml.bak /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml; \
		 fi && \
		 cd /home/ubuntu/otel-memory && sudo docker compose up -d --force-recreate otel-collector"; \
	echo "✅ [tgen] Scenario-tail-sampling completed."

# Tail Sampling 最適化版（telemetrygen版）
scenario-tail-sampling-optimized: wait-collector prepare-telemetrygen
	@echo "=== [tgen] Scenario: Tail Sampling Optimized ==="
	@IP=$$($(GET_COLLECTOR_IP)); \
	echo "1. Applying tail-sampling-optimized config to Collector VM (IP: $$IP)..."; \
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"sudo chown -R ubuntu:ubuntu /home/ubuntu/otel-memory && \
		 if [ -f /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml ]; then \
		   sudo cp /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml.bak; \
		 fi && \
		 sudo cp /home/ubuntu/otel-memory/otel-collector/scenarios/$(SCENARIO_FILE_TAIL_OPT) /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml && \
		 cd /home/ubuntu/otel-memory && sudo docker compose up -d --force-recreate otel-collector"; \
	echo "2. Starting telemetrygen from Loadgen VM (1500 traces/s, optimized config)..."; \
	gcloud compute ssh otel-loadgen --project $(PROJECT_ID) --zone $(ZONE) -- \
		"telemetrygen traces --otlp-endpoint $$IP:4317 --otlp-insecure --rate 1500 --duration 120s --workers 10 --child-spans 5 || true"; \
	echo "3. Restoring Collector config..."; \
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"sudo chown -R ubuntu:ubuntu /home/ubuntu/otel-memory && \
		 if [ -f /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml.bak ]; then \
		   sudo mv /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml.bak /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml; \
		 fi && \
		 cd /home/ubuntu/otel-memory && sudo docker compose up -d --force-recreate otel-collector"; \
	echo "✅ [tgen] Scenario-tail-sampling-optimized completed."

# シナリオ: spanmetrics 高カーディナリティ [Python + OTel SDK]
# telemetrygen ではランダム属性生成ができないため Python を使用
scenario-spanmetrics: wait-collector prepare-pyloadgen
	@echo "=== [pyloadgen] Scenario 2: Processor High Cardinality (spanmetrics) ==="
	@IP=$$($(GET_COLLECTOR_IP)); \
	echo "1. Applying scenario-spanmetrics config to Collector VM (IP: $$IP)..."; \
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"sudo chown -R ubuntu:ubuntu /home/ubuntu/otel-memory && \
		 if [ -f /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml ]; then \
		   sudo cp /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml.bak; \
		 fi && \
		 sudo cp /home/ubuntu/otel-memory/otel-collector/scenarios/$(SCENARIO_FILE_SPANMETRICS) /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml && \
		 cd /home/ubuntu/otel-memory && sudo docker compose up -d --force-recreate otel-collector"; \
	echo "2. Starting Python load from Loadgen VM (high-cardinality traces)..."; \
	gcloud compute ssh otel-loadgen --project $(PROJECT_ID) --zone $(ZONE) -- \
		"cd /home/ubuntu/otel-memory && python3 pyloadgen/high_cardinality_traces.py --endpoint $$IP:4317 --rate 1300 --duration 300 --workers 10 --attr-count 8 || true"; \
	echo "3. Restoring Collector config..."; \
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"sudo chown -R ubuntu:ubuntu /home/ubuntu/otel-memory && \
		 if [ -f /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml.bak ]; then \
		   sudo mv /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml.bak /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml; \
		 fi && \
		 cd /home/ubuntu/otel-memory && sudo docker compose up -d --force-recreate otel-collector"; \
	echo "✅ [pyloadgen] scenario-spanmetrics completed."

scenario-spanmetrics-optimized: wait-collector prepare-pyloadgen
	@echo "=== [pyloadgen] Scenario 2: Processor High Cardinality (spanmetrics) - OPTIMIZED ==="
	@IP=$$($(GET_COLLECTOR_IP)); \
	echo "1. Applying scenario-spanmetrics config to Collector VM (IP: $$IP)..."; \
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"sudo chown -R ubuntu:ubuntu /home/ubuntu/otel-memory && \
		 if [ -f /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml ]; then \
		   sudo cp /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml.bak; \
		 fi && \
		 sudo cp /home/ubuntu/otel-memory/otel-collector/scenarios/$(SCENARIO_FILE_SPANMETRICS_OPT) /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml && \
		 cd /home/ubuntu/otel-memory && sudo docker compose up -d --force-recreate otel-collector"; \
	echo "2. Starting Python load from Loadgen VM (high-cardinality traces)..."; \
	gcloud compute ssh otel-loadgen --project $(PROJECT_ID) --zone $(ZONE) -- \
		"cd /home/ubuntu/otel-memory && python3 pyloadgen/high_cardinality_traces.py --endpoint $$IP:4317 --rate 1300 --duration 300 --workers 10 --attr-count 8 || true"; \
	echo "3. Restoring Collector config..."; \
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"sudo chown -R ubuntu:ubuntu /home/ubuntu/otel-memory && \
		 if [ -f /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml.bak ]; then \
		   sudo mv /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml.bak /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml; \
		 fi && \
		 cd /home/ubuntu/otel-memory && sudo docker compose up -d --force-recreate otel-collector"; \
	echo "✅ [pyloadgen] scenario-spanmetrics-optimized completed."

# Batch × Queue メモリ増幅（telemetrygen版）
scenario-batch-queue: wait-collector prepare-telemetrygen
	@echo "=== [tgen] Scenario: Batch × Queue Memory Amplification ==="
	@IP=$$($(GET_COLLECTOR_IP)); \
	echo "1. Applying batch-queue config to Collector VM (IP: $$IP)..."; \
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"sudo chown -R ubuntu:ubuntu /home/ubuntu/otel-memory && \
		 if [ -f /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml ]; then \
		   sudo cp /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml.bak; \
		 fi && \
		 sudo cp /home/ubuntu/otel-memory/otel-collector/scenarios/$(SCENARIO_FILE_BQ) /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml && \
		 cd /home/ubuntu/otel-memory && sudo docker compose up -d --force-recreate otel-collector"; \
	echo "2. Stopping Jaeger to simulate downstream failure..."; \
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"sudo docker compose -f /home/ubuntu/otel-memory/docker-compose.yaml stop jaeger"; \
	echo "3. Starting telemetrygen ..."; \
	gcloud compute ssh otel-loadgen --project $(PROJECT_ID) --zone $(ZONE) -- \
		"telemetrygen traces --otlp-endpoint $$IP:4317 --otlp-insecure --rate 2000 --duration 180s --workers 10 --child-spans 3 --telemetry-attributes 'padding=\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"' || true"; \
	echo "4. Restarting Jaeger..."; \
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"sudo docker compose -f /home/ubuntu/otel-memory/docker-compose.yaml start jaeger"; \
	echo "5. Restoring Collector config..."; \
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"sudo chown -R ubuntu:ubuntu /home/ubuntu/otel-memory && \
		 if [ -f /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml.bak ]; then \
		   sudo mv /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml.bak /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml; \
		 fi && \
		 cd /home/ubuntu/otel-memory && sudo docker compose up -d --force-recreate otel-collector"; \
	echo "✅ [tgen] Scenario-batch-queue completed."

# Batch × Queue 最適化版（telemetrygen版）
scenario-batch-queue-optimized: wait-collector prepare-telemetrygen
	@echo "=== [tgen] Scenario: Batch × Queue Optimized ==="
	@IP=$$($(GET_COLLECTOR_IP)); \
	echo "1. Applying batch-queue-optimized config to Collector VM (IP: $$IP)..."; \
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"sudo chown -R ubuntu:ubuntu /home/ubuntu/otel-memory && \
		 if [ -f /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml ]; then \
		   sudo cp /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml.bak; \
		 fi && \
		 sudo cp /home/ubuntu/otel-memory/otel-collector/scenarios/$(SCENARIO_FILE_BQ_OPT) /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml && \
		 cd /home/ubuntu/otel-memory && sudo docker compose up -d --force-recreate otel-collector"; \
	echo "2. Stopping Jaeger to simulate downstream failure..."; \
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"sudo docker compose -f /home/ubuntu/otel-memory/docker-compose.yaml stop jaeger"; \
	echo "3. Starting telemetrygen ..."; \
	gcloud compute ssh otel-loadgen --project $(PROJECT_ID) --zone $(ZONE) -- \
		"telemetrygen traces --otlp-endpoint $$IP:4317 --otlp-insecure --rate 2000 --duration 180s --workers 10 --child-spans 3 --telemetry-attributes 'padding=\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"' || true"; \
	echo "4. Restarting Jaeger..."; \
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"sudo docker compose -f /home/ubuntu/otel-memory/docker-compose.yaml start jaeger"; \
	echo "5. Restoring Collector config..."; \
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"sudo chown -R ubuntu:ubuntu /home/ubuntu/otel-memory && \
		 if [ -f /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml.bak ]; then \
		   sudo mv /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml.bak /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml; \
		 fi && \
		 cd /home/ubuntu/otel-memory && sudo docker compose up -d --force-recreate otel-collector"; \
	echo "✅ [tgen] Scenario-batch-queue-optimized completed."
