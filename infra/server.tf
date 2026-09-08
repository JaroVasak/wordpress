data "hcloud_ssh_key" "selected" {
  name = var.ssh_key_name
}

locals {
  bws_version = "2.1.0"
  bws_checksums = {
    aarch64 = "18253757286e119d450133a87eb463bf8c1ce418ce24c834f4f250d60cba6f9e"
    x86_64  = "ba8233c3a4aee5d43e3c73bbd04d99e9bc5aba13bbbfd06d89b073abe732b860"
  }
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
  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    bws_version           = local.bws_version
    bws_checksum_aarch64  = local.bws_checksums.aarch64
    bws_checksum_x86_64   = local.bws_checksums.x86_64
    repository_ref_base64 = base64encode(var.repository_ref)
    repository_url_base64 = base64encode(var.repository_url)
  })

  public_net {
    ipv4_enabled = true
    ipv6_enabled = var.enable_ipv6
  }
}
