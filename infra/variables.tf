variable "server_name" {
  description = "Name of the Hetzner Cloud server."
  type        = string
  default     = "wordpress-prod"

  validation {
    condition = (
      length(var.server_name) <= 63 &&
      can(regex("^[a-z0-9]+(-[a-z0-9]+)*$", var.server_name))
    )
    error_message = "The server name must use lowercase letters, digits, and single hyphens."
  }
}

variable "server_type" {
  description = "Hetzner Cloud server type."
  type        = string
  default     = "cx23"

  validation {
    condition     = length(trimspace(var.server_type)) > 0
    error_message = "The server type cannot be empty."
  }
}

variable "server_image" {
  description = "Hetzner Cloud operating-system image."
  type        = string
  default     = "ubuntu-24.04"

  validation {
    condition     = length(trimspace(var.server_image)) > 0
    error_message = "The server image cannot be empty."
  }
}

variable "location" {
  description = "Hetzner Cloud location."
  type        = string
  default     = "nbg1"

  validation {
    condition     = can(regex("^[a-z0-9]+(-[a-z0-9]+)*$", var.location))
    error_message = "The location must be a valid Hetzner location name."
  }
}

variable "ssh_key_name" {
  description = "Name of an existing SSH key in the Hetzner Cloud project."
  type        = string

  validation {
    condition     = length(trimspace(var.ssh_key_name)) > 0
    error_message = "The SSH key name cannot be empty."
  }
}

variable "ssh_allowed_cidrs" {
  description = "IPv4 or IPv6 CIDR ranges allowed to connect to SSH port 22."
  type        = list(string)

  validation {
    condition = (
      length(var.ssh_allowed_cidrs) > 0 &&
      alltrue([for cidr in var.ssh_allowed_cidrs : can(cidrhost(cidr, 0))]) &&
      !contains(var.ssh_allowed_cidrs, "0.0.0.0/0") &&
      !contains(var.ssh_allowed_cidrs, "::/0")
    )
    error_message = "Provide at least one valid CIDR. Public SSH access from all addresses is not allowed."
  }
}

variable "enable_ipv6" {
  description = "Enable a public IPv6 address on the server."
  type        = bool
  default     = true
}

variable "enable_backups" {
  description = "Enable paid Hetzner server backups in addition to application backups."
  type        = bool
  default     = false
}

variable "enable_server_protection" {
  description = "Protect the server from deletion and rebuild operations."
  type        = bool
  default     = true
}

variable "server_labels" {
  description = "Labels assigned to the Hetzner Cloud server."
  type        = map(string)
  default = {
    managed_by = "terraform"
    project    = "wordpress"
  }
}
