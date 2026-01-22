output "project_id" {
  description = "Project ID"
  value       = var.project_id
}

output "collector_internal_ip" {
  description = "Internal IP address of the Collector VM (used by Loadgen VM)"
  value       = google_compute_instance.collector_vm.network_interface[0].network_ip
}
