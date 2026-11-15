# Shared Services

[Project overview](../README.md)

The shared stack runs one socket proxy, Traefik, and MariaDB for all sites.
Commands below run from the repository root on the server. Changes to these
services can affect every site.

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

For Bitwarden injection, use the [secrets shell](../scripts/README.md#load-bitwarden-secrets).

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

## Base stack setup

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

## Networks

| Network    | Purpose                                      |
|------------|----------------------------------------------|
| `proxy`    | Traefik ↔ nginx (public-facing)              |
| `db`       | MariaDB ↔ WordPress FPM (database access)    |
| `internal` | nginx ↔ WordPress FPM within a site (no external access) |

The `socket-proxy` network is internal and connects Traefik to the Docker socket
proxy. The proxy does not publish a host port.

## Shared-service updates

Review image changes in [docker-compose.yml](docker-compose.yml), back up data,
and test before recreating shared services. Load the existing Cloudflare and
MariaDB root secrets, then run `./scripts/bootstrap.sh` from the repository root.
MariaDB remains pinned to `12.2.2-noble`; database upgrades require a separate
migration plan. Never use `down --volumes` as an update step.

Changing the cloud-init template does not update the existing host; see the
[infrastructure lifecycle notes](../infra/README.md).

## Docker discovery

Traefik reads Docker metadata through the restricted socket proxy. Only site
Nginx services with `traefik.enable=true` are exposed.
