terraform {
  backend "remote" {
    hostname     = "app.terraform.io"
    organization = "jarovasak"

    workspaces {
      name = "wordpress-hetzner"
    }
  }
}
