mock_provider "hcloud" {
  mock_data "hcloud_ssh_key" {
    defaults = { id = "100" }
  }
}

override_resource {
  target = hcloud_firewall.wordpress
  values = { id = "101" }
}

override_resource {
  target = hcloud_firewall.ssh
  values = { id = "102" }
}

run "cloudflare_web_ingress" {
  command = apply

  variables {
    ssh_key_name      = "test-key"
    ssh_allowed_cidrs = ["203.0.113.10/32"]
  }

  assert {
    condition = alltrue([
      for rule in hcloud_firewall.wordpress.rule :
      toset(rule.source_ips) == toset(local.web_allowed_cidrs)
      if contains(["80", "443"], rule.port)
      ]) && length([
      for rule in hcloud_firewall.wordpress.rule : rule
      if rule.direction == "in" && rule.protocol == "tcp" && contains(["80", "443"], rule.port)
    ]) == 2
    error_message = "Both web ports must accept exactly the reviewed Cloudflare IPv4 and IPv6 ranges."
  }

  assert {
    condition = alltrue([
      for rule in hcloud_firewall.ssh.rule :
      toset(rule.source_ips) == toset(var.ssh_allowed_cidrs)
      if rule.port == "22"
    ]) && length(hcloud_firewall.ssh.rule) == 1
    error_message = "The separate SSH firewall must be seeded with the operator CIDRs."
  }

  assert {
    condition = alltrue([
      for rule in hcloud_firewall.wordpress.rule : rule.port != "22"
    ])
    error_message = "The web firewall must not manage SSH rules."
  }

  assert {
    condition = toset(hcloud_server.wordpress.firewall_ids) == toset([
      tonumber(hcloud_firewall.wordpress.id), tonumber(hcloud_firewall.ssh.id),
    ])
    error_message = "Both web and SSH firewalls must be attached to the server."
  }
}

run "preserve_ssh_rules_after_creation" {
  command = plan

  variables {
    ssh_key_name      = "test-key"
    ssh_allowed_cidrs = ["198.51.100.20/32"]
  }

  assert {
    condition = alltrue([
      for rule in hcloud_firewall.ssh.rule :
      toset(rule.source_ips) == toset(["203.0.113.10/32"])
    ]) && length(hcloud_firewall.ssh.rule) == 1
    error_message = "Later applies must preserve existing SSH rules rather than restore the seed input."
  }
}

run "optional_ssh_inputs" {
  command   = plan
  state_key = "fresh"

  variables {
    ssh_allowed_cidrs = []
  }

  assert {
    condition     = var.ssh_key_name == "hetzner-wordpress" && length(hcloud_firewall.ssh.rule) == 0
    error_message = "The key name must default correctly and an empty seed must grant no SSH access."
  }
}
