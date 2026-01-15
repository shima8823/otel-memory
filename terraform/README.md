# OpenTelemetry Collector Debug Environment - Terraform IaC

このディレクトリには、Google Cloud Platform（GCP）上にOpenTelemetry Collectorのデバッグ環境を構築するためのTerraform設定が含まれています。

## 概要

このTerraform設定は以下を自動的にプロビジョニングします：

- **GCE VMインスタンス**（e2-medium: 2vCPU, 4GB RAM）
- **ファイアウォールルール**（SSH、Grafana、Prometheus、Jaeger、OTLP）
- **スタートアップスクリプト**（Docker、Docker Compose、Go、プロジェクトコードの自動セットアップ）

## 前提条件

### ローカル環境

1. **Terraform**（v1.5以降）
   ```bash
   # インストール確認
   terraform version
   ```

2. **gcloud CLI**
   ```bash
   # インストール確認
   gcloud version
   
   # 認証設定
   gcloud auth application-default login
   ```

3. **GCPプロジェクト**
   - GCPプロジェクトが作成済み
   - 請求先アカウントが有効
   - 必要なAPI（Compute Engine API）が有効化済み

## クイックスタート

### 1. 設定ファイルの準備

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars`を編集して、以下の必須項目を設定：

```hcl
project_id   = "your-gcp-project-id"
git_repo_url = "https://github.com/your-username/otel-memory.git"
```

**重要**: `git_repo_url`は実際のリポジトリURLに変更してください。プライベートリポジトリの場合は、後述の「プライベートリポジトリの対応」を参照してください。

### 2. Terraformの初期化

```bash
terraform init
```

### 3. 実行計画の確認

```bash
terraform plan
```

作成されるリソースを確認します：
- 1つのGCE VMインスタンス
- 4つのファイアウォールルール（SSH、Web UI、OTLP、Collector Metrics）

### 4. リソースの作成

```bash
terraform apply
```

プロンプトで `yes` と入力して実行を確認します。

**所要時間**: 約3-5分

### 5. 出力値の確認

```bash
terraform output
```

以下の情報が表示されます：
- VM外部IPアドレス
- SSH接続コマンド
- Grafana、Prometheus、JaegerのURL

### 6. VMへの接続

#### 方法1: gcloudコマンド（推奨）

```bash
# outputに表示されたコマンドをコピー＆ペースト
gcloud compute ssh otel-collector-debug --zone=asia-northeast1-a --project=your-project-id
```

#### 方法2: 直接SSH

```bash
# outputに表示されたIPアドレスを使用
ssh ubuntu@<EXTERNAL_IP>
```

**注意**: `gcloud compute ssh`で接続すると、GCPが自動的にローカルのユーザー名でVM上にユーザーを作成します。一方、スタートアップスクリプトは`ubuntu`ユーザーのホームディレクトリ（`/home/ubuntu`）にファイルを作成します。

プロジェクトファイルが見つからない場合は、以下を確認してください：

```bash
# ubuntuユーザーのホームディレクトリを確認
ls -la /home/ubuntu/

# ubuntuユーザーに切り替える
sudo su - ubuntu

# または直接パスを指定
cd /home/ubuntu/otel-memory
```

### 7. セットアップ状態の確認

VM接続後：

```bash
# セットアップ完了確認（ubuntuユーザーのホームディレクトリ）
cat /home/ubuntu/setup_status.txt
# または、ubuntuユーザーに切り替えた場合
sudo su - ubuntu
cat ~/setup_status.txt

# ツールのバージョン確認
docker --version
docker-compose --version
go version
```

### 8. サービスの起動とシナリオ実行

```bash
# プロジェクトディレクトリへ移動（ubuntuユーザーのホームディレクトリ）
cd /home/ubuntu/otel-memory
# または、ubuntuユーザーに切り替えた場合
sudo su - ubuntu
cd ~/otel-memory

# サービス起動
make up

# ブラウザでダッシュボード確認
# - Grafana: http://<VM_IP>:3000
# - Prometheus: http://<VM_IP>:9090
# - Jaeger: http://<VM_IP>:16686

# シナリオ実行
make scenario-1

# メトリクスエクスポート
make export-metrics DURATION=15 STEP=60 OUTPUT=scenario1_results
```

### 9. 結果のダウンロード

ローカルマシンから（別ターミナル）：

```bash
scp -r ubuntu@<VM_IP>:~/otel-memory/scenario1_results ./
```

### 10. リソースの削除（実験完了後）

```bash
terraform destroy
```

プロンプトで `yes` と入力して削除を確認します。

**重要**: 削除を忘れるとコストが継続的に発生します。

## 設定のカスタマイズ

### VMスペックの変更

より大きなVMが必要な場合、`terraform.tfvars`で変更：

```hcl
machine_type = "e2-standard-4"  # 4vCPU, 16GB RAM
```

### セキュリティの強化

特定のIPアドレスからのみアクセスを許可：

```hcl
allowed_ssh_ips = ["203.0.113.0/32"]  # 自分のIPアドレス
allowed_web_ips = ["203.0.113.0/32"]  # 自分のIPアドレス
```

自分のIPアドレスを確認：

```bash
curl ifconfig.me
```

### リージョン/ゾーンの変更

```hcl
region = "us-central1"
zone   = "us-central1-a"
```

## プライベートリポジトリの対応

### 方法1: デプロイキーの使用（推奨）

1. GitHubでデプロイキーを生成
2. startup-script.shを修正してSSHキーを設定
3. `git_repo_url`をSSH形式に変更

```hcl
git_repo_url = "git@github.com:your-username/otel-memory.git"
```

### 方法2: 手動アップロード

1. `git_repo_url`はプレースホルダーのまま
2. VM起動後、手動でコードをアップロード：

```bash
# ローカルからVMへアップロード
scp -r ./otel-memory ubuntu@<VM_IP>:~/
```

## トラブルシューティング

### 問題: `terraform apply` でエラーが発生

#### API が有効化されていない

```
Error: Error creating instance: googleapi: Error 403: Compute Engine API has not been used
```

**解決策**:

```bash
gcloud services enable compute.googleapis.com --project=your-project-id
```

#### プロジェクトIDが無効

```
Error: Error getting project: googleapi: Error 403: The caller does not have permission
```

**解決策**: `terraform.tfvars`の`project_id`が正しいか確認

```bash
gcloud projects list
```

#### 認証エラー

```
Error: google: could not find default credentials
```

**解決策**:

```bash
gcloud auth application-default login
```

### 問題: VMにSSH接続できない

#### ファイアウォールルールの確認

```bash
gcloud compute firewall-rules list --project=your-project-id
```

`otel-collector-debug-allow-ssh`が存在するか確認

#### GCPコンソールからシリアルコンソールを使用

1. GCPコンソール > Compute Engine > VMインスタンス
2. 該当のVMを選択
3. 「シリアルポートに接続」をクリック

### 問題: スタートアップスクリプトが失敗

#### ログの確認

VM接続後：

```bash
sudo tail -n 100 /var/log/startup-script.log
```

#### 手動でスクリプトを再実行

```bash
sudo bash /var/run/google.startup.script
```

### 問題: Gitリポジトリのクローンに失敗

#### ログ確認

```bash
sudo cat /var/log/startup-script.log | grep -A 10 "Cloning"
```

#### 手動でクローン

```bash
cd ~
git clone https://github.com/your-username/otel-memory.git
```

### 問題: Docker Composeが起動しない

#### Docker サービスの確認

```bash
sudo systemctl status docker
```

#### Docker グループの確認

```bash
groups ubuntu
# ubuntu docker ... と表示されるはず
```

表示されない場合、再ログインまたは：

```bash
newgrp docker
```

### 問題: メトリクスが取得できない

#### サービスの起動確認

```bash
cd ~/otel-memory
docker-compose ps
```

すべてのサービスが`Up`状態か確認

#### Prometheusの接続確認

```bash
curl http://localhost:9090/-/healthy
```

## コスト管理

### 推定コスト（asia-northeast1リージョン）

- **e2-medium**: 約$0.067/時間
- **実験用途（1日3時間使用）**: 約$6/月
- **1週間の実験**: 約$1.5-2

### コスト削減のヒント

1. **使用後は必ず削除**
   ```bash
   terraform destroy
   ```

2. **VMの停止**
   ```bash
   gcloud compute instances stop otel-collector-debug --zone=asia-northeast1-a
   ```
   停止中はCPU/RAM課金なし（ディスクのみ課金）

3. **予算アラートの設定**
   GCPコンソール > 請求 > 予算とアラート

## 高度な使用例

### 複数のシナリオを並列実行

`main.tf`を編集して`count`を使用：

```hcl
resource "google_compute_instance" "otel_collector_vm" {
  count = 4  # 4つのVMを作成
  name  = "${var.instance_name}-${count.index + 1}"
  # ...
}
```

### Cloud Storageへの結果自動アップロード

1. バケット作成

```hcl
resource "google_storage_bucket" "results" {
  name     = "${var.project_id}-otel-results"
  location = var.region
}
```

2. シナリオ完了後にアップロード

```bash
gsutil cp -r scenario1_results gs://your-project-otel-results/
```

## ファイル構成

```
terraform/
├── main.tf                    # メインのリソース定義
├── variables.tf               # 変数定義
├── outputs.tf                 # 出力値
├── terraform.tfvars.example   # 変数の例示ファイル
├── terraform.tfvars           # 実際の設定（.gitignore対象）
├── startup-script.sh          # VMスタートアップスクリプト
└── README.md                  # このファイル
```

## 参考リンク

- [Terraform Google Provider](https://registry.terraform.io/providers/hashicorp/google/latest/docs)
- [GCE Machine Types](https://cloud.google.com/compute/docs/machine-types)
- [GCP Pricing Calculator](https://cloud.google.com/products/calculator)
- [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/)

## サポート

問題が発生した場合は、以下を確認してください：

1. `terraform.tfvars`の設定が正しいか
2. GCP APIが有効化されているか
3. 認証が正しく設定されているか
4. `/var/log/startup-script.log`のエラーメッセージ

## ライセンス

Apache License 2.0 - 詳細は [LICENSE](../LICENSE) を参照
