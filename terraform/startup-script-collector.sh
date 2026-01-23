#!/bin/bash
# Startup script for Collector VM
# This script runs on VM boot and sets up OTel Collector, Prometheus, Grafana, Jaeger

set -e

LOG_FILE="/var/log/startup-script.log"

# ログ関数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "=== Starting Collector VM setup ==="

# 1. システムアップデート
log "Step 1: System update"
apt-get update -y >> "$LOG_FILE" 2>&1
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y >> "$LOG_FILE" 2>&1

# 2. 必要なパッケージインストール
log "Step 2: Installing required packages"
apt-get install -y \
    ca-certificates \
    curl \
    git \
    make \
    python3 \
    python3-pip \
    python3-requests \
    jq \
    htop \
    vim >> "$LOG_FILE" 2>&1

# 3. Dockerインストール
log "Step 3: Installing Docker"
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh >> "$LOG_FILE" 2>&1
    rm get-docker.sh
    systemctl enable docker
    systemctl start docker
    
    # ubuntuユーザーをdockerグループに追加
    usermod -aG docker ubuntu
    
    log "Docker installed successfully"
else
    log "Docker already installed"
fi

# 4. Docker Composeインストール（最新版）
log "Step 4: Installing Docker Compose"
if ! command -v docker-compose &> /dev/null; then
    COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)
    log "Installing Docker Compose version: $COMPOSE_VERSION"
    curl -L "https://github.com/docker/compose/releases/download/$${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    log "Docker Compose installed successfully"
else
    log "Docker Compose already installed"
fi

# 5. Pythonパッケージインストール（メトリクスエクスポート用）
# 注: Ubuntu 24.04以降はシステムPythonへのpipインストールが制限されているため、
# 前のステップで apt install python3-requests を使用しています
log "Step 5: Python environment check"
python3 -c "import requests; print('requests version:', requests.__version__)" >> "$LOG_FILE" 2>&1
log "Python environment check completed"

# 6. プロジェクトコードのクローン
log "Step 6: Cloning project repository"
cd /home/ubuntu

# 既存ディレクトリがあれば削除
if [ -d "otel-memory" ]; then
    log "Removing existing otel-memory directory"
    rm -rf otel-memory
fi

# Gitリポジトリのクローン
GIT_REPO_URL="${git_repo_url}"
log "Cloning from: $GIT_REPO_URL"

if [[ "$GIT_REPO_URL" == *"github.com"* ]] || [[ "$GIT_REPO_URL" == "https://"* ]]; then
    git clone "$GIT_REPO_URL" otel-memory >> "$LOG_FILE" 2>&1 || {
        log "WARNING: Failed to clone repository. You may need to manually clone or upload the code."
        log "Creating placeholder directory..."
        mkdir -p otel-memory
    }
else
    log "WARNING: Invalid or placeholder git_repo_url. Creating empty directory."
    log "Please manually upload your code or configure git_repo_url variable."
    mkdir -p otel-memory
fi

chown -R ubuntu:ubuntu otel-memory
log "Project code setup completed"

# 7. Docker imagesのプリプル（時間短縮のため）
log "Step 7: Pre-pulling Docker images"
cd /home/ubuntu/otel-memory
if [ -f "docker-compose.yaml" ]; then
    sudo -u ubuntu docker-compose pull >> "$LOG_FILE" 2>&1 || log "WARNING: Could not pre-pull images"
fi

# 8. 準備完了メッセージ
log "Step 8: Creating setup status file"

EXTERNAL_IP=$(curl -s http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip -H "Metadata-Flavor: Google")
INTERNAL_IP=$(curl -s http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip -H "Metadata-Flavor: Google")

cat > /home/ubuntu/setup_status.txt <<EOF
=== Collector VM Setup Complete ===
Setup completed at: $(date)

Status: READY

Network Info:
- External IP: $EXTERNAL_IP
- Internal IP: $INTERNAL_IP (Loadgen VMからの接続先)
- OTLP Endpoint: $INTERNAL_IP:4317

Quick Start:
1. cd ~/otel-memory
2. make up          # Start all services (OTel Collector, Prometheus, Grafana, Jaeger)

Web UIs (access from browser):
- Grafana:    http://$EXTERNAL_IP:3000
- Prometheus: http://$EXTERNAL_IP:9090
- Jaeger:     http://$EXTERNAL_IP:16686

Services in docker-compose:
- otel-collector: Receives OTLP data on port 4317
- prometheus:     Scrapes and stores metrics
- grafana:        Visualizes metrics
- jaeger:         Stores and visualizes traces

Installed versions:
- Docker: $(docker --version)
- Docker Compose: $(docker-compose --version)
- Python3: $(python3 --version)

For more information, see ~/otel-memory/README.md
EOF

chown ubuntu:ubuntu /home/ubuntu/setup_status.txt

log "=== Collector VM setup completed successfully ==="
log "Users can now SSH and run: cat ~/setup_status.txt"

# 9. 最終確認
log "Final check - listing installed tools:"
log "Docker: $(docker --version)"
log "Docker Compose: $(docker-compose --version)"
log "Git: $(git --version)"
log "Python3: $(python3 --version)"
log "Make: $(make --version | head -1)"
log "Internal IP: $INTERNAL_IP"
log "External IP: $EXTERNAL_IP"

# 10. Start services with Docker Compose
log "Step 10: Starting services with Docker Compose"
cd /home/ubuntu/otel-memory
if [ -f "docker-compose.yaml" ]; then
    sudo -u ubuntu docker-compose up -d >> "$LOG_FILE" 2>&1
    log "Docker Compose services started successfully"
else
    log "ERROR: docker-compose.yaml not found, could not start services"
fi

exit 0
