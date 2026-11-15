# Hetzner Infrastructure

[Project overview](../README.md)

Terraform creates one Hetzner Cloud server and separate web and SSH firewalls.
Cloud-init installs Docker and runtime tools, then clones this repository into
`/opt/wordpress`.
Cloudflare DNS and TLS settings are managed separately.

Terraform and provider versions are pinned in `mise.toml` and `versions.tf`.
Authentication uses the `HCLOUD_TOKEN` environment variable. Non-secret inputs
are documented in [terraform.tfvars.example](terraform.tfvars.example), including
the existing Hetzner SSH key and repository branch or tag. All inputs have defaults;
`ssh_key_name` defaults to `hetzner-wordpress`, the uploaded public key's name,
not its fingerprint. The key initializes access when a server is created.
Terraform state and local input files are gitignored.

## Remote state in HCP Terraform

State is stored in the `jarovasak/wordpress-hetzner` workspace on `app.terraform.io`,
with execution mode **Local**. Terraform runs on the workstation using local
inputs and `HCLOUD_TOKEN`; HCP stores, versions, and locks the state.

The organization and workspace are configured in [backend.tf](backend.tf).
Each workstation needs its own Terraform CLI login. Credentials stay outside
the repository.

The existing state has already been uploaded. Other checkouts connect to that
same workspace; they do not need another migration or a copy of the old local
state. CI uses `init -backend=false` and needs no HCP credentials.

## Cloudflare-only web access

TCP ports 80 and 443 accept only Cloudflare's IPv4 and IPv6 ranges from
[cloudflare-ips.json](cloudflare-ips.json). ICMP remains public. The policy applies
to every website on the server.

SSH rules belong to the separate `<server_name>-ssh` firewall and are managed in
the Hetzner GUI. Terraform creates and attaches this firewall but ignores later
rule changes. Optional `ssh_allowed_cidrs` seeds its rules only at creation;
the default empty list grants no SSH access until a rule is added in the GUI.
The original combined firewall no longer contains SSH rules. Other existing
SSH rules are not automatically copied into the new firewall.

All public website hostnames require proxied Cloudflare DNS records (orange
cloud). Direct origin access and DNS-only website records are blocked. The
expected Cloudflare TLS mode is **Full (strict)**, using Traefik's existing
Let's Encrypt certificates. DNS-01 certificate renewal needs no public inbound
HTTP access.

The IP list is maintained manually from [Cloudflare's official ranges](https://www.cloudflare.com/ips/).
Changes are infrequent; there is no scheduled updater or network fetch during
Terraform runs. A list change takes effect on the server only after a Terraform
apply. IP filtering allows Cloudflare's network; account-specific authentication
through Authenticated Origin Pulls is not configured.

## Infrastructure lifecycle

Cloud-init runs only on first boot. Editing its template does not update an
existing host, and a `user_data` change can require server replacement. The
Bitwarden CLI version and download checksums are pinned in `server.tf`.

Server deletion and rebuild protection are enabled by default through
`enable_server_protection`. Hetzner backups are optional and do not replace
application backups. The HCP state tracks the existing resources across
workstations.
