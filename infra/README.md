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

## Remote state in HCP Terraform

State is stored in the HCP Terraform workspace `wordpress-hetzner`. Set its
execution mode to **Local** so Terraform runs on your workstation and uses your
local inputs and `HCLOUD_TOKEN`. HCP Terraform stores and locks the state.
The organization name is supplied during initialization. Do not put API tokens
in Terraform configuration, backend arguments, or Git.

### Create the HCP workspace

1. Create an account at [HCP Terraform](https://app.terraform.io/) and enable
   multi-factor authentication.
2. Create an organization and select the **Free** plan. Record its organization
   name. The current Free plan supports up to 500 managed resources.
3. Create a **CLI-driven** workspace named `wordpress-hetzner`. Do not connect
   it to GitHub or run Terraform in it yet.
4. Under the workspace's **Settings > General**, set **Execution Mode** to
   **Local** and the Terraform version to **1.17.2**. Save the settings before
   migration. Keep the workspace empty until the existing state is migrated.

These instructions use `app.terraform.io`, as configured in `backend.tf`. An
HCP Europe organization uses a different hostname; update the backend hostname
and login command to match before initialization.

### Migrate existing local state once

Run this procedure on the workstation that has `infra/terraform.tfstate`.
Stop other Terraform operations for this infrastructure until verification is
complete. A fresh clone without that file cannot migrate the existing state.

1. From the repository root, install and verify the pinned Terraform version:

   ```bash
   mise install
   mise exec -- terraform version
   ```

2. Make a protected backup before initializing the backend:

   ```bash
   test -s infra/terraform.tfstate
   mkdir -p backups
   install -m 600 infra/terraform.tfstate "backups/terraform-before-hcp-$(date +%Y%m%d-%H%M%S).tfstate"
   ```

   Confirm both commands succeed before continuing. The `backups/` directory
   and Terraform state files are ignored by Git. Keep a separate encrypted
   recovery copy outside this workstation. State can contain sensitive data.

3. Authenticate through Terraform's browser login. Do not paste the token into
   a terminal command, repository file, or pull request:

   ```bash
   mise exec -- terraform login app.terraform.io
   ```

4. Replace `YOUR_HCP_ORGANIZATION` with the organization name, then migrate:

   ```bash
   mise exec -- terraform -chdir=infra init -migrate-state \
     -backend-config="organization=YOUR_HCP_ORGANIZATION"
   ```

   Confirm that the destination is the empty `wordpress-hetzner` workspace in
   your organization before accepting the state-copy prompt. Stop if the
   destination already contains state or Terraform does not offer to copy the
   existing local state. Do not use `-force-copy` or `-reconfigure` to bypass
   the migration prompt. This step copies state; it does not apply resources.

5. Verify that HCP shows a state version and the expected resources. List the
   migrated resource addresses, then run a plan from your usual secret-enabled
   shell with `HCLOUD_TOKEN` available:

   ```bash
   mise exec -- terraform -chdir=infra state list
   mise exec -- terraform -chdir=infra plan
   ```

   Review any proposed changes. Repository changes made since the last apply
   can cause differences unrelated to the backend. If resources are missing
   or the plan proposes unexpected creation, deletion, or replacement, stop
   and investigate. Migration does not require an apply. Keep the recovery
   backup until the migrated state and plan have been verified.

### Initialize another checkout

After migration, authenticate with `terraform login` through Mise as above,
then run:

```bash
mise install
mise exec -- terraform -chdir=infra init \
  -backend-config="organization=YOUR_HCP_ORGANIZATION"
```

Use the same organization and workspace. Do not copy the old local state into
another checkout or initialize a second workspace for these resources. Later
commands use the cached backend settings. CI uses `init -backend=false` for
validation and does not require an HCP token or access to the state.

See the official [remote backend documentation](https://developer.hashicorp.com/terraform/language/backend/remote)
and [state migration guidance](https://developer.hashicorp.com/terraform/cloud-docs/migrate).

## Provisioning and maintenance

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
terraform init -backend-config="organization=YOUR_HCP_ORGANIZATION"
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
