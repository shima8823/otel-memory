terraform {
  required_version = "~> 1.14.0"
  
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.15.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

data "google_compute_image" "ubuntu" {
  family  = "ubuntu-2204-lts"
  project = "ubuntu-os-cloud"
}

resource "google_compute_instance" "otel_collector_vm" {
  name         = var.instance_name
  machine_type = var.machine_type
  zone         = var.zone

  tags = ["otel-debug", "allow-ssh", "allow-http"]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = var.boot_disk_size
      type  = "pd-standard"
    }
  }

  network_interface {
    network = "default"

    access_config {
      // Ephemeral public IP
    }
  }

  metadata = {
    ssh-keys = var.ssh_public_key != "" ? "${var.ssh_user}:${var.ssh_public_key}" : ""
  }

  metadata_startup_script = templatefile("${path.module}/startup-script.sh", {
    git_repo_url = var.git_repo_url
  })

  allow_stopping_for_update = true

  labels = {
    environment = "debug"
    purpose     = "otel-collector-test"
    managed_by  = "terraform"
  }
}

resource "google_compute_firewall" "allow_ssh" {
  name    = "${var.instance_name}-allow-ssh"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = var.allowed_ssh_ips
  target_tags   = ["allow-ssh"]

  description = "Allow SSH access from specified IPs"
}

resource "google_compute_firewall" "allow_web_ui" {
  name    = "${var.instance_name}-allow-web-ui"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["3000", "9090", "16686"]
  }

  source_ranges = var.allowed_web_ips
  target_tags   = ["allow-http"]

  description = "Allow access to Grafana (3000), Prometheus (9090), Jaeger (16686)"
}

resource "google_compute_firewall" "allow_otlp" {
  name    = "${var.instance_name}-allow-otlp"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["4317"]
  }

  source_ranges = var.allowed_otlp_ips
  target_tags   = ["allow-http"]

  description = "Allow OTLP gRPC traffic (optional)"
}

resource "google_compute_firewall" "allow_collector_metrics" {
  name    = "${var.instance_name}-allow-collector-metrics"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["8888"]
  }

  source_ranges = var.allowed_web_ips
  target_tags   = ["allow-http"]

  description = "Allow access to Collector self-telemetry metrics"
}
