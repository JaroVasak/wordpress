# Operator Commands

[Project overview](../README.md)

Executable files under `scripts/` are operator commands:

- `scripts/bws-shell.sh` starts an optional shell with Bitwarden secrets.
- `scripts/bootstrap.sh` initializes the shared infrastructure once per server.
- `scripts/new-site.sh` provisions one additional site and can be run repeatedly.
- `scripts/site-compose.sh` updates or recreates one existing site.
- `scripts/backup-site.sh` creates an on-demand database dump for one site.
- `scripts/install-backup-cron.sh` installs the daily database backup schedule.
- `scripts/validate.sh` checks scripts, Compose files, Nginx, and PHP-FPM configurations.

Files under `scripts/lib/` are sourced by the operator commands and are not run
directly.

The examples below run from the repository root. You can also change to the
`scripts/` directory and omit `scripts/` from each path. The scripts locate the
repository from their own file paths, so they work from any current directory.

## Load Bitwarden secrets

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

See the [secret inventory and Cloudflare token setup](../shared/README.md#secret-management)
for the environment variables consumed by each command. Use the Bitwarden
Secrets Manager machine access token, not a vault password or SSH passphrase.

## Adding a new site

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

Pass a domain or HTTP/HTTPS URL:

```bash
./scripts/new-site.sh example.com
```

`www.example.com`, `https://example.com`, and `https://www.example.com/`
all create the same site at `example.com`. Uppercase is converted to lowercase;
URL paths, queries, and fragments are ignored. Credentials and ports are not
accepted. The same normalization applies to the `DOMAIN` environment variable
and interactive input. This does not add routing or a redirect for `www`.

With no argument or `DOMAIN` environment variable, the script asks for the
hostname. It derives `SITE_NAME=example-com`, `DB_NAME=example_com`, and
`DB_USER=example_com_user`. The matching secret is `EXAMPLE_COM_DB_PASSWORD`.
Dots become hyphens in the slug, and repeated hyphens are
collapsed. For long names that exceed the input limits, supply shorter resource
names explicitly.

You can still override the generated names through the environment:

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

For generated `.env` fields and template behavior, see the
[site template guide](../templates/site/README.md#generated-configuration).
After provisioning, complete the WordPress installer in the browser or migrate
the existing site. The provisioning script does not create a WordPress admin.

## Automation input rules

The setup scripts reject values that could change paths, `.env` parsing, or SQL
statements:

- Site names use lowercase letters, digits, and single hyphens. Maximum: 63 characters.
- Domains must be lowercase, contain at least one dot, and use valid DNS labels.
- Database names use letters, digits, and underscores. Maximum: 64 characters.
- Database users use letters, digits, and underscores. Maximum: 32 characters.
- Database passwords contain 16–128 characters from `A-Z`, `a-z`, `0-9`, or `._~!@%^+=,:/-`.

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

The 03:00 schedule uses the server timezone. Retention is based on file age,
not a fixed number of copies: after a successful backup, matching files aged
14 days or older are deleted by default. Failed backups remove the partial file
and leave older backups intact. Installing a schedule does not run a first backup.

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

Existing sites keep their own copies of the template. Update their image tags
separately before recreating the containers. Existing WordPress core files are
persistent and must be updated through WordPress itself. MariaDB remains pinned
to `12.2.2-noble`; a database version upgrade is outside this update.

Version tags can still be changed in a container registry. Pin image digests as
well if deployments need immutable image content.

For shared-service maintenance, see [shared services](../shared/README.md#shared-service-updates).

## Repository validation

Run all application-stack checks before provisioning or committing changes:

```bash
./scripts/validate.sh
```

The command checks Bash syntax, runs ShellCheck, validates the cloud-init YAML,
renders every Compose file, tests both Nginx configurations in the pinned Nginx
image, and checks the Git diff for whitespace errors. It does not start the
WordPress stacks.


For CI workflows and their setup, see the [automation guide](../.github/README.md).

## Container logs

Every service uses Docker's `json-file` logging driver. Each container keeps up
to three 10 MB log files. This limits local disk use while preserving support
for `docker compose logs`.

For one site, with its database secret loaded:

```bash
./scripts/site-compose.sh example-com logs --tail=100
```
