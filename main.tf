locals {
  // The default port that Atlantis runs on is 4141.
  atlantis_port = lookup(var.env_vars, "ATLANTIS_PORT", 4141)
  // Atlantis its home directory is "/home/atlantis".
  atlantis_data_dir = lookup(var.env_vars, "ATLANTIS_DATA_DIR", "/home/atlantis")
  port_name         = "atlantis"
}

data "google_compute_image" "cos" {
  family  = "cos-stable"
  project = "cos-cloud"
}

resource "google_compute_instance_template" "atlantis" {
  # checkov:skip=CKV_GCP_32:Ensure 'Block Project-wide SSH keys' is enabled for VM instances
  name_prefix = "${var.name}-"
  description = "This template is used to create VMs that run Atlantis in a containerized environment using Docker"
  region      = var.region

  tags = ["atlantis"]

  metadata_startup_script = templatefile("${path.module}/startup-script.sh", { disk_name = "atlantis-disk-0" })

  metadata = {
    "gce-container-declaration" = module.atlantis.metadata_value
    "google-logging-enabled"    = true
    "block-project-ssh-keys"    = var.block_project_ssh_keys
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

  // Persistent disk for Atlantis
  disk {
    device_name  = "atlantis-disk-0"
    disk_type    = "pd-ssd"
    mode         = "READ_WRITE"
    disk_size_gb = var.persistent_disk_size_gb
    auto_delete  = false

    dynamic "disk_encryption_key" {
      for_each = var.disk_kms_key_self_link != null ? [1] : []
      content {
        kms_key_self_link = var.disk_kms_key_self_link
      }
    }
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

  project = var.project

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
    image = var.image
    securityContext = {
      privileged : true
    }
    tty : true
    env = [for key, value in var.env_vars : {
      name  = key
      value = value
    }]

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

  project = var.project
}

resource "google_compute_health_check" "atlantis_mig" {
  name                = "${var.name}-mig"
  healthy_threshold   = 4
  unhealthy_threshold = 5

  http_health_check {
    port         = local.atlantis_port
    request_path = "/healthz"
  }

  project = var.project
}

resource "google_compute_firewall" "atlantis" {
  ## firewall rules enabling the load balancer health checks
  name    = var.name
  network = var.network

  description = "allow health checks and load balancers access to Atlantis"

  allow {
    protocol = "icmp"
  }

  allow {
    protocol = "tcp"
    ports    = [local.atlantis_port]
  }

  source_ranges = ["35.191.0.0/16", "130.211.0.0/22", "209.85.152.0/22", "209.85.204.0/22"]
  target_tags   = ["atlantis"]
}

resource "google_compute_instance_group_manager" "atlantis" {
  name               = var.name
  base_instance_name = var.name
  zone               = var.zone
  description        = "Instance group manager responsible for managing the VM running Atlantis in a containerized environment using Docker"

  version {
    instance_template = google_compute_instance_template.atlantis.id
  }


  named_port {
    name = local.port_name
    port = local.atlantis_port
  }

  stateful_disk {
    device_name = "atlantis-disk-0"
    delete_rule = "NEVER"
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.atlantis_mig.id
    initial_delay_sec = 30
  }

  target_size = 1

  update_policy {
    type                           = "PROACTIVE"
    minimal_action                 = "RESTART"
    most_disruptive_allowed_action = "REPLACE"
    max_surge_fixed                = 0
    max_unavailable_fixed          = 1
    replacement_method             = "RECREATE"
  }
  project = var.project
}

resource "google_compute_global_address" "atlantis" {
  name    = var.name
  project = var.project
}

resource "google_compute_managed_ssl_certificate" "atlantis" {
  name = var.name
  managed {
    domains = ["${var.domain}"]
  }
  project = var.project
}

resource "google_compute_backend_service" "atlantis" {
  name                  = var.name
  protocol              = "HTTP"
  port_name             = local.port_name
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
  project = var.project
}

resource "google_compute_url_map" "atlantis" {
  name            = var.name
  default_service = google_compute_backend_service.atlantis.id
  project         = var.project
}

resource "google_compute_target_https_proxy" "atlantis" {
  name    = var.name
  url_map = google_compute_url_map.atlantis.id
  ssl_certificates = [
    google_compute_managed_ssl_certificate.atlantis.id,
  ]
  project = var.project
}

resource "google_compute_global_forwarding_rule" "https" {
  name                  = var.name
  target                = google_compute_target_https_proxy.atlantis.id
  port_range            = "443"
  ip_address            = google_compute_global_address.atlantis.address
  load_balancing_scheme = "EXTERNAL_MANAGED"
  project               = var.project
}

# Route public internet traffic to the default internet gateway
resource "google_compute_route" "public_internet" {
  network          = var.network
  name             = "${var.name}-public-internet"
  description      = "Custom static route for Altantis to communicate with the public internet"
  dest_range       = "0.0.0.0/0"
  next_hop_gateway = "default-internet-gateway"
  priority         = 0
  project          = var.project
  tags             = ["atlantis"]
}

# This firewall rule allows Google Cloud to issue the health checks
resource "google_compute_firewall" "atlantis_lb_health_check" {
  name        = "${var.name}-lb-health-checks"
  description = "Firewall rule to allow inbound Google Load Balancer health checks to the Atlantis instance"
  priority    = 0
  direction   = "INGRESS"
  network     = var.network
  allow {
    protocol = "tcp"
  }
  # These are the source IP ranges for health checks (managed by Google Cloud)
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  project       = var.project
  target_tags   = ["atlantis"]
}
