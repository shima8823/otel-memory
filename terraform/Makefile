# 現在のフロー
# make re
# make sync
# make restart
# make scenario-1
# make grafana
# make pprof
# cd ../ && make pprof-heap

.PHONY: set-project-id ssh grafana pprof forward forward-bg forward-stop forward-status forward-pprof forward-pprof-bg forward-pprof-stop forward-pprof-status sync sync-loadgen restart rebuild-loadgen prepare-high-cardinality-metrics sync-and-rebuild loadgen-ssh loadgen scenario-1 scenario-2 wait-collector wait-loadgen

# --- terraform ---

# --- 設定 ---
ZONE = asia-northeast1-a
INSTANCE_NAME = otel-collector
GIT_BRANCH = $(shell git rev-parse --abbrev-ref HEAD)
TAR_PATH ?= /tmp/otel-memory-project.tar.gz
WAIT_RETRIES ?= 30
WAIT_INTERVAL ?= 5
PPROF_TUNNEL_PORT ?= 1777
SCENARIO_FILE_1 := scenario-1.yaml
SCENARIO_FILE_2 := high-cardinality-spanmetrics.yaml

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

grafana: set-project-id
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- -NL 3000:localhost:3000

pprof: set-project-id
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- -NL $(PPROF_TUNNEL_PORT):localhost:1777

# Grafana / Prometheus / Jaeger / pprof をまとめてポートフォワード
forward: set-project-id
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		-NL 3000:localhost:3000 \
		-NL 9090:localhost:9090 \
		-NL 16686:localhost:16686 \
		-NL $(PPROF_TUNNEL_PORT):localhost:1777

# バックグラウンドでまとめてポートフォワード
FORWARD_PID_FILE ?= ../.forward.pid
FORWARD_LOG_FILE ?= ../pprof/logs/port_forward.log

forward-bg: set-project-id
	@mkdir -p ../pprof/logs
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

# pprof only (avoid local port conflicts)
FORWARD_PPROF_PID_FILE ?= ../.forward_pprof.pid
FORWARD_PPROF_LOG_FILE ?= ../pprof/logs/port_forward_pprof.log

forward-pprof: set-project-id
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		-NL $(PPROF_TUNNEL_PORT):localhost:1777

forward-pprof-bg: set-project-id
	@mkdir -p ../pprof/logs
	@PORT_PID=$$(lsof -ti tcp:$(PPROF_TUNNEL_PORT) 2>/dev/null || true); \
	if [ -n "$$PORT_PID" ]; then \
		echo "⚠️  Local port $(PPROF_TUNNEL_PORT) is in use (pid=$$PORT_PID). Killing..."; \
		kill $$PORT_PID 2>/dev/null || true; \
		sleep 1; \
	fi
	@if [ -f "$(FORWARD_PPROF_PID_FILE)" ] && kill -0 "$$(cat $(FORWARD_PPROF_PID_FILE))" 2>/dev/null; then \
		echo "✅ Port-forward (pprof) already running (pid=$$(cat $(FORWARD_PPROF_PID_FILE)))"; \
		exit 0; \
	fi
	@nohup gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		-o ExitOnForwardFailure=yes \
		-o ServerAliveInterval=30 \
		-o ServerAliveCountMax=3 \
		-NL $(PPROF_TUNNEL_PORT):localhost:1777 \
		> "$(FORWARD_PPROF_LOG_FILE)" 2>&1 & echo $$! > "$(FORWARD_PPROF_PID_FILE)"
	@sleep 1; \
	PID=$$(cat "$(FORWARD_PPROF_PID_FILE)"); \
	if ! kill -0 $$PID 2>/dev/null; then \
		echo "❌ Port-forward (pprof) failed to start"; \
		if [ -f "$(FORWARD_PPROF_LOG_FILE)" ]; then tail -n 20 "$(FORWARD_PPROF_LOG_FILE)"; fi; \
		exit 1; \
	fi
	@echo "✅ Port-forward (pprof) started (pid=$$(cat $(FORWARD_PPROF_PID_FILE)))"

forward-pprof-stop:
	@if [ ! -f "$(FORWARD_PPROF_PID_FILE)" ]; then \
		echo "ℹ️  Port-forward (pprof) not running (no pid file)"; \
		exit 0; \
	fi
	@PID=$$(cat "$(FORWARD_PPROF_PID_FILE)"); \
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
			echo "❌ Port-forward (pprof) still running (pid=$$PID)"; \
			exit 1; \
		fi; \
		echo "✅ Port-forward (pprof) stopped (pid=$$PID)"; \
	else \
		echo "ℹ️  Port-forward (pprof) pid not running (pid=$$PID)"; \
	fi
	@rm -f "$(FORWARD_PPROF_PID_FILE)"

forward-pprof-status:
	@if [ -f "$(FORWARD_PPROF_PID_FILE)" ] && kill -0 "$$(cat $(FORWARD_PPROF_PID_FILE))" 2>/dev/null; then \
		echo "✅ Port-forward (pprof) running (pid=$$(cat $(FORWARD_PPROF_PID_FILE)))"; \
	else \
		echo "ℹ️  Port-forward (pprof) not running"; \
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
	tar -czf "$(TAR_PATH)" \
		--exclude='.git' \
		--exclude='.terraform' \
		--exclude='*.tfstate*' \
		-C .. .
	gcloud compute scp "$(TAR_PATH)" otel-loadgen:~/project.tar.gz --project $(PROJECT_ID) --zone $(ZONE)
	gcloud compute ssh otel-loadgen --project $(PROJECT_ID) --zone $(ZONE) -- \
		"sudo mkdir -p /home/ubuntu/otel-memory && \
		 sudo tar -xzf ~/project.tar.gz -C /home/ubuntu/otel-memory && \
		 sudo chown -R ubuntu:ubuntu /home/ubuntu/otel-memory && \
		 rm ~/project.tar.gz"
	@rm -f "$(TAR_PATH)" project.tar.gz
	@echo "✅ Loadgen sync completed!"

# Loadgenをリビルド（新しいフラグを追加した場合など）
rebuild-loadgen: set-project-id wait-loadgen
	@echo "🔨 Rebuilding loadgen on VM..."
	gcloud compute ssh otel-loadgen --project $(PROJECT_ID) --zone $(ZONE) -- \
		"sudo chown -R ubuntu:ubuntu /home/ubuntu/otel-memory/loadgen && \
		 sudo -u ubuntu bash -lc 'cd /home/ubuntu/otel-memory/loadgen && /usr/local/go/bin/go build -buildvcs=false -o loadgen .'"
	@echo "✅ Loadgen rebuilt!"

# syncしてリビルド（コード変更後に使用）
# sync: Collector VM（docker compose用）, sync-loadgen: Loadgen VM（loadgenコード用）
sync-and-rebuild: sync sync-loadgen rebuild-loadgen restart
	@echo "✅ Sync, rebuild, and restart completed!"

# 高カーディナリティメトリクス用の最小準備（Loadgen VMのみ）
prepare-high-cardinality-metrics: sync-loadgen rebuild-loadgen
	@echo "✅ High-cardinality loadgen prep completed!"

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
		 sudo cp /home/ubuntu/otel-memory/otel-collector/scenarios/$(SCENARIO_FILE_1) /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml && \
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

# シナリオ2: Processor 高カーディナリティ（メモリ高騰）
scenario-2: set-project-id
	@echo "=== Scenario 2: Processor High Cardinality (Memory Growth) ==="
	@IP=$$($(GET_COLLECTOR_IP)); \
	echo "1. Applying scenario-2 config to Collector VM (IP: $$IP)..."; \
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"sudo chown -R ubuntu:ubuntu /home/ubuntu/otel-memory && \
		 sudo cp /home/ubuntu/otel-memory/otel-collector/scenarios/$(SCENARIO_FILE_2) /home/ubuntu/otel-memory/otel-collector/otel-collector.yaml && \
		 cd /home/ubuntu/otel-memory && sudo docker-compose up -d --force-recreate otel-collector"; \
	echo "2. Starting load from Loadgen VM (high-cardinality)..."; \
	gcloud compute ssh otel-loadgen --project $(PROJECT_ID) --zone $(ZONE) -- \
		"cd /home/ubuntu/otel-memory/loadgen && ./loadgen -endpoint $$IP:4317 -scenario sustained -duration 300s -rate 8000 -workers 10 -attr-size 128 -attr-count 8 -depth 3 -metrics=false -logs=false -high-cardinality"; \
	echo "3. Restoring Collector config..."; \
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"sudo chown -R ubuntu:ubuntu /home/ubuntu/otel-memory && \
		 git -C /home/ubuntu/otel-memory restore otel-collector/otel-collector.yaml && \
		 cd /home/ubuntu/otel-memory && sudo docker-compose up -d --force-recreate otel-collector"; \
	echo "✅ Scenario-2 completed."
