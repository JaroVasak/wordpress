# WordPress + Traefik Docker Setup

Multi-site WordPress stack with Traefik v3 as reverse proxy, Cloudflare DNS challenge for SSL, and MariaDB as a shared database.

**For isolated local testing**, see [local/README.md](local/README.md). The local stack does not use the production Traefik or Cloudflare configuration.

## Structure

```
wordpress/
  local/                      # Isolated local-only stack
  shared/                     # Socket proxy + Traefik + MariaDB
  scripts/lib/                # Internal shell libraries
  sites/
    example-com/              # Template — copy this for each new site
```

Root-level shell scripts are operator commands:

- `bootstrap.sh` initializes the shared infrastructure once per server.
- `new-site.sh` provisions one additional site and can be run repeatedly.
- `backup-site.sh` creates an on-demand database dump for one site.
- `install-backup-cron.sh` installs the daily database backup schedule.
- `validate.sh` checks scripts, Compose files, and Nginx configurations.

Files under `scripts/lib/` are sourced by the operator commands and are not run
directly.

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

## Prerequisites

- Docker + Docker Compose
- A Cloudflare account managing your domain(s)
- Domain(s) with DNS pointing to your server

---

## Credentials setup

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

**Verify the token works:**

```bash
curl "https://api.cloudflare.com/client/v4/user/tokens/verify" \
  -H "Authorization: Bearer YOUR_TOKEN_HERE"
# expected: "status":"active"
```

This request confirms that the token is active. It does not confirm that the
token has the required zone permissions.

**Token security notes:**

- Scope the token to zone read and DNS edit access only
- Store it in a password manager; update `shared/.env` and restart Traefik if you ever rotate it
- Keep `shared/.env` out of git (already covered by `.gitignore`)
- Set strict permissions on the server: `chmod 600 shared/.env`

---

## 1. Base stack setup

```bash
./bootstrap.sh
```

The script prompts for credentials, confirms that the Cloudflare token is
active, creates `shared/.env` and `traefik/acme.json` with correct permissions,
and then starts the socket proxy, Traefik, and MariaDB. It fails if the shared
services do not become ready within two minutes.

**shared/.env variables:**

| Variable               | Description                                      |
|------------------------|--------------------------------------------------|
| `CF_DNS_API_TOKEN`     | Cloudflare token with zone read and DNS edit     |
| `ACME_EMAIL`           | Email for Let's Encrypt notifications            |
| `MYSQL_ROOT_PASSWORD`  | MariaDB root password                            |

If `shared/.env` already uses `CF_API_TOKEN`, rename it to
`CF_DNS_API_TOKEN` before you restart Traefik.

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

```bash
./new-site.sh
```

The script prompts for the site slug, domain, and database credentials. It
checks for existing Docker and MariaDB resources before it copies the template,
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
./backup-site.sh example-com /var/backups/wordpress
```

The script reads only the database name from the site's `.env`, creates the
dump through the running MariaDB container, and keeps 14 days of matching dump
files by default. Set `BACKUP_RETENTION_DAYS` to a different positive number if
needed.

On an Ubuntu server, install the daily 03:00 backup schedule after the site is
provisioned:

```bash
sudo ./install-backup-cron.sh example-com
```

The installer writes `/etc/cron.d/wordpress-db-backup-example-com`, uses
`/var/backups/wordpress` by default, and creates the site backup directory with
owner-only permissions. Re-running it replaces only that site's schedule. Pass
a different absolute backup root and retention period when needed:

```bash
sudo ./install-backup-cron.sh example-com /mnt/backups/wordpress 30
```

The script backs up only the database. Back up each site's `wp-content` and
`.env` separately, encrypt sensitive backups, and copy them off the Docker host.
Test a restore before relying on the backups for recovery.

---

## Container image updates

Compose files use exact application version tags. This prevents an ordinary
restart from silently moving to a newer application release. Review release
notes, update the tag in every production and local Compose file that uses the
image, and test the local stack before a production update.

Version tags can still be changed in a container registry. Pin image digests as
well if deployments need immutable image content.

---

## Repository validation

Run all repository checks before provisioning or committing infrastructure
changes:

```bash
./validate.sh
```

The command checks Bash syntax, runs ShellCheck, renders every Compose file,
tests both Nginx configurations in the pinned Nginx image, and checks the Git
diff for whitespace errors. It does not start the WordPress stacks.

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

`.env` files and `acme.json` are gitignored. Commit only `.env.example` files with placeholder values.
