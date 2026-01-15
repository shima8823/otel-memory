# Variables for OpenTelemetry Collector debug environment on GCE
# 2-instance configuration: Collector VM + Loadgen VM

# ====================
# 共通設定
# ====================

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
  description = "GCP Zone for VM instances"
  type        = string
  default     = "asia-northeast1-a"
}

variable "git_repo_url" {
  description = "Git repository URL to clone the otel-memory project"
  type        = string
  default     = "https://github.com/your-org/otel-memory.git"
}

# ====================
# Collector VM 設定
# ====================

variable "collector_instance_name" {
  description = "Name of the Collector VM instance"
  type        = string
  default     = "otel-collector"
}

variable "collector_machine_type" {
  description = "GCE machine type for Collector VM (e2-medium: 2vCPU 4GB RAM)"
  type        = string
  default     = "e2-medium"
}

variable "collector_boot_disk_size" {
  description = "Boot disk size in GB for Collector VM"
  type        = number
  default     = 30
}

# ====================
# Loadgen VM 設定
# ====================

variable "loadgen_instance_name" {
  description = "Name of the Loadgen VM instance"
  type        = string
  default     = "otel-loadgen"
}

variable "loadgen_machine_type" {
  description = "GCE machine type for Loadgen VM (e2-small: 2vCPU 2GB RAM)"
  type        = string
  default     = "e2-small"
}

variable "loadgen_boot_disk_size" {
  description = "Boot disk size in GB for Loadgen VM"
  type        = number
  default     = 20
}

# ====================
# セキュリティ設定
# ====================

variable "allowed_ssh_ips" {
  description = "CIDR ranges allowed for SSH access to both VMs"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "allowed_web_ips" {
  description = "CIDR ranges allowed for web UI access (Grafana, Prometheus, Jaeger) on Collector VM"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ====================
# SSH設定
# ====================

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
