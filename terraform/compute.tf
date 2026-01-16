// OTel Collector, Prometheus, Grafana, Jaeger を実行
resource "google_compute_instance" "collector_vm" {
  name         = "otel-collector"
  machine_type = var.collector_machine_type
  zone         = var.zone

  tags = local.collector_tags

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = 30
      type  = "pd-standard"
    }
  }

  network_interface {
    network = "default"

    access_config {
    }
  }

  metadata_startup_script = templatefile("${path.module}/startup-script.sh", {
    git_repo_url = "https://github.com/shima8823/otel-memory.git"
  })

  allow_stopping_for_update = true

  labels = local.collector_labels
}

// 負荷生成ツール (loadgen) を実行
resource "google_compute_instance" "loadgen_vm" {
  name         = "otel-loadgen"
  machine_type = var.loadgen_machine_type
  zone         = var.zone

  tags = local.loadgen_tags

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

  allow_stopping_for_update = true

  depends_on = [google_compute_instance.collector_vm]

  labels = local.loadgen_labels
}
