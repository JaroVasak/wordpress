# Hetzner Infrastructure

[Project overview](../README.md)

Commands below start from the repository root on your workstation, except for
the SSH session, which runs on the server.

Terraform configuration under `infra/` creates one Hetzner Cloud server and an
attached firewall. Cloud-init prepares Ubuntu, installs Docker and the runtime
tools, and clones this repository into `/opt/wordpress`. Terraform uses an
existing SSH key from the selected Hetzner Cloud project. Cloudflare resources
are not managed by this configuration.

The configuration pins Terraform in `mise.toml` and `infra/versions.tf` and reads
the Hetzner API token from the `HCLOUD_TOKEN` environment variable. The token is
never stored in a Terraform input file.

Prepare the inputs:

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
```

Set `ssh_key_name` to a key already uploaded to the Hetzner project. Replace
the documentation address in `ssh_allowed_cidrs` with your current public IP
using `/32` for IPv4 or `/128` for IPv6. SSH access from the whole internet is
rejected by input validation. Change `repository_url` if you use a fork, and
set `repository_ref` to the branch or tag that the server must clone.

Review the infrastructure before creating resources:

```bash
terraform init
terraform fmt -check
terraform validate
terraform plan
```

Run these commands in an environment where the selected secret manager has
injected `HCLOUD_TOKEN`. Terraform reads it directly.

After reviewing the plan, apply the configuration:

```bash
terraform apply
```

The server IPv4 and IPv6 addresses are Terraform outputs. Add the required DNS
records to the existing Cloudflare zone, then continue with the
[shared stack setup](../shared/README.md#base-stack-setup).

Cloud-init runs during the first server boot. Wait for it before you run the
application scripts:

```bash
ssh root@SERVER_IPV4
cloud-init status --wait
cd /opt/wordpress
./scripts/bws-shell.sh
```

The host setup installs CA certificates, cron, curl, Git, gzip, OpenSSL,
ShellCheck, unzip, Docker Engine, the Docker Compose plugin, and the Bitwarden
Secrets Manager CLI. The `bws` version and its official Linux checksums are
pinned in `infra/server.tf`. No access token or application secret is included
in cloud-init or Terraform state.

Cloud-init is a first-boot installer. A later change to the cloud-init template
does not update an existing server. Review the Terraform plan carefully because
a `user_data` change can require server replacement.

Server deletion and rebuild protection are enabled by default. To destroy the
PoC later, set `enable_server_protection = false`, apply that change, and only
then run `terraform destroy`.
