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

output "collector_gcloud_ssh_command" {
  description = "gcloud SSH command to connect to the Collector VM"
  value       = "gcloud compute ssh ${google_compute_instance.collector_vm.name} --zone=${google_compute_instance.collector_vm.zone} --project=${var.project_id}"
}

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

output "loadgen_gcloud_ssh_command" {
  description = "gcloud SSH command to connect to the Loadgen VM"
  value       = "gcloud compute ssh ${google_compute_instance.loadgen_vm.name} --zone=${google_compute_instance.loadgen_vm.zone} --project=${var.project_id}"
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

output "collector_metrics_url" {
  description = "URL to access Collector self-telemetry metrics"
  value       = "http://${google_compute_instance.collector_vm.network_interface[0].access_config[0].nat_ip}:8888/metrics"
}

output "loadgen_command_example" {
  description = "Example loadgen command with Collector internal IP"
  value       = "./loadgen -endpoint ${google_compute_instance.collector_vm.network_interface[0].network_ip}:4317 -scenario sustained -duration 60s -rate 1000"
}
