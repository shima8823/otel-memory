#!/bin/bash
# Startup script for OpenTelemetry Collector debug environment
# This script runs on VM boot and sets up the complete environment

set -e

LOG_FILE="/var/log/startup-script.log"

# ログ関数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "=== Starting VM setup for OpenTelemetry Collector debug environment ==="

# 1. システムアップデート
log "Step 1: System update"
apt-get update -y >> "$LOG_FILE" 2>&1
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y >> "$LOG_FILE" 2>&1

# 2. 必要なパッケージインストール
log "Step 2: Installing required packages"
apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    git \
    make \
    python3 \
    python3-pip \
    jq \
    wget \
    unzip \
    htop \
    vim \
    tree >> "$LOG_FILE" 2>&1

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

# 5. Goインストール（loadgenビルド用）
log "Step 5: Installing Go"
if ! command -v go &> /dev/null; then
    GO_VERSION="1.23.4"
    log "Installing Go version: $GO_VERSION"
    cd /tmp
    wget -q "https://go.dev/dl/go$${GO_VERSION}.linux-amd64.tar.gz" >> "$LOG_FILE" 2>&1
    tar -C /usr/local -xzf "go$${GO_VERSION}.linux-amd64.tar.gz"
    rm "go$${GO_VERSION}.linux-amd64.tar.gz"
    
    # 環境変数設定
    echo 'export PATH=$PATH:/usr/local/go/bin' >> /home/ubuntu/.bashrc
    echo 'export PATH=$PATH:/usr/local/go/bin' >> /home/ubuntu/.profile
    
    # Go modulesディレクトリ設定
    mkdir -p /home/ubuntu/go
    chown -R ubuntu:ubuntu /home/ubuntu/go
    
    log "Go installed successfully"
else
    log "Go already installed"
fi

# 6. Pythonパッケージインストール（メトリクスエクスポート用）
log "Step 6: Installing Python packages"
pip3 install --upgrade pip >> "$LOG_FILE" 2>&1
pip3 install requests >> "$LOG_FILE" 2>&1
log "Python packages installed successfully"

# 7. プロジェクトコードのクローン
log "Step 7: Cloning project repository"
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

# 8. Docker imagesのプリプル（オプション、時間短縮のため）
log "Step 8: Pre-pulling Docker images"
cd /home/ubuntu/otel-memory
if [ -f "docker-compose.yaml" ]; then
    sudo -u ubuntu docker-compose pull >> "$LOG_FILE" 2>&1 || log "WARNING: Could not pre-pull images"
fi

# 9. 準備完了メッセージ
log "Step 9: Creating setup status file"
cat > /home/ubuntu/setup_status.txt <<EOF
=== OpenTelemetry Collector Debug Environment ===
Setup completed at: $(date)

Status: READY

Quick Start:
1. cd ~/otel-memory
2. make up          # Start all services
3. make scenario-1  # Run scenario 1

Web UIs:
- Grafana:    http://$(curl -s http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip -H "Metadata-Flavor: Google"):3000
- Prometheus: http://$(curl -s http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip -H "Metadata-Flavor: Google"):9090
- Jaeger:     http://$(curl -s http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip -H "Metadata-Flavor: Google"):16686

Installed versions:
- Docker: $(docker --version)
- Docker Compose: $(docker-compose --version)
- Go: $(go version 2>/dev/null || echo "Not found in current shell")
- Python3: $(python3 --version)

For more information, see ~/otel-memory/README.md
EOF

chown ubuntu:ubuntu /home/ubuntu/setup_status.txt

log "=== VM setup completed successfully ==="
log "Users can now SSH and run: cat ~/setup_status.txt"

# 10. 最終確認
log "Final check - listing installed tools:"
log "Docker: $(docker --version)"
log "Docker Compose: $(docker-compose --version)"
log "Git: $(git --version)"
log "Python3: $(python3 --version)"
log "Make: $(make --version | head -1)"

exit 0
