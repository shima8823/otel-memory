# 現在のフロー
# make re
# make sync
# make restart
# make scenario-1
# make grafana
# make pprof
# cd ../ && make pprof-heap

.PHONY: set-project-id ssh grafana pprof forward forward-bg forward-stop forward-status sync restart loadgen-ssh loadgen scenario-1

# --- terraform ---

# --- 設定 ---
ZONE = asia-northeast1-a
INSTANCE_NAME = otel-collector
GIT_BRANCH = $(shell git rev-parse --abbrev-ref HEAD)
TAR_PATH ?= /tmp/otel-memory-project.tar.gz

set-project-id:
	@if [ -z "$(PROJECT_ID)" ]; then \
		echo "PROJECT_ID is not set. Please run the following command to set it:"; \
		echo "export PROJECT_ID=\$$(gcloud config get-value project)"; \
		exit 1; \
	fi

# Terraform実行時にブランチ名を渡す
# 使用例: make re (再構築) または make tf-apply (適用)
tf-apply: set-project-id
	terraform apply -var="project_id=$(PROJECT_ID)" -var="git_branch=$(GIT_BRANCH)" -auto-approve
destroy: set-project-id
	terraform destroy -var="project_id=$(PROJECT_ID)" -auto-approve

re: set-project-id
	terraform destroy -var="project_id=$(PROJECT_ID)" -auto-approve && \
	terraform apply -var="project_id=$(PROJECT_ID)" -var="git_branch=$(GIT_BRANCH)" -auto-approve

ssh: set-project-id
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE)

grafana: set-project-id
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- -NL 3000:localhost:3000

pprof: set-project-id
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- -NL 1777:localhost:1777

# Grafana / Prometheus / Jaeger / pprof をまとめてポートフォワード
forward: set-project-id
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		-NL 3000:localhost:3000 \
		-NL 9090:localhost:9090 \
		-NL 16686:localhost:16686 \
		-NL 1777:localhost:1777

# バックグラウンドでまとめてポートフォワード
FORWARD_PID_FILE ?= ../.forward.pid
FORWARD_LOG_FILE ?= ../notes/pprof-logs/port_forward.log

forward-bg: set-project-id
	@mkdir -p ../notes/pprof-logs
	@if [ -f "$(FORWARD_PID_FILE)" ] && kill -0 "$$(cat $(FORWARD_PID_FILE))" 2>/dev/null; then \
		echo "✅ Port-forward already running (pid=$$(cat $(FORWARD_PID_FILE)))"; \
		exit 0; \
	fi
	@nohup gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		-NL 3000:localhost:3000 \
		-NL 9090:localhost:9090 \
		-NL 16686:localhost:16686 \
		-NL 1777:localhost:1777 \
		> "$(FORWARD_LOG_FILE)" 2>&1 & echo $$! > "$(FORWARD_PID_FILE)"
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
# プロジェクト全体を VM に同期
sync: set-project-id
	@echo "🚀 Syncing local project to VM..."
	@rm -f "$(TAR_PATH)"
	# 以前の書き方だと --exclude がうまく動かなかったので修正
	tar -czf "$(TAR_PATH)" \
		--exclude='.git' \
		--exclude='.terraform' \
		--exclude='*.tfstate*' \
		-C .. .
	gcloud compute scp "$(TAR_PATH)" $(INSTANCE_NAME):~/project.tar.gz --project $(PROJECT_ID) --zone $(ZONE)
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"sudo mkdir -p /home/ubuntu/otel-memory && \
		 sudo tar -xzf ~/project.tar.gz -C /home/ubuntu/otel-memory && \
		 sudo chown -R ubuntu:ubuntu /home/ubuntu/otel-memory && \
		 rm ~/project.tar.gz"
	@rm -f "$(TAR_PATH)" project.tar.gz
	@echo "✅ Sync completed!"

# コンテナを再起動（設定変更やポートの追加を反映）
restart: set-project-id
	@echo "🔄 Recreating containers to apply changes..."
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"cd /home/ubuntu/otel-memory && sudo docker-compose up -d --force-recreate"
	@echo "✅ All services are up-to-date and running!"

# --- 負荷試験のヘルパー ---
GET_COLLECTOR_IP = gcloud compute instances describe $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) --format='get(networkInterfaces[0].networkIP)'

loadgen-ssh: set-project-id
	gcloud compute ssh otel-loadgen --project $(PROJECT_ID) --zone $(ZONE)

# 負荷試験の実行
# 例: make loadgen SCENARIO=spike DURATION=180s
SCENARIO ?= sustained
DURATION ?= 60s
loadgen: set-project-id
	@IP=$$($(GET_COLLECTOR_IP)); \
	gcloud compute ssh otel-loadgen --project $(PROJECT_ID) --zone $(ZONE) -- \
		"cd /home/ubuntu/otel-memory/loadgen && ./loadgen -endpoint $$IP:4317 -scenario $(SCENARIO) -duration $(DURATION)"

# --- シナリオ実行 (Distributed) ---

# シナリオ1: 下流停止 (Jaeger停止によるメモリ蓄積の観測)
scenario-1: set-project-id
	@echo "=== Scenario 1: Downstream Failure (Jaeger Stop) ==="
	@IP=$$($(GET_COLLECTOR_IP)); \
	echo "1. Applying scenario-1 config to Collector VM (IP: $$IP)..."; \
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"sudo chown -R ubuntu:ubuntu /home/ubuntu/otel-memory && \
		 sudo cp /home/ubuntu/otel-memory/otel-collector/scenarios/scenario-1.yaml /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml && \
		 cd /home/ubuntu/otel-memory && sudo docker-compose up -d --force-recreate otel-collector"; \
	echo "2. Starting load from Loadgen VM..."; \
	gcloud compute ssh otel-loadgen --project $(PROJECT_ID) --zone $(ZONE) -- \
		"cd /home/ubuntu/otel-memory/loadgen && ./loadgen -endpoint $$IP:4317 -scenario sustained -duration 180s -rate 12000" & \
	LOADGEN_PID=$$!; \
	echo "⏳ Waiting 30s before stopping Jaeger..."; sleep 30; \
	\
	echo "3. 🛑 Stopping Jaeger on Collector VM..."; \
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- "sudo docker-compose -f /home/ubuntu/otel-memory/docker-compose.yaml stop jaeger"; \
	\
	echo "⏳ Observing for 60s..."; sleep 60; \
	\
	echo "4. 🔄 Starting Jaeger on Collector VM..."; \
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- "sudo docker-compose -f /home/ubuntu/otel-memory/docker-compose.yaml start jaeger"; \
	\
	echo "5. Restoring Collector config..."; \
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"sudo chown -R ubuntu:ubuntu /home/ubuntu/otel-memory && \
		 git -C /home/ubuntu/otel-memory restore otel-collector/otel-collector.yaml && \
		 cd /home/ubuntu/otel-memory && sudo docker-compose up -d --force-recreate otel-collector"; \
	\
	echo "✅ Scenario-1 completed. Waiting for loadgen to finish..."; \
	wait $$LOADGEN_PID
