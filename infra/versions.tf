terraform {
  required_version = "= 1.17.2"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "= 1.70.2"
    }
  }
}
