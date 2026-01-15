output "instance_name" {
  description = "Name of the created VM instance"
  value       = google_compute_instance.otel_collector_vm.name
}

output "instance_zone" {
  description = "Zone of the VM instance"
  value       = google_compute_instance.otel_collector_vm.zone
}

output "external_ip" {
  description = "External IP address of the VM"
  value       = google_compute_instance.otel_collector_vm.network_interface[0].access_config[0].nat_ip
}

output "ssh_command" {
  description = "SSH command to connect to the VM"
  value       = "ssh ubuntu@${google_compute_instance.otel_collector_vm.network_interface[0].access_config[0].nat_ip}"
}

output "gcloud_ssh_command" {
  description = "gcloud SSH command to connect to the VM"
  value       = "gcloud compute ssh ${google_compute_instance.otel_collector_vm.name} --zone=${google_compute_instance.otel_collector_vm.zone} --project=${var.project_id}"
}

output "grafana_url" {
  description = "URL to access Grafana dashboard"
  value       = "http://${google_compute_instance.otel_collector_vm.network_interface[0].access_config[0].nat_ip}:3000"
}

output "prometheus_url" {
  description = "URL to access Prometheus UI"
  value       = "http://${google_compute_instance.otel_collector_vm.network_interface[0].access_config[0].nat_ip}:9090"
}

output "jaeger_url" {
  description = "URL to access Jaeger UI"
  value       = "http://${google_compute_instance.otel_collector_vm.network_interface[0].access_config[0].nat_ip}:16686"
}

output "setup_status_check" {
  description = "Command to check setup status on the VM"
  value       = "ssh ubuntu@${google_compute_instance.otel_collector_vm.network_interface[0].access_config[0].nat_ip} 'cat ~/setup_status.txt'"
}

output "project_directory" {
  description = "Project directory path on the VM"
  value       = "/home/ubuntu/otel-memory"
}

output "quick_start_commands" {
  description = "Quick start commands after SSH"
  value = <<-EOT
    # 1. SSH接続
    ${google_compute_instance.otel_collector_vm.network_interface[0].access_config[0].nat_ip != "" ? "ssh ubuntu@${google_compute_instance.otel_collector_vm.network_interface[0].access_config[0].nat_ip}" : "gcloud compute ssh ${google_compute_instance.otel_collector_vm.name} --zone=${google_compute_instance.otel_collector_vm.zone}"}

    # 2. セットアップ確認
    cat ~/setup_status.txt

    # 3. プロジェクトディレクトリへ移動
    cd ~/otel-memory

    # 4. サービス起動
    make up

    # 5. シナリオ実行例
    make scenario-1
  EOT
}
