# WordPress + Traefik Docker Setup

Multi-site WordPress stack with Traefik v3 as reverse proxy, Cloudflare DNS challenge for SSL, and MariaDB as a shared database.

**For isolated local testing**, see [local/README.md](local/README.md). The local stack does not use the production Traefik or Cloudflare configuration.

## Structure

```
wordpress/
  infra/                      # Hetzner Terraform configuration
  local/                      # Isolated local-only stack
  shared/                     # Socket proxy + Traefik + MariaDB
  scripts/                    # Operator commands
    lib/                      # Internal shell libraries
  templates/
    site/                     # Source template for new sites
  sites/
    <site-name>/               # Provisioned sites created from the template
```

Executable files under `scripts/` are operator commands:

- `scripts/bws-shell.sh` starts an optional shell with Bitwarden secrets.
- `scripts/bootstrap.sh` initializes the shared infrastructure once per server.
- `scripts/new-site.sh` provisions one additional site and can be run repeatedly.
- `scripts/site-compose.sh` updates or recreates one existing site.
- `scripts/backup-site.sh` creates an on-demand database dump for one site.
- `scripts/install-backup-cron.sh` installs the daily database backup schedule.
- `scripts/validate.sh` checks scripts, Compose files, and Nginx configurations.

Files under `scripts/lib/` are sourced by the operator commands and are not run
directly.

The examples below run from the repository root. You can also change to the
`scripts/` directory and omit `scripts/` from each path. The scripts locate the
repository from their own file paths, so they work from any current directory.

## Architecture

Production requests follow this path:

```text
client -> Traefik -> site nginx -> WordPress PHP-FPM -> MariaDB
```

Traefik listens on ports 80 and 443. It discovers only site nginx services
that have `traefik.enable=true`. Each site has an internal network between
nginx and WordPress. All WordPress services use the shared MariaDB service
through the `db` network.

Persistent data is stored in these locations:

- `shared/mariadb/data/` contains the MariaDB data.
- `shared/traefik/acme.json` contains the ACME certificate data.
- `sites/<site>/wp-content/` contains site uploads, plugins, and themes.
- Each site has a `wordpress_files` volume shared by nginx and WordPress.

## Hetzner infrastructure

Terraform configuration under `infra/` creates one Hetzner Cloud server and an
attached firewall. It uses an existing SSH key from the selected Hetzner Cloud
project. Cloudflare resources are not managed by this configuration.

The configuration requires Terraform 1.16.1 and reads the Hetzner API token
from the `HCLOUD_TOKEN` environment variable. The token is never stored in a
Terraform input file.

Prepare the inputs:

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
```

Set `ssh_key_name` to a key already uploaded to the Hetzner project. Replace
the documentation address in `ssh_allowed_cidrs` with your current public IP
using `/32` for IPv4 or `/128` for IPv6. SSH access from the whole internet is
rejected by input validation.

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
records to the existing Cloudflare zone, then continue with the base stack
setup below.

Server deletion and rebuild protection are enabled by default. To destroy the
PoC later, set `enable_server_protection = false`, apply that change, and only
then run `terraform destroy`.

## Prerequisites

- Docker + Docker Compose
- A secret manager that can inject environment variables
- A Cloudflare account managing your domain(s)
- Domain(s) with DNS pointing to your server

---

## Secret management

The repository is independent of any secret-management vendor. Supply secrets
as environment variables before running Terraform or an operator script. The
secret manager, CI runner, or service manager is responsible for authentication
and injection.

| Environment variable | Consumer | Purpose |
|---|---|---|
| `HCLOUD_TOKEN` | Terraform | Hetzner infrastructure access |
| `CF_DNS_API_TOKEN` | `bootstrap.sh` | Traefik DNS-01 challenges |
| `MYSQL_ROOT_PASSWORD` | `bootstrap.sh` | MariaDB administration and backups |
| `<SITE>_DB_PASSWORD` | Site scripts | Password for one site's database user |

Secret names must be POSIX-compatible because scripts read them from the
environment. Give automation only the secrets it requires. Keep secret-manager
access credentials outside this repository.

### Optional Bitwarden Secrets Manager shell

The core scripts do not depend on Bitwarden. If you use Bitwarden Secrets
Manager, install the `bws` command and run:

```bash
./scripts/bws-shell.sh
```

The helper asks for the machine access token without showing it. It then starts
a clean interactive shell with all secrets that the machine account can read.
The helper does not need a project ID when the machine account has access to
only one project. It does not save the access token or secret values in the
repository. Run the required Terraform or operator commands in that shell, and
type `exit` when finished.

### ACME_EMAIL

Any email address you own. Let's Encrypt uses it only to notify you if a certificate is about to expire.

### CF_DNS_API_TOKEN

Traefik uses this token to answer the ACME DNS-01 challenge. It creates a
temporary TXT record to prove domain ownership and then removes it. The token
must have these permissions:

- `Zone / Zone / Read`
- `Zone / DNS / Edit`

**Steps to create it:**

1. Log in to **dash.cloudflare.com**
2. Top-right avatar → **My Profile** → **API Tokens**
3. Click **Create Token**
4. Use the **Edit zone DNS** template
5. Confirm that the token has the permissions listed above
6. Under **Zone Resources**, select only the zones served by this stack
   - Add a zone to the token before you provision a site for a new zone
7. Leave **TTL** empty (no expiry) — Traefik needs the token for renewals
8. Click **Continue to summary** → **Create Token**
9. **Copy the token immediately** — Cloudflare shows it only once

**Token security notes:**

- Scope the token to zone read and DNS edit access only
- Store it under the exact name `CF_DNS_API_TOKEN`
- Recreate the shared stack with `bootstrap.sh` after rotating the token

---

## 1. Base stack setup

```bash
./scripts/bootstrap.sh
```

Before running the script, inject `CF_DNS_API_TOKEN` and
`MYSQL_ROOT_PASSWORD`. If `ACME_EMAIL` is not set, the script asks for it. The
script confirms that the Cloudflare token is active, creates `shared/.env` and
`traefik/acme.json` with correct permissions, and starts the socket proxy,
Traefik, and MariaDB. It fails if the shared services do not become ready within
two minutes.

For unattended input, set the non-secret value before the command:

```bash
ACME_EMAIL=admin@example.com ./scripts/bootstrap.sh
```

`shared/.env` contains only non-secret configuration:

| Variable | Description |
|---|---|
| `ACME_EMAIL` | Email for Let's Encrypt notifications |

Compose receives the Cloudflare and MariaDB values from the environment and
mounts them only into the services that require them as read-only Docker
secrets.

If MariaDB already contains data, `MYSQL_ROOT_PASSWORD` must match the password
used when that data directory was initialized. Changing the container secret
does not change an existing MariaDB root password. For a new production server,
use the value stored in your secret manager from the first start.

### Automation input rules

The setup scripts reject values that could change paths, `.env` parsing, or SQL
statements:

- Site names use lowercase letters, digits, and single hyphens. Maximum: 63 characters.
- Domains must be lowercase, contain at least one dot, and use valid DNS labels.
- Database names use letters, digits, and underscores. Maximum: 64 characters.
- Database users use letters, digits, and underscores. Maximum: 32 characters.
- Database passwords contain 16–128 characters from `A-Z`, `a-z`, `0-9`, or `._~!@%^+=,:/-`.

---

## 2. Adding a new site

Before provisioning a site, add its database password to your secret manager.
Convert the site slug to uppercase, replace hyphens with underscores, and add
the `_DB_PASSWORD` suffix. For example:

```text
Site slug: example-com
Secret:    EXAMPLE_COM_DB_PASSWORD
```

Generate a separate value for every site. Each WordPress database user is
granted access only to its own database. It never uses the MariaDB root
password.

```bash
./scripts/new-site.sh
```

If a non-secret input is not set, the script asks for it. You can also supply
all non-secret inputs through the environment:

```bash
SITE_NAME=example-com \
DOMAIN=example.com \
DB_NAME=example_com \
DB_USER=example_com_user \
./scripts/new-site.sh
```

The script retrieves the matching site password from the environment. It checks
for existing Docker and MariaDB resources before it copies the template,
creates the database and user, and starts the site stack.

The script waits up to two minutes for the site containers. A startup or health
failure triggers the provisioning rollback.

After successful provisioning, the script prints the command that installs the
site's daily database backup schedule.

If provisioning fails, the script removes only resources created during that
run. If rollback cannot remove a database or Docker resource, it preserves the
site directory and reports the resources that need manual cleanup.

---

## Database backups

Create a compressed dump for one provisioned site:

```bash
./scripts/backup-site.sh example-com /var/backups/wordpress
```

The script reads only the database name from the site's `.env`, creates the
dump through the running MariaDB container, and keeps 14 days of matching dump
files by default. Set `BACKUP_RETENTION_DAYS` to a different positive number if
needed.

On an Ubuntu server, install the daily 03:00 backup schedule after the site is
provisioned:

```bash
sudo ./scripts/install-backup-cron.sh example-com
```

The installer writes `/etc/cron.d/wordpress-db-backup-example-com`, uses
`/var/backups/wordpress` by default, and creates the site backup directory with
owner-only permissions. Re-running it replaces only that site's schedule. Pass
a different absolute backup root and retention period when needed:

```bash
sudo ./scripts/install-backup-cron.sh example-com /mnt/backups/wordpress 30
```

The script backs up only the database. Back up each site's `wp-content`
separately and copy backups off the Docker host. Site `.env` files now contain
only non-secret configuration. WordPress generates authentication keys in its
persistent configuration when the container is initialized. Test a restore
before relying on the backups for recovery.

---

## Container image updates

Compose files use exact application version tags. This prevents an ordinary
restart from silently moving to a newer application release. Review release
notes, update the tag in every production and local Compose file that uses the
image, and test the local stack before a production update.

After injecting the site's database password, recreate an existing site after
an image or configuration change:

```bash
./scripts/site-compose.sh example-com up -d --wait
```

Version tags can still be changed in a container registry. Pin image digests as
well if deployments need immutable image content.

---

## Repository validation

Run all application-stack checks before provisioning or committing changes:

```bash
./scripts/validate.sh
```

The command checks Bash syntax, runs ShellCheck, renders every Compose file,
tests both Nginx configurations in the pinned Nginx image, and checks the Git
diff for whitespace errors. It does not start the WordPress stacks.

GitHub Actions runs the same command for pull requests, pushes to `main`, and
manual workflow runs. It also checks Terraform formatting and validates the
Hetzner configuration. The workflow has read-only repository access and does
not receive Hetzner credentials, so it cannot create or change cloud resources.

---

## Container logs

Every service uses Docker's `json-file` logging driver. Each container keeps up
to three 10 MB log files. This limits local disk use while preserving support
for `docker compose logs`.

---

## Networks

| Network    | Purpose                                      |
|------------|----------------------------------------------|
| `proxy`    | Traefik ↔ nginx (public-facing)              |
| `db`       | MariaDB ↔ WordPress FPM (database access)    |
| `internal` | nginx ↔ WordPress FPM within a site (no external access) |

## Nginx request safeguards

The production and local Nginx configurations:

- Reject hidden files, direct `wp-config.php` access, and PHP under upload directories.
- Reject requests for PHP scripts that do not exist on disk.
- Add common content-type, clickjacking, and referrer security headers.
- Compress suitable text responses with a moderate gzip level.
- Cache static assets for 30 days and omit them from access logs.
- Hide Nginx and PHP versions from HTTP responses.

Traefik remains responsible for HTTP-to-HTTPS redirects, TLS, and certificate
management. FastCGI page caching is intentionally not enabled by the generic
template because authenticated sessions and plugin behavior need site-specific
cache rules and testing.

Traefik reads Docker metadata through a restricted socket proxy. The proxy is
available only on an internal Docker network and does not publish a host port.
Nginx mounts WordPress content read-only. WordPress disables PHP file editing
through the administration dashboard.

---

## Git safety

`.env` and `acme.json` runtime files are gitignored. Commit only example files
with placeholder values. Never store secret-manager credentials in the
repository.
