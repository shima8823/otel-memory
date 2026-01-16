# ====================
# Collector VM Outputs
# ====================

output "collector_instance_name" {
  description = "Name of the Collector VM instance"
  value       = google_compute_instance.collector_vm.name
}

output "collector_zone" {
  description = "Zone of the Collector VM instance"
  value       = google_compute_instance.collector_vm.zone
}

output "collector_external_ip" {
  description = "External IP address of the Collector VM"
  value       = google_compute_instance.collector_vm.network_interface[0].access_config[0].nat_ip
}

output "collector_internal_ip" {
  description = "Internal IP address of the Collector VM (used by Loadgen VM)"
  value       = google_compute_instance.collector_vm.network_interface[0].network_ip
}

output "collector_ssh_command" {
  description = "SSH command to connect to the Collector VM"
  value       = "ssh ${var.ssh_user}@${google_compute_instance.collector_vm.network_interface[0].access_config[0].nat_ip}"
}

output "collector_gcloud_ssh_command" {
  description = "gcloud SSH command to connect to the Collector VM"
  value       = "gcloud compute ssh ${google_compute_instance.collector_vm.name} --zone=${google_compute_instance.collector_vm.zone} --project=${var.project_id}"
}

# ====================
# Loadgen VM Outputs
# ====================

output "loadgen_instance_name" {
  description = "Name of the Loadgen VM instance"
  value       = google_compute_instance.loadgen_vm.name
}

output "loadgen_zone" {
  description = "Zone of the Loadgen VM instance"
  value       = google_compute_instance.loadgen_vm.zone
}

output "loadgen_external_ip" {
  description = "External IP address of the Loadgen VM"
  value       = google_compute_instance.loadgen_vm.network_interface[0].access_config[0].nat_ip
}

output "loadgen_internal_ip" {
  description = "Internal IP address of the Loadgen VM"
  value       = google_compute_instance.loadgen_vm.network_interface[0].network_ip
}

output "loadgen_ssh_command" {
  description = "SSH command to connect to the Loadgen VM"
  value       = "ssh ${var.ssh_user}@${google_compute_instance.loadgen_vm.network_interface[0].access_config[0].nat_ip}"
}

output "loadgen_gcloud_ssh_command" {
  description = "gcloud SSH command to connect to the Loadgen VM"
  value       = "gcloud compute ssh ${google_compute_instance.loadgen_vm.name} --zone=${google_compute_instance.loadgen_vm.zone} --project=${var.project_id}"
}

# ====================
# Web UI URLs
# ====================

output "grafana_url" {
  description = "URL to access Grafana dashboard"
  value       = "http://${google_compute_instance.collector_vm.network_interface[0].access_config[0].nat_ip}:3000"
}

output "prometheus_url" {
  description = "URL to access Prometheus UI"
  value       = "http://${google_compute_instance.collector_vm.network_interface[0].access_config[0].nat_ip}:9090"
}

output "jaeger_url" {
  description = "URL to access Jaeger UI"
  value       = "http://${google_compute_instance.collector_vm.network_interface[0].access_config[0].nat_ip}:16686"
}

output "collector_metrics_url" {
  description = "URL to access Collector self-telemetry metrics"
  value       = "http://${google_compute_instance.collector_vm.network_interface[0].access_config[0].nat_ip}:8888/metrics"
}

# ====================
# Quick Start Guide
# ====================

output "quick_start_collector" {
  description = "Quick start commands for Collector VM"
  value       = <<-EOT
    # === Collector VM ===
    
    # 1. SSH接続
    ssh ${var.ssh_user}@${google_compute_instance.collector_vm.network_interface[0].access_config[0].nat_ip}
    
    # 2. セットアップ確認
    cat ~/setup_status.txt
    
    # 3. サービス起動
    cd ~/otel-memory && make up
    
    # 4. Web UIアクセス
    # - Grafana:    http://${google_compute_instance.collector_vm.network_interface[0].access_config[0].nat_ip}:3000
    # - Prometheus: http://${google_compute_instance.collector_vm.network_interface[0].access_config[0].nat_ip}:9090
    # - Jaeger:     http://${google_compute_instance.collector_vm.network_interface[0].access_config[0].nat_ip}:16686
  EOT
}

output "quick_start_loadgen" {
  description = "Quick start commands for Loadgen VM"
  value       = <<-EOT
    # === Loadgen VM ===
    
    # 1. SSH接続
    ssh ${var.ssh_user}@${google_compute_instance.loadgen_vm.network_interface[0].access_config[0].nat_ip}
    
    # 2. セットアップ確認
    cat ~/setup_status.txt
    
    # 3. loadgen実行（Collector VMの内部IPに送信）
    cd ~/otel-memory/loadgen
    ./loadgen -endpoint ${google_compute_instance.collector_vm.network_interface[0].network_ip}:4317 -scenario sustained -duration 60s
    
    # シナリオ例:
    # - burst:     可能な限り高速に送信
    # - sustained: 一定レートで継続送信
    # - spike:     通常負荷とスパイクを繰り返し
    # - rampup:    徐々に負荷を上げる
  EOT
}

output "loadgen_command_example" {
  description = "Example loadgen command with Collector internal IP"
  value       = "./loadgen -endpoint ${google_compute_instance.collector_vm.network_interface[0].network_ip}:4317 -scenario sustained -duration 60s -rate 1000"
}
