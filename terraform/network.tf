// ====================
// ファイアウォールルール
// ====================

// SSH: 両VMへの外部アクセス
resource "google_compute_firewall" "allow_ssh" {
  name    = "${var.name_prefix}-allow-ssh"
  network = var.network_name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = var.allowed_ssh_ips
  target_tags   = ["allow-ssh"]

  description = "Allow SSH access from specified IPs"
}

// Web UI: Collector VMへの外部アクセス（Grafana, Prometheus, Jaeger）
resource "google_compute_firewall" "allow_web_ui" {
  name    = "${var.name_prefix}-allow-web-ui"
  network = var.network_name

  allow {
    protocol = "tcp"
    ports    = ["3000", "9090", "16686"]
  }

  source_ranges = var.allowed_web_ips
  target_tags   = ["allow-web-ui"]

  description = "Allow access to Grafana (3000), Prometheus (9090), Jaeger (16686)"
}

// OTLP gRPC: 内部ネットワークからのみ（Loadgen VM → Collector VM）
resource "google_compute_firewall" "allow_otlp_internal" {
  name    = "${var.name_prefix}-allow-otlp-internal"
  network = var.network_name

  allow {
    protocol = "tcp"
    ports    = ["4317"]
  }

  // GCPのデフォルトVPC内部ネットワーク範囲
  // GCPのデフォルトVPC（10.128.0.0/9, 各リージョン共通）の内部IPから許可
  // - Loadgen VMとCollector VMが同じVPC内にいる限り全リージョンで有効
  // - 外部からはアクセス不可（セキュリティ確保）
  source_ranges = [var.internal_network_cidr]
  target_tags   = ["otel-collector"]

  description = "Allow OTLP gRPC traffic from internal network (Loadgen VM)"
}

// Collector Metrics: 外部からのセルフテレメトリアクセス（オプション）
resource "google_compute_firewall" "allow_collector_metrics" {
  name    = "${var.name_prefix}-allow-collector-metrics"
  network = var.network_name

  allow {
    protocol = "tcp"
    ports    = ["8888"]
  }

  source_ranges = var.allowed_web_ips
  target_tags   = ["otel-collector"]

  description = "Allow access to Collector self-telemetry metrics"
}
