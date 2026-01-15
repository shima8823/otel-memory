terraform {
  required_version = "~> 1.14.0"
  
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.15.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

data "google_compute_image" "ubuntu" {
  family  = "ubuntu-2204-lts"
  project = "ubuntu-os-cloud"
}

# ====================
# Collector VM
# ====================
# OTel Collector, Prometheus, Grafana, Jaeger を実行
resource "google_compute_instance" "collector_vm" {
  name         = var.collector_instance_name
  machine_type = var.collector_machine_type
  zone         = var.zone

  tags = ["otel-collector", "allow-ssh", "allow-web-ui"]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = var.collector_boot_disk_size
      type  = "pd-standard"
    }
  }

  network_interface {
    network = "default"

    access_config {
      // Ephemeral public IP
    }
  }

  metadata = {
    ssh-keys = var.ssh_public_key != "" ? "${var.ssh_user}:${var.ssh_public_key}" : ""
  }

  metadata_startup_script = templatefile("${path.module}/startup-script.sh", {
    git_repo_url = var.git_repo_url
  })

  allow_stopping_for_update = true

  labels = {
    environment = "debug"
    purpose     = "otel-collector"
    managed_by  = "terraform"
  }
}

# ====================
# Loadgen VM
# ====================
# 負荷生成ツール (loadgen) を実行
resource "google_compute_instance" "loadgen_vm" {
  name         = var.loadgen_instance_name
  machine_type = var.loadgen_machine_type
  zone         = var.zone

  tags = ["otel-loadgen", "allow-ssh"]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = var.loadgen_boot_disk_size
      type  = "pd-standard"
    }
  }

  network_interface {
    network = "default"

    access_config {
      // Ephemeral public IP
    }
  }

  metadata = {
    ssh-keys = var.ssh_public_key != "" ? "${var.ssh_user}:${var.ssh_public_key}" : ""
  }

  metadata_startup_script = templatefile("${path.module}/startup-script-loadgen.sh", {
    git_repo_url          = var.git_repo_url
    collector_internal_ip = google_compute_instance.collector_vm.network_interface[0].network_ip
  })

  allow_stopping_for_update = true

  # Collector VMが先に作成されるよう依存関係を設定
  depends_on = [google_compute_instance.collector_vm]

  labels = {
    environment = "debug"
    purpose     = "otel-loadgen"
    managed_by  = "terraform"
  }
}

# ====================
# ファイアウォールルール
# ====================

# SSH: 両VMへの外部アクセス
resource "google_compute_firewall" "allow_ssh" {
  name    = "otel-debug-allow-ssh"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = var.allowed_ssh_ips
  target_tags   = ["allow-ssh"]

  description = "Allow SSH access from specified IPs"
}

# Web UI: Collector VMへの外部アクセス（Grafana, Prometheus, Jaeger）
resource "google_compute_firewall" "allow_web_ui" {
  name    = "otel-debug-allow-web-ui"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["3000", "9090", "16686"]
  }

  source_ranges = var.allowed_web_ips
  target_tags   = ["allow-web-ui"]

  description = "Allow access to Grafana (3000), Prometheus (9090), Jaeger (16686)"
}

# OTLP gRPC: 内部ネットワークからのみ（Loadgen VM → Collector VM）
resource "google_compute_firewall" "allow_otlp_internal" {
  name    = "otel-debug-allow-otlp-internal"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["4317"]
  }

  # GCPのデフォルトVPC内部ネットワーク範囲
  # GCPのデフォルトVPC（10.128.0.0/9, 各リージョン共通）の内部IPから許可
  # - Loadgen VMとCollector VMが同じVPC内にいる限り全リージョンで有効
  # - 外部からはアクセス不可（セキュリティ確保）
  source_ranges = ["10.128.0.0/9"]
  target_tags   = ["otel-collector"]

  description = "Allow OTLP gRPC traffic from internal network (Loadgen VM)"
}

# Collector Metrics: 外部からのセルフテレメトリアクセス（オプション）
resource "google_compute_firewall" "allow_collector_metrics" {
  name    = "otel-debug-allow-collector-metrics"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["8888"]
  }

  source_ranges = var.allowed_web_ips
  target_tags   = ["otel-collector"]

  description = "Allow access to Collector self-telemetry metrics"
}
