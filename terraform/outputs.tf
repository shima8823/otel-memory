output "project_id" {
  description = "Project ID"
  value       = var.project_id
}

output "collector_internal_ip" {
  description = "Internal IP address of the Collector VM (used by Loadgen VM)"
  value       = google_compute_instance.collector_vm.network_interface[0].network_ip
}

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
