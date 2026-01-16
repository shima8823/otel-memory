locals {
  ssh_keys_metadata = var.ssh_public_key != "" ? "${var.ssh_user}:${var.ssh_public_key}" : ""

  base_labels = {
    environment = "debug"
    managed_by  = "terraform"
  }

  collector_labels = merge(local.base_labels, {
    purpose = "otel-collector"
  })

  loadgen_labels = merge(local.base_labels, {
    purpose = "otel-loadgen"
  })

  collector_tags = ["otel-collector", "allow-ssh", "allow-web-ui"]
  loadgen_tags   = ["otel-loadgen", "allow-ssh"]
}
