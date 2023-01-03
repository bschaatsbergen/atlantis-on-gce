locals {
  zone = var.zone != null ? var.zone : data.google_compute_zones.available.names[0]
  // The default port that Atlantis runs on is 4141.
  atlantis_port = lookup(var.env_vars, "ATLANTIS_PORT", 4141)
  // Atlantis its home directory is "/home/atlantis".
  atlantis_data_dir = lookup(var.env_vars, "ATLANTIS_DATA_DIR", "/home/atlantis")
}

data "cloudinit_config" "atlantis" {
  gzip          = true
  base64_encode = true

  # We store the provided environment variables in a .env file on the boot disk
  part {
    filename     = "server.env"
    content_type = "text/cloud-config"
    merge_type   = "list(append)+dict(no_replace, recurse_list)+str()"
    content = yamlencode({
      write_files = [
        {
          path        = "/etc/atlantis/server.env"
          permissions = "0644"
          owner       = "root"
          content     = join("", formatlist("%s=%s\n", keys(var.env_vars), values(var.env_vars)))
        }
      ]
    })
  }

  # We specify a service that changes the owner of the mounted GCE Persistent Disk to the atlantis user
  part {
    filename     = "atlantis-chown-disk.service"
    content_type = "text/cloud-config"
    merge_type   = "list(append)+dict(no_replace, recurse_list)+str()"
    content = yamlencode({
      write_files = [
        {
          path        = "/etc/systemd/system/atlantis-chown-disk.service"
          permissions = "0644"
          owner       = "root"
          content     = <<EOF
            [Unit]
            Description=Chown the Atlantis mount
            Wants=konlet-startup.service
            After=konlet-startup.service

            [Service]
            ExecStart=/bin/chown 100 /mnt/disks/gce-containers-mounts/gce-persistent-disks/atlantis-disk-0
            Restart=on-failure
            RestartSec=30
            StandardOutput=journal+console

            [Install]
            WantedBy=multi-user.target
          EOF
        }
      ]
    })
  }

  // We start the service
  part {
    filename     = "runcmda"
    content_type = "text/cloud-config"
    merge_type   = "list(append)+dict(no_replace, recurse_list)+str()"
    content = yamlencode({
      runcmd = [
        "systemctl daemon-reload",
        "systemctl start --no-block atlantis-chown-disk.service"
      ]
    })
  }
}

data "google_compute_zones" "available" {
  status = "UP"
  region = var.region
}

data "google_compute_image" "cos" {
  family  = "cos-stable"
  project = "cos-cloud"
}

resource "google_compute_disk" "atlantis" {
  name = var.name
  type = "pd-ssd"
  zone = local.zone
  size = 25
}

resource "google_compute_instance_template" "atlantis" {
  # checkov:skip=CKV_GCP_32:Ensure 'Block Project-wide SSH keys' is enabled for VM instances
  name_prefix = "${var.name}-"
  description = "This template is used to create VMs that run Atlantis in a containerized environment using Docker"
  region      = var.region

  tags = ["atlantis"]

  metadata = {
    "gce-container-declaration" = module.atlantis.metadata_value
    "google-logging-enabled"    = true
    "block-project-ssh-keys"    = var.block_project_ssh_keys
    "user-data"                 = data.cloudinit_config.atlantis.rendered
  }

  labels = {
    "container-vm" = module.atlantis.vm_container_label
  }

  instance_description = "VM running Atlantis in a containerized environment using Docker"
  machine_type         = var.machine_type
  can_ip_forward       = false

  // Using the below scheduling configuration,
  // the managed instance group will recreate the Spot VM if Compute Engine stops them
  scheduling {
    automatic_restart           = var.use_spot_machine ? false : true
    preemptible                 = var.use_spot_machine ? true : false
    provisioning_model          = var.use_spot_machine ? "SPOT" : "STANDARD"
    on_host_maintenance         = var.use_spot_machine ? "TERMINATE" : "MIGRATE"
    instance_termination_action = var.use_spot_machine ? "STOP" : null
  }

  // Ephemeral OS boot disk
  disk {
    source_image = data.google_compute_image.cos.self_link
    auto_delete  = true
    boot         = true
    disk_type    = "pd-ssd"
    disk_size_gb = 10

    dynamic "disk_encryption_key" {
      for_each = var.disk_kms_key_self_link != null ? [1] : []
      content {
        kms_key_self_link = var.disk_kms_key_self_link
      }
    }
  }

  // Persistent data disk for Atlantis
  disk {
    source      = google_compute_disk.atlantis.name
    boot        = false
    mode        = "READ_WRITE"
    device_name = "atlantis-disk-0"
    auto_delete = false
  }

  network_interface {
    subnetwork = var.subnetwork
  }

  shielded_instance_config {
    enable_integrity_monitoring = true
    enable_vtpm                 = true
  }

  service_account {
    email  = var.service_account.email
    scopes = var.service_account.scopes
  }

  // Instance Templates cannot be updated after creation with the Google Cloud Platform API. 
  // In order to update an Instance Template, Terraform will destroy the existing resource and create a replacement
  lifecycle {
    create_before_destroy = true
  }
}

module "atlantis" {
  source  = "terraform-google-modules/container-vm/google"
  version = "~> 2.0"

  container = {
    image   = var.image
    envFile = "/etc/atlantis/server.env"
    securityContext = {
      privileged : true
    }
    tty : true

    # Declare volumes to be mounted.
    # This is similar to how docker volumes are declared.
    volumeMounts = [
      {
        mountPath = local.atlantis_data_dir
        name      = "atlantis-disk-0"
        readOnly  = false
      },
    ]
  }

  volumes = [
    {
      name = "atlantis-disk-0"

      gcePersistentDisk = {
        pdName = "atlantis-disk-0"
        fsType = "ext4"
      }
    },
  ]

  restart_policy = "Always"
}

resource "google_compute_health_check" "atlantis" {
  name                = var.name
  check_interval_sec  = 1
  timeout_sec         = 1
  healthy_threshold   = 4
  unhealthy_threshold = 5

  tcp_health_check {
    port = local.atlantis_port
  }
}

resource "google_compute_instance_group_manager" "atlantis" {
  name               = var.name
  base_instance_name = var.name
  zone               = local.zone
  description        = "Instance group manager responsible for managing the VM running Atlantis in a containerized environment using Docker"

  version {
    instance_template = google_compute_instance_template.atlantis.id
  }

  target_size = 1

  named_port {
    name = "http"
    port = local.atlantis_port
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.atlantis.id
    initial_delay_sec = 60
  }

  update_policy {
    type                           = "PROACTIVE"
    minimal_action                 = "RESTART"
    most_disruptive_allowed_action = "REPLACE"
    max_surge_fixed                = 0
    max_unavailable_fixed          = 5
    replacement_method             = "RECREATE"
  }
}

resource "google_compute_global_address" "atlantis" {
  name = var.name
}

resource "google_compute_managed_ssl_certificate" "atlantis" {
  name = var.name
  managed {
    domains = ["${var.domain}"]
  }
}

resource "google_compute_backend_service" "atlantis" {
  name                  = "${var.name}-backend"
  protocol              = "HTTP"
  port_name             = "http"
  timeout_sec           = "30"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  health_checks         = [google_compute_health_check.atlantis.id]

  log_config {
    enable = true
  }

  backend {
    balancing_mode  = "UTILIZATION"
    max_utilization = 0.8
    group           = google_compute_instance_group_manager.atlantis.instance_group
  }
}

resource "google_compute_url_map" "atlantis" {
  name = "${var.name}-map"

  default_service = google_compute_backend_service.atlantis.id

  host_rule {
    hosts        = ["${var.domain}"]
    path_matcher = var.name
  }

  path_matcher {
    name            = var.name
    default_service = google_compute_backend_service.atlantis.id
  }
}

resource "google_compute_url_map" "https_redirect" {
  name = "${var.name}-https-redirect-map"
  default_url_redirect {
    https_redirect         = true
    strip_query            = false
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
  }
}

resource "google_compute_target_http_proxy" "atlantis" {
  name    = "${var.name}-http-proxy"
  url_map = google_compute_url_map.https_redirect.id
}

resource "google_compute_target_https_proxy" "atlantis" {
  name    = "${var.name}-https-proxy"
  url_map = google_compute_url_map.atlantis.id
  ssl_certificates = [
    google_compute_managed_ssl_certificate.atlantis.id,
  ]
}

resource "google_compute_global_forwarding_rule" "http" {
  name                  = "${var.name}-http-lb"
  target                = google_compute_target_http_proxy.atlantis.id
  port_range            = "80"
  ip_address            = google_compute_global_address.atlantis.address
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

resource "google_compute_global_forwarding_rule" "https" {
  name                  = "${var.name}-https-lb"
  target                = google_compute_target_https_proxy.atlantis.id
  port_range            = "443"
  ip_address            = google_compute_global_address.atlantis.address
  load_balancing_scheme = "EXTERNAL_MANAGED"
}
