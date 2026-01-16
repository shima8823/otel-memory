# Variables for OpenTelemetry Collector debug environment on GCE
# 2-instance configuration: Collector VM + Loadgen VM

# ====================
# 共通設定
# ====================

variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
  default     = "otel-debug"
}

variable "region" {
  description = "GCP region for resources"
  type        = string
  default     = "asia-northeast1"
}

variable "zone" {
  description = "GCP zone for VM instances"
  type        = string
  default     = "asia-northeast1-a"
}

variable "network_name" {
  description = "VPC network name for VM and firewall rules"
  type        = string
  default     = "default"
}

variable "git_repo_url" {
  description = "Git repository URL to clone otel-memory"
  type        = string
  default     = "https://github.com/your-org/otel-memory.git"
}

# ====================
# Collector VM 設定
# ====================

variable "collector_instance_name" {
  description = "Collector VM instance name"
  type        = string
  default     = "otel-collector"
}

variable "collector_machine_type" {
  description = "Collector VM machine type (e2-medium: 2vCPU 4GB RAM)"
  type        = string
  default     = "e2-medium"
}

variable "collector_boot_disk_size" {
  description = "Collector VM boot disk size (GB)"
  type        = number
  default     = 30
}

# ====================
# Loadgen VM 設定
# ====================

variable "loadgen_instance_name" {
  description = "Loadgen VM instance name"
  type        = string
  default     = "otel-loadgen"
}

variable "loadgen_machine_type" {
  description = "Loadgen VM machine type (e2-small: 2vCPU 2GB RAM)"
  type        = string
  default     = "e2-small"
}

variable "loadgen_boot_disk_size" {
  description = "Loadgen VM boot disk size (GB)"
  type        = number
  default     = 20
}

# ====================
# セキュリティ設定
# ====================

variable "allowed_ssh_ips" {
  description = "CIDR ranges for SSH access to both VMs"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "allowed_web_ips" {
  description = "CIDR ranges for web UI access on Collector VM"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "internal_network_cidr" {
  description = "Internal CIDR range for OTLP gRPC on Collector VM"
  type        = string
  default     = "10.128.0.0/9"
}

# ====================
# SSH設定
# ====================

variable "ssh_public_key" {
  description = "SSH public key for VM access (optional)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "ssh_user" {
  description = "SSH username for the public key"
  type        = string
  default     = "ubuntu"
}
