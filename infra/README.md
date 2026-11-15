# Hetzner Infrastructure

[Project overview](../README.md)

Terraform creates one Hetzner Cloud server and its firewall. Cloud-init installs
Docker and runtime tools, then clones this repository into `/opt/wordpress`.
Cloudflare DNS and TLS settings are managed separately.

Terraform and provider versions are pinned in `mise.toml` and `versions.tf`.
Non-secret inputs are documented in
[terraform.tfvars.example](terraform.tfvars.example), including the Hetzner SSH
key, allowed SSH CIDRs, and repository branch or tag. Provider authentication
uses `HCLOUD_TOKEN` from the environment.

## Remote state in HCP Terraform

State is stored in the `wordpress-hetzner` workspace on `app.terraform.io`,
with execution mode **Local**. Terraform runs on the workstation using local
inputs and `HCLOUD_TOKEN`; HCP stores, versions, and locks the state.

The organization is supplied at initialization with
`-backend-config="organization=YOUR_HCP_ORGANIZATION"`. Each workstation needs
its own Terraform CLI login. Credentials stay outside the repository.

The existing state has already been uploaded. Other checkouts connect to that
same workspace; they do not need another migration or a copy of the old local
state. CI uses `init -backend=false` and needs no HCP credentials.

## Infrastructure lifecycle

Cloud-init runs only on first boot. Editing its template does not update an
existing host, and changing `user_data` can require server replacement. The
Bitwarden CLI version and download checksums are pinned in `server.tf`.

Server deletion and rebuild protection are enabled by default through
`enable_server_protection`. Hetzner backups are optional and do not replace
application backups. Terraform state, local inputs, and runtime secrets are
excluded from Git.

See the [remote backend documentation](https://developer.hashicorp.com/terraform/language/backend/remote)
for connection details, and the [shared services guide](../shared/README.md)
for the application stack.
