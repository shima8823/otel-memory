# OpenTelemetry Collector Debug Environment - Terraform IaC

このディレクトリには、Google Cloud Platform（GCP）上にOpenTelemetry Collectorのデバッグ環境を構築するためのTerraform設定が含まれています。

## 概要

このTerraform設定は**2インスタンス構成**で、負荷生成と収集・可視化を分離しています。これにより、正確な負荷試験結果を得ることができます。

### アーキテクチャ

```
┌─────────────────────────────────────────────────────────────────┐
│                         GCP VPC (default)                       │
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

### なぜ2インスタンス構成なのか？

- **測定の正確性**: loadgenのリソース消費がCollectorの測定に影響しない
- **リアルなネットワーク条件**: 内部IP経由の通信で、実環境に近い条件をテスト
- **ボトルネックの明確化**: Collectorの問題なのかloadgenの問題なのか切り分け可能

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

3. **GCPプロジェクト**
   - GCPプロジェクトが作成済み
   - 請求先アカウントが有効
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

**所要時間**: 約5-7分（2つのVMをセットアップ）

### 3. 出力値の確認

```bash
terraform output
```

主な出力：
- Collector/Loadgen VMの内部IP
- gcloud SSH接続コマンド
- loadgen実行コマンド例

### 4. Collector VMでサービス起動

```bash
# Collector VMにSSH接続
gcloud compute ssh otel-collector --zone=asia-northeast1-a --project=$(terraform output -raw project_id)

# ubuntuユーザーに切り替え（スタートアップスクリプトはubuntuユーザーで実行）
sudo su - ubuntu

# セットアップ確認
cat ~/setup_status.txt

# サービス起動
cd ~/otel-memory
make up

# 動作確認
docker-compose ps
```

**ヒント**: `terraform output collector_gcloud_ssh_command` で正確なSSHコマンドを確認できます。

### 5. Loadgen VMで負荷テスト実行

```bash
# Loadgen VMにSSH接続（別ターミナル）
gcloud compute ssh otel-loadgen --zone=asia-northeast1-a --project=$(terraform output -raw project_id)

# ubuntuユーザーに切り替え
sudo su - ubuntu

# loadgen実行（Collector VMの内部IPに送信）
cd ~/otel-memory/loadgen
./loadgen -endpoint $(terraform output -raw collector_internal_ip):4317 -scenario sustained -duration 60s
```

**ヒント**: `terraform output loadgen_command_example` でコマンド例を確認できます。

### 6. Web UIでモニタリング

ブラウザで以下にアクセス（URLは `terraform output` で確認可能）：
- **Grafana**: `$(terraform output -raw grafana_url)`
- **Prometheus**: `$(terraform output -raw prometheus_url)`
- **Jaeger**: `$(terraform output -raw jaeger_url)`

### 7. リソースの削除

```bash
terraform destroy
```

**重要**: 削除を忘れるとコストが継続的に発生します。

## loadgenシナリオ

| シナリオ | 説明 |
|---------|------|
| `burst` | 可能な限り高速に送信（レート制限なし） |
| `sustained` | 指定レートで継続的に送信（デフォルト） |
| `spike` | 通常負荷とスパイクを交互に繰り返し |
| `rampup` | 徐々に負荷を上げていく |

### loadgenオプション

```bash
./loadgen \
  -endpoint <COLLECTOR_IP>:4317 \
  -scenario sustained \
  -duration 60s \
  -workers 10 \
  -rate 1000 \
  -depth 5 \
  -attr-size 256 \
  -attr-count 10 \
  -metrics true
```

## 設定のカスタマイズ

### VMスペックの変更

`terraform.tfvars`で変更：

```hcl
# より大きなCollector VM（高負荷テスト用）
collector_machine_type = "e2-standard-4"  # 4vCPU, 16GB RAM

# より大きなLoadgen VM
loadgen_machine_type = "e2-medium"  # 2vCPU, 4GB RAM
```

### セキュリティについて

```hcl
# 特定のIPからのみアクセスを許可
allowed_ssh_ips = ["YOUR_IP_ADDRESS/32"]
allowed_web_ips = ["YOUR_IP_ADDRESS/32"]
```

### ネットワーク/名前の変更

```hcl
# 既存のVPCを指定（例: shared-vpc）
network_name = "shared-vpc"

# ファイアウォール名のプレフィックス
name_prefix = "otel-debug"

# OTLP gRPCの内部許可CIDR
internal_network_cidr = "10.128.0.0/9"
```

自分のIPアドレスを確認：

IAP経由のSSHには適切なIAM権限が必要です：
- `roles/compute.instanceAdmin.v1`
- `roles/iap.tunnelResourceAccessor`

## ネットワーク構成

- **Loadgen → Collector**: 内部IP経由でOTLP gRPC (4317)
- **ローカル → Collector**: 直接アクセスまたはSSHポートフォワーディングでWeb UI (3000, 9090, 16686)
- **SSH接続**: gcloud compute ssh経由（IAP tunneling）

## トラブルシューティング

### スタートアップスクリプトのログ確認

```bash
sudo tail -f /var/log/startup-script.log
```

### loadgenがCollectorに接続できない

1. Collector VMでサービスが起動しているか確認：
   ```bash
   docker-compose ps
   ```

2. ファイアウォールルールを確認：
   ```bash
   gcloud compute firewall-rules list --project=$(terraform output -raw project_id)
   ```

3. 内部IPで接続をテスト（Loadgen VMから）：
   ```bash
   nc -zv $(terraform output -raw collector_internal_ip) 4317
   ```

### Docker Composeが起動しない

```bash
# Dockerサービス確認
sudo systemctl status docker

# dockerグループ確認
groups ubuntu

# 再ログインまたは
newgrp docker
```

## コスト管理

### 推定コスト（asia-northeast1リージョン）

| VM | 時間あたり | 1日3時間/月 |
|----|-----------|------------|
| Collector (e2-medium) | 約$0.067 | 約$6 |
| Loadgen (e2-small) | 約$0.034 | 約$3 |
| **合計** | 約$0.10 | 約$9 |

### コスト削減のヒント

1. **使用後は必ず削除**
   ```bash
   terraform destroy
   ```

2. **VMの停止**（削除せずに一時停止）
   ```bash
   gcloud compute instances stop otel-collector otel-loadgen --zone=asia-northeast1-a --project=$(terraform output -raw project_id)
   ```

## ファイル構成

```
terraform/
├── providers.tf                 # Terraform/Provider 設定
├── data.tf                      # データソース
├── locals.tf                    # 共通ラベル/タグ/メタデータ
├── compute.tf                   # Collector/Loadgen VM
├── network.tf                   # ファイアウォールルール
├── variables.tf                 # 変数定義
├── outputs.tf                   # 出力値
├── terraform.tfvars.example     # 変数の例示ファイル
├── terraform.tfvars             # 実際の設定（.gitignore対象）
├── startup-script.sh            # Collector VM スタートアップスクリプト
├── startup-script-loadgen.sh    # Loadgen VM スタートアップスクリプト
└── README.md                    # このファイル
```

## 参考リンク

- [Terraform Google Provider](https://registry.terraform.io/providers/hashicorp/google/latest/docs)
- [GCE Machine Types](https://cloud.google.com/compute/docs/machine-types)
- [GCP Pricing Calculator](https://cloud.google.com/products/calculator)
- [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/)

## ライセンス

Apache License 2.0 - 詳細は [LICENSE](../LICENSE) を参照
