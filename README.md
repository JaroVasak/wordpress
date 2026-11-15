# WordPress + Traefik Docker Setup

A multi-site WordPress stack on one Hetzner server, with Traefik for HTTPS,
Cloudflare DNS challenges for certificates, and a shared MariaDB database.

## Architecture

```text
Browser -> Traefik (HTTPS) -> site Nginx -> WordPress PHP-FPM -> shared MariaDB
```

Traefik listens on ports 80 and 443. Each site has its own Nginx/PHP-FPM
containers, internal network, database, and database user. Shared Docker
networks connect site Nginx services to Traefik and PHP-FPM services to MariaDB.
Traefik discovers site services through a restricted Docker socket proxy.
The Hetzner firewall accepts web traffic only from Cloudflare's reviewed IP
ranges. Public website DNS records must be proxied through Cloudflare; see the
[firewall configuration](infra/README.md#cloudflare-only-web-access).

Persistent data lives in `shared/mariadb/data/`, `shared/traefik/acme.json`,
`sites/<site>/wp-content/`, and each site's `wordpress_files` Docker volume.

## Prerequisites

- A Hetzner Cloud project and an uploaded SSH public key for server provisioning.
- Terraform at the version pinned in [mise.toml](mise.toml).
- Docker Engine and Docker Compose on the host; cloud-init installs these on a new server.
- A secret manager that can inject environment variables; Bitwarden is supported.
- Cloudflare-managed DNS pointing to the server for public access and trusted HTTPS.

For an existing environment, start with adding a site; server provisioning and
shared-stack setup are performed once. An isolated development stack is available
under [local/](local/README.md).

## Setup sequence

Examples run from the repository root, `/opt/wordpress` on the server.

1. [Provision the server](infra/README.md), then connect with `ssh root@SERVER_IP`.
2. [Load secrets and start shared services](shared/README.md#base-stack-setup):
   `./scripts/bootstrap.sh`.
3. [Create a site](scripts/README.md#adding-a-new-site): create its database secret,
   load it into the environment, then run `./scripts/new-site.sh example.com`.
4. Complete the WordPress installer and [enable database backups](scripts/README.md#database-backups):
   `sudo ./scripts/install-backup-cron.sh example-com`.
5. [Test changes locally](local/README.md) and [enable repository automation](.github/README.md).

Database backups exclude `wp-content`; back up those files separately and copy
backups off the server.

## Detailed guides

| Directory | Guide |
|---|---|
| [infra/](infra/README.md) | Hetzner, Terraform, SSH/firewall setup, and infrastructure lifecycle |
| [shared/](shared/README.md) | Shared services, secrets, Cloudflare, certificates, and networks |
| [scripts/](scripts/README.md) | Site creation, Bitwarden shell, backups, updates, logs, and validation |
| [templates/site/](templates/site/README.md) | Generated configuration, persistent data, and PHP/Nginx settings |
| [local/](local/README.md) | Isolated local testing |
| [.github/](.github/README.md) | CI validation, security scans, automated update PRs, and repository settings |

The `sites/<site-name>/` directories are generated from the site template.
Files in `scripts/lib/` are internal helpers used by the operator commands.

## Git safety

`.env` and `acme.json` runtime files are gitignored. Commit only example files
with placeholder values. Keep secret-manager credentials outside the repository.
