terraform {
  backend "remote" {
    hostname = "app.terraform.io"

    workspaces {
      name = "wordpress-hetzner"
    }
  }
}
