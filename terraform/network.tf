// SSH: 両VMへの外部アクセス
resource "google_compute_firewall" "allow_ssh" {
  name          = "otel-debug-allow-ssh"
  description   = "Allow SSH access from specified IPs"
  network       = "default"
  source_ranges = var.allowed_ssh_ips
  target_tags   = ["allow-ssh"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

// Web UI: Collector VMへの外部アクセス（Grafana, Prometheus, Jaeger）
resource "google_compute_firewall" "allow_web_ui" {
  name          = "otel-debug-allow-web-ui"
  description   = "Allow access to Grafana (3000), Prometheus (9090), Jaeger (16686)"
  network       = "default"
  source_ranges = var.allowed_web_ips
  target_tags   = ["allow-web-ui"]

  allow {
    protocol = "tcp"
    ports    = ["3000", "9090", "16686"]
  }
}

// OTLP gRPC: 内部ネットワークからのみ（Loadgen VM → Collector VM）
resource "google_compute_firewall" "allow_otlp_internal" {
  name          = "otel-debug-allow-otlp-internal"
  description   = "Allow OTLP gRPC traffic from internal network (Loadgen VM)"
  network       = "default"
  source_ranges = ["10.128.0.0/9"]
  target_tags   = ["otel-collector"]

  allow {
    protocol = "tcp"
    ports    = ["4317"]
  }
}
