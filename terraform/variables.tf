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

# ====================
# Collector VM 設定
# ====================

variable "collector_machine_type" {
  description = "Collector VM machine type (e2-medium: 2vCPU 4GB RAM)"
  type        = string
  default     = "e2-medium"
}

# ====================
# Loadgen VM 設定
# ====================

variable "loadgen_machine_type" {
  description = "Loadgen VM machine type (e2-small: 2vCPU 2GB RAM)"
  type        = string
  default     = "e2-small"
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
