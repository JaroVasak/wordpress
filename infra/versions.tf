terraform {
  required_version = "= 1.16.1"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "= 1.68.0"
    }
  }
}
