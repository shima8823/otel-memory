# Variables for OpenTelemetry Collector debug environment on GCE

variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP Region for resources"
  type        = string
  default     = "asia-northeast1"
}

variable "zone" {
  description = "GCP Zone for VM instance"
  type        = string
  default     = "asia-northeast1-a"
}

variable "instance_name" {
  description = "Name of the GCE VM instance"
  type        = string
  default     = "otel-collector-debug"
}

variable "machine_type" {
  description = "GCE machine type (e2-medium: 2vCPU 4GB RAM)"
  type        = string
  default     = "e2-medium"
}

variable "boot_disk_size" {
  description = "Boot disk size in GB"
  type        = number
  default     = 30
}

variable "allowed_ssh_ips" {
  description = "CIDR ranges allowed for SSH access"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "allowed_web_ips" {
  description = "CIDR ranges allowed for web UI access (Grafana, Prometheus, Jaeger)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "allowed_otlp_ips" {
  description = "CIDR ranges allowed for OTLP gRPC traffic"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "git_repo_url" {
  description = "Git repository URL to clone the otel-memory project"
  type        = string
  default     = "https://github.com/your-org/otel-memory.git"
}

variable "ssh_public_key" {
  description = "SSH public key for VM access (optional, leave empty to use gcloud ssh)"
  type        = string
  default     = ""
}

variable "ssh_user" {
  description = "SSH username for the public key"
  type        = string
  default     = "ubuntu"
}
