data "hcloud_ssh_key" "selected" {
  name = var.ssh_key_name
}

resource "hcloud_firewall" "wordpress" {
  name = "${var.server_name}-firewall"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = var.ssh_allowed_cidrs
  }

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "80"
    source_ips = [
      "0.0.0.0/0",
      "::/0",
    ]
  }

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "443"
    source_ips = [
      "0.0.0.0/0",
      "::/0",
    ]
  }

  rule {
    direction = "in"
    protocol  = "icmp"
    source_ips = [
      "0.0.0.0/0",
      "::/0",
    ]
  }
}

resource "hcloud_server" "wordpress" {
  name        = var.server_name
  server_type = var.server_type
  image       = var.server_image
  location    = var.location
  ssh_keys    = [data.hcloud_ssh_key.selected.id]
  firewall_ids = [
    hcloud_firewall.wordpress.id,
  ]

  backups            = var.enable_backups
  delete_protection  = var.enable_server_protection
  rebuild_protection = var.enable_server_protection
  labels             = var.server_labels

  public_net {
    ipv4_enabled = true
    ipv6_enabled = var.enable_ipv6
  }
}
