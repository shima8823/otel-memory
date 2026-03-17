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

# 3. Docker インストール（telemetrygen バイナリ抽出用）
log "Step 3: Installing Docker"
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh >> "$LOG_FILE" 2>&1
    rm get-docker.sh
    systemctl enable docker
    systemctl start docker
    usermod -aG docker ubuntu
    log "Docker installed successfully"
else
    log "Docker already installed"
fi

# 3.5. telemetrygen インストール（Docker イメージからバイナリ抽出）
log "Step 3.5: Installing telemetrygen from Docker image"
TELEMETRYGEN_VERSION="v0.146.0"
TELEMETRYGEN_IMAGE="ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:$${TELEMETRYGEN_VERSION}"
if ! command -v telemetrygen &> /dev/null; then
    docker pull "$${TELEMETRYGEN_IMAGE}" >> "$LOG_FILE" 2>&1
    docker create --name tgen-tmp "$${TELEMETRYGEN_IMAGE}" >> "$LOG_FILE" 2>&1
    docker cp tgen-tmp:/telemetrygen /usr/local/bin/telemetrygen
    docker rm tgen-tmp >> "$LOG_FILE" 2>&1
    chmod +x /usr/local/bin/telemetrygen
    # イメージのクリーンアップ（ディスク節約）
    docker rmi "$${TELEMETRYGEN_IMAGE}" >> "$LOG_FILE" 2>&1 || true
    log "telemetrygen $${TELEMETRYGEN_VERSION} installed successfully"
else
    log "telemetrygen already installed"
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
GIT_BRANCH="${git_branch}"
log "Cloning from: $GIT_REPO_URL (branch: $GIT_BRANCH)"

if [[ "$GIT_REPO_URL" == *"github.com"* ]] || [[ "$GIT_REPO_URL" == "https://"* ]]; then
    git clone -b "$GIT_BRANCH" "$GIT_REPO_URL" otel-memory >> "$LOG_FILE" 2>&1 || {
        log "WARNING: Failed to clone specific branch. Attempting default branch..."
        git clone "$GIT_REPO_URL" otel-memory >> "$LOG_FILE" 2>&1 || {
            log "WARNING: Failed to clone repository. You may need to manually clone or upload the code."
            log "Creating placeholder directory..."
            mkdir -p otel-memory
        }
    }
else
    log "WARNING: Invalid or placeholder git_repo_url. Creating empty directory."
    log "Please manually upload your code or configure git_repo_url variable."
    mkdir -p otel-memory
fi

chown -R ubuntu:ubuntu otel-memory
log "Project code setup completed"

# 5b. Python 依存のインストール（pyloadgen 用）
log "Step 5b: Installing Python dependencies for pyloadgen"
apt-get install -y python3-pip >> "$LOG_FILE" 2>&1 || log "WARNING: Failed to install python3-pip"
if [ -f "/home/ubuntu/otel-memory/pyloadgen/requirements.txt" ]; then
    pip3 install --break-system-packages -r /home/ubuntu/otel-memory/pyloadgen/requirements.txt >> "$LOG_FILE" 2>&1 || {
        log "WARNING: Failed to install Python dependencies. You may need to install manually."
    }
    log "Python dependencies installed successfully"
else
    log "WARNING: pyloadgen/requirements.txt not found. Skipping Python dependency installation."
fi

# 6. Collector VMの内部IP情報を保存
log "Step 6: Saving Collector VM connection info"
COLLECTOR_IP="${collector_internal_ip}"

cat > /home/ubuntu/collector_info.txt <<EOF
# Collector VM Connection Info
COLLECTOR_INTERNAL_IP=$COLLECTOR_IP
COLLECTOR_ENDPOINT=$COLLECTOR_IP:4317

# Usage example:
# telemetrygen traces --otlp-endpoint $COLLECTOR_IP:4317 --otlp-insecure --rate 1500 --duration 120s --workers 10 --child-spans 5
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
1. telemetrygen traces --otlp-endpoint $COLLECTOR_IP:4317 --otlp-insecure --rate 1500 --duration 120s --workers 10 --child-spans 5

Installed versions:
- telemetrygen: $(telemetrygen --version 2>/dev/null || echo "Not found")
- Docker: $(docker --version 2>/dev/null || echo "Not found")

For more information, see ~/otel-memory/README.md
EOF

chown ubuntu:ubuntu /home/ubuntu/setup_status.txt

log "=== Loadgen VM setup completed successfully ==="
log "Users can now SSH and run: cat ~/setup_status.txt"

# 8. 最終確認
log "Final check - listing installed tools:"
log "telemetrygen: $(telemetrygen --version 2>/dev/null || echo "Not found")"
log "Docker: $(docker --version 2>/dev/null || echo "Not found")"
log "Git: $(git --version)"
log "Collector IP: $COLLECTOR_IP"

exit 0
