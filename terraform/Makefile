.PHONY: set-project-id ssh grafana pprof sync

# --- terraform ---
re:
	terraform destroy -auto-approve && terraform apply -auto-approve

# --- 設定 ---
ZONE = asia-northeast1-a
INSTANCE_NAME = otel-collector
GIT_BRANCH = $(shell git rev-parse --abbrev-ref HEAD)

set-project-id:
	@if [ -z "$(PROJECT_ID)" ]; then \
		echo "PROJECT_ID is not set. Please run the following command to set it:"; \
		echo "export PROJECT_ID=\$$(gcloud config get-value project)"; \
		exit 1; \
	fi

# Terraform実行時にブランチ名を渡す
tf-apply: set-project-id
	terraform apply -var="project_id=$(PROJECT_ID)" -var="git_branch=$(GIT_BRANCH)" -auto-approve

re: set-project-id
	terraform destroy -var="project_id=$(PROJECT_ID)" -auto-approve && \
	terraform apply -var="project_id=$(PROJECT_ID)" -var="git_branch=$(GIT_BRANCH)" -auto-approve

ssh: set-project-id
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE)

grafana: set-project-id
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- -NL 3000:localhost:3000

pprof: set-project-id
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- -NL 1777:localhost:1777

# --- 開発・デバッグ用コマンド ---

# プロジェクト全体を VM に同期（Gitの状態に関わらず、手元の最新ファイルを反映）
# プロジェクト全体を VM に同期
sync: set-project-id
	@echo "🚀 Syncing local project to VM..."
	@rm -f project.tar.gz
	# 以前の書き方だと --exclude がうまく動かなかったので修正
	tar -czf project.tar.gz \
		--exclude='.git' \
		--exclude='.terraform' \
		--exclude='*.tfstate*' \
		-C .. .
	gcloud compute scp project.tar.gz $(INSTANCE_NAME):~/project.tar.gz --project $(PROJECT_ID) --zone $(ZONE)
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"sudo mkdir -p /home/ubuntu/otel-memory && \
		 sudo tar -xzf ~/project.tar.gz -C /home/ubuntu/otel-memory && \
		 sudo chown -R ubuntu:ubuntu /home/ubuntu/otel-memory && \
		 rm ~/project.tar.gz"
	@rm project.tar.gz
	@echo "✅ Sync completed!"

# コンテナを再起動（設定変更やポートの追加を反映）
restart: set-project-id
	@echo "🔄 Recreating containers to apply changes..."
	gcloud compute ssh $(INSTANCE_NAME) --project $(PROJECT_ID) --zone $(ZONE) -- \
		"cd /home/ubuntu/otel-memory && sudo docker-compose up -d --force-recreate"
	@echo "✅ All services are up-to-date and running!"

# --- loadgen instance ---
# 接続
loadgen-ssh: set-project-id
	gcloud compute ssh otel-loadgen --project $(PROJECT_ID) --zone $(ZONE)

# 負荷試験の実行
# 例: make loadgen SCENARIO=spike DURATION=180s
SCENARIO ?= sustained
DURATION ?= 60s
loadgen: set-project-id
	gcloud compute ssh otel-loadgen --project $(PROJECT_ID) --zone $(ZONE) -- \
		"cd ~/otel-memory/loadgen && ./loadgen -endpoint \$$COLLECTOR_ENDPOINT -scenario $(SCENARIO) -duration $(DURATION)"

	