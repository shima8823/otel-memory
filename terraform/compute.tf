locals {
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

// OTel Collector, Prometheus, Grafana, Jaeger を実行
resource "google_compute_instance" "collector_vm" {
  name                      = "otel-collector"
  machine_type              = var.collector_machine_type
  zone                      = var.zone
  tags                      = local.collector_tags
  labels                    = local.collector_labels
  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = 20
      type  = "pd-standard"
    }
  }

  network_interface {
    network = "default"

    access_config {
    }
  }

  metadata_startup_script = templatefile("${path.module}/startup-script-collector.sh", {
    git_repo_url = "https://github.com/shima8823/otel-memory.git"
  })
}

// 負荷生成ツール (loadgen) を実行
resource "google_compute_instance" "loadgen_vm" {
  name                      = "otel-loadgen"
  machine_type              = var.loadgen_machine_type
  zone                      = var.zone
  tags                      = local.loadgen_tags
  labels                    = local.loadgen_labels
  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = 20
      type  = "pd-standard"
    }
  }

  network_interface {
    network = "default"

    access_config {
    }
  }

  metadata_startup_script = templatefile("${path.module}/startup-script-loadgen.sh", {
    git_repo_url          = "https://github.com/shima8823/otel-memory.git"
    collector_internal_ip = google_compute_instance.collector_vm.network_interface[0].network_ip
  })
}
