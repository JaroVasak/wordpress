output "server_id" {
  description = "Hetzner Cloud server ID."
  value       = hcloud_server.wordpress.id
}

output "server_name" {
  description = "Hetzner Cloud server name."
  value       = hcloud_server.wordpress.name
}

output "server_ipv4_address" {
  description = "Public IPv4 address to configure in Cloudflare DNS."
  value       = hcloud_server.wordpress.ipv4_address
}

output "server_ipv6_address" {
  description = "Public IPv6 address to configure in Cloudflare DNS when IPv6 is enabled."
  value       = hcloud_server.wordpress.ipv6_address
}

output "server_status" {
  description = "Current Hetzner Cloud server status."
  value       = hcloud_server.wordpress.status
}

output "firewall_id" {
  description = "Hetzner Cloud firewall ID attached to the server."
  value       = hcloud_firewall.wordpress.id
}
