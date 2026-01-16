// ====================
// Collector VM
// ====================
// OTel Collector, Prometheus, Grafana, Jaeger を実行
resource "google_compute_instance" "collector_vm" {
  name         = var.collector_instance_name
  machine_type = var.collector_machine_type
  zone         = var.zone

  tags = local.collector_tags

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = var.collector_boot_disk_size
      type  = "pd-standard"
    }
  }

  network_interface {
    network = var.network_name

    access_config {
      // Ephemeral public IP
    }
  }

  metadata = {
    ssh-keys = local.ssh_keys_metadata
  }

  metadata_startup_script = templatefile("${path.module}/startup-script.sh", {
    git_repo_url = var.git_repo_url
  })

  allow_stopping_for_update = true

  labels = local.collector_labels
}

// ====================
// Loadgen VM
// ====================
// 負荷生成ツール (loadgen) を実行
resource "google_compute_instance" "loadgen_vm" {
  name         = var.loadgen_instance_name
  machine_type = var.loadgen_machine_type
  zone         = var.zone

  tags = local.loadgen_tags

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = var.loadgen_boot_disk_size
      type  = "pd-standard"
    }
  }

  network_interface {
    network = var.network_name

    access_config {
      // Ephemeral public IP
    }
  }

  metadata = {
    ssh-keys = local.ssh_keys_metadata
  }

  metadata_startup_script = templatefile("${path.module}/startup-script-loadgen.sh", {
    git_repo_url          = var.git_repo_url
    collector_internal_ip = google_compute_instance.collector_vm.network_interface[0].network_ip
  })

  allow_stopping_for_update = true

  // Collector VMが先に作成されるよう依存関係を設定
  depends_on = [google_compute_instance.collector_vm]

  labels = local.loadgen_labels
}
