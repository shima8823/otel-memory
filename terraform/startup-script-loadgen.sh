#!/bin/bash
# Startup script for Loadgen VM
# This script runs on VM boot and sets up the loadgen environment

set -e

LOG_FILE="/var/log/startup-script.log"

# ログ関数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "=== Starting Loadgen VM setup ==="

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
    htop \
    vim >> "$LOG_FILE" 2>&1

# 3. Goインストール（loadgenビルド用）
log "Step 3: Installing Go"
if ! command -v go &> /dev/null; then
    GO_VERSION="1.23.4"
    log "Installing Go version: $GO_VERSION"
    cd /tmp
    curl -fsSL "https://go.dev/dl/go$${GO_VERSION}.linux-amd64.tar.gz" -o "go$${GO_VERSION}.linux-amd64.tar.gz" >> "$LOG_FILE" 2>&1
    tar -C /usr/local -xzf "go$${GO_VERSION}.linux-amd64.tar.gz"
    rm "go$${GO_VERSION}.linux-amd64.tar.gz"
    
    # 環境変数設定
    echo 'export PATH=$PATH:/usr/local/go/bin' >> /home/ubuntu/.bashrc
    echo 'export GOPATH=/home/ubuntu/go' >> /home/ubuntu/.bashrc
    
    # Go modulesディレクトリ設定
    mkdir -p /home/ubuntu/go
    chown -R ubuntu:ubuntu /home/ubuntu/go
    
    log "Go installed successfully"
else
    log "Go already installed"
fi

# 4. プロジェクトコードのクローン
log "Step 4: Cloning project repository"
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
        mkdir -p otel-memory/loadgen
    }
else
    log "WARNING: Invalid or placeholder git_repo_url. Creating empty directory."
    log "Please manually upload your code or configure git_repo_url variable."
    mkdir -p otel-memory/loadgen
fi

chown -R ubuntu:ubuntu otel-memory
log "Project code setup completed"

# 5. loadgenバイナリのビルド
log "Step 5: Building loadgen binary"
cd /home/ubuntu/otel-memory/loadgen

if [ -f "go.mod" ]; then
    export PATH=$PATH:/usr/local/go/bin
    export GOPATH=/home/ubuntu/go
    
    # 依存関係のダウンロード
    sudo -u ubuntu /usr/local/go/bin/go mod download >> "$LOG_FILE" 2>&1 || log "WARNING: go mod download failed"
    
    # ビルド
    sudo -u ubuntu /usr/local/go/bin/go build -o loadgen . >> "$LOG_FILE" 2>&1 || {
        log "WARNING: Failed to build loadgen. You may need to build manually."
    }
    
    if [ -f "loadgen" ]; then
        chmod +x loadgen
        log "loadgen binary built successfully"
    fi
else
    log "WARNING: go.mod not found in loadgen directory. Manual setup required."
fi

chown -R ubuntu:ubuntu /home/ubuntu/otel-memory

# 6. Collector VMの内部IP情報を保存
log "Step 6: Saving Collector VM connection info"
COLLECTOR_IP="${collector_internal_ip}"

cat > /home/ubuntu/collector_info.txt <<EOF
# Collector VM Connection Info
COLLECTOR_INTERNAL_IP=$COLLECTOR_IP
COLLECTOR_ENDPOINT=$COLLECTOR_IP:4317

# Usage example:
# cd ~/otel-memory/loadgen
# ./loadgen -endpoint $COLLECTOR_IP:4317 -scenario sustained -duration 60s
EOF

# 環境変数としても設定
echo "export COLLECTOR_ENDPOINT=$COLLECTOR_IP:4317" >> /home/ubuntu/.bashrc

chown ubuntu:ubuntu /home/ubuntu/collector_info.txt

# 7. 準備完了メッセージ
log "Step 7: Creating setup status file"
cat > /home/ubuntu/setup_status.txt <<EOF
=== Loadgen VM Setup Complete ===
Setup completed at: $(date)

Status: READY

Collector VM Internal IP: $COLLECTOR_IP

Quick Start:
1. cd ~/otel-memory/loadgen
2. ./loadgen -endpoint $COLLECTOR_IP:4317 -scenario sustained -duration 60s

Installed versions:
- Go: $(/usr/local/go/bin/go version 2>/dev/null || echo "Not found")

For more information, see ~/otel-memory/README.md
EOF

chown ubuntu:ubuntu /home/ubuntu/setup_status.txt

log "=== Loadgen VM setup completed successfully ==="
log "Users can now SSH and run: cat ~/setup_status.txt"

# 8. 最終確認
log "Final check - listing installed tools:"
log "Go: $(/usr/local/go/bin/go version 2>/dev/null || echo "Not found")"
log "Git: $(git --version)"
log "Collector IP: $COLLECTOR_IP"

exit 0
