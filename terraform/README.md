# OpenTelemetry Collector Debug Environment - Terraform IaC

このディレクトリには、Google Cloud Platform（Google Cloud）上にOpenTelemetry Collectorのデバッグ環境を構築するためのTerraform設定が含まれています。

## 概要

このTerraform設定は**2インスタンス構成**で、負荷生成と収集・可視化を分離しています。これにより、正確な負荷試験結果を得ることができます。

### アーキテクチャ

```
┌─────────────────────────────────────────────────────────────────┐
│                 Google Cloud VPC (default)                      │
│                                                                 │
│  ┌─────────────────────┐      ┌─────────────────────────────┐  │
│  │    Loadgen VM       │      │       Collector VM          │  │
│  │    (e2-small)       │      │       (e2-medium)           │  │
│  │                     │      │                             │  │
│  │  ┌───────────────┐  │      │  ┌───────────────────────┐  │  │
│  │  │   loadgen     │──┼──────┼─▶│   OTel Collector      │  │  │
│  │  │   binary      │  │ 4317 │  │   (port 4317)         │  │  │
│  │  └───────────────┘  │(内部)│  └───────────┬───────────┘  │  │
│  │                     │      │              │              │  │
│  └─────────────────────┘      │  ┌───────────▼───────────┐  │  │
│                               │  │     Prometheus        │  │  │
│                               │  │     (port 9090)       │  │  │
│                               │  └───────────┬───────────┘  │  │
│                               │              │              │  │
│                               │  ┌───────────▼───────────┐  │  │
│                               │  │      Grafana          │  │  │
│                               │  │     (port 3000)       │  │  │
│                               │  └───────────────────────┘  │  │
│                               │                             │  │
│                               │  ┌───────────────────────┐  │  │
│                               │  │       Jaeger          │  │  │
│                               │  │     (port 16686)      │  │  │
│                               │  └───────────────────────┘  │  │
│                               └─────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                                        │
                                        │ 外部アクセス
                                        ▼
                               ┌─────────────────┐
                               │   User Browser  │
                               │  :3000 :9090    │
                               │  :16686         │
                               └─────────────────┘
```

### 構成

| VM | マシンタイプ | 役割 |
|----|------------|------|
| **Collector VM** | e2-medium (2vCPU, 4GB) | OTel Collector, Prometheus, Grafana, Jaeger |
| **Loadgen VM** | e2-small (2vCPU, 2GB) | loadgen バイナリ実行 |

## 前提条件

### ローカル環境

1. **Terraform**（v1.14以降）
   ```bash
   terraform version
   ```

2. **gcloud CLI**
   ```bash
   gcloud version
   gcloud auth application-default login
   ```

3. **Google Cloudプロジェクト**
4. - Google Cloudプロジェクトが作成済み
   - Compute Engine APIが有効化済み

## クイックスタート

### 1. 設定ファイルの準備

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars`を編集（必須項目のみ）：

```hcl
project_id = "your-gcp-project-id"
```

### 2. Terraformの初期化と実行

```bash
terraform init
terraform plan
terraform apply
```

### 3. Collector VMでサービス起動

```bash
# Collector VMにSSH接続
gcloud compute ssh otel-collector --zone=asia-northeast1-a --project=$(terraform output -raw project_id)

# ubuntuユーザーに切り替え（スタートアップスクリプトはubuntuユーザーで実行）
sudo su - ubuntu

# サービス起動
cd ~/otel-memory
make up

# 動作確認
docker-compose ps
```

### 4. Loadgen VMで負荷テスト実行

```bash
# Loadgen VMにSSH接続（別ターミナル）
gcloud compute ssh otel-loadgen --zone=asia-northeast1-a --project=$(terraform output -raw project_id)

# ubuntuユーザーに切り替え
sudo su - ubuntu

# loadgen実行（Collector VMの内部IPに送信）
cd ~/otel-memory/loadgen
./loadgen -endpoint <Collectorの内部IP>:4317 -scenario sustained -duration 60s
```

### 5. Web UIでモニタリング

ブラウザで以下にアクセス（URLは `terraform output` で確認可能）：
- **Grafana**: `terraform output -raw grafana_url`
- **Prometheus**: `terraform output -raw prometheus_url`
- **Jaeger**: `terraform output -raw jaeger_url`

### 6. リソースの削除

```bash
terraform destroy
```
