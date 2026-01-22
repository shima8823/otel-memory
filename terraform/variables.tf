# ====================
# 共通設定
# ====================

variable "project_id" {
  description = "Google Cloud project ID"
  type        = string
}

variable "region" {
  description = "Google Cloud region for resources"
  type        = string
  default     = "asia-northeast1"
}

variable "zone" {
  description = "Google Cloud zone for VM instances"
  type        = string
  default     = "asia-northeast1-a"
}

variable "time_zone" {
  description = "Time zone for resource policies"
  type        = string
  default     = "Asia/Tokyo"
}

# ====================
# VM 設定
# ====================

variable "collector_machine_type" {
  description = "Collector VM machine type (e2-medium: 2vCPU 4GB RAM)"
  type        = string
  default     = "e2-medium"
}

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
