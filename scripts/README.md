# Operator Commands

[Project overview](../README.md)

Executable files under `scripts/` are operator commands:

- `scripts/bws-shell.sh` starts an optional shell with Bitwarden secrets.
- `scripts/bootstrap.sh` initializes the shared infrastructure once per server.
- `scripts/new-site.sh` provisions one additional site and can be run repeatedly.
- `scripts/site-compose.sh` updates or recreates one existing site.
- `scripts/deploy.sh` applies repository changes to sites: a canary site first, the rest a day later.
- `scripts/install-deploy-timer.sh` installs the daily automatic update timer.
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

On an Ubuntu server, install the daily backup schedule after the site is
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

Without an explicit time, the installer preserves the site's existing schedule
or assigns the first free daily slot, starting at 03:00 with 15-minute spacing
in server time. It reads `/etc/cron.d/wordpress-db-backup-*` to find occupied
times; no site-count variable or manual schedule calculation is needed. Removed
schedules free their slots. Concurrent installers lock slot selection so they
cannot claim the same time. If the day has no available slot, installation fails.

The optional fourth argument overrides automatic selection when a specific
time is needed:

```bash
sudo ./scripts/install-backup-cron.sh example-com /var/backups/wordpress 14 03:15
```

Spacing the start times reduces overlap; it does not prevent overlap if a dump
runs longer than the interval.

The script backs up only the database. Back up each site's `wp-content`
separately and copy backups off the Docker host. Site `.env` files now contain
only non-secret configuration. WordPress generates authentication keys in its
persistent configuration when the container is initialized. Test a restore
before relying on the backups for recovery.

Backup times use the server timezone. Retention is based on file age,
not a fixed number of copies: after a successful backup, matching files aged
14 days or older are deleted by default. Failed backups remove the partial file
and leave older backups intact. Installing a schedule does not run a first backup.

## Container image updates

Compose files use exact application version tags. This prevents an ordinary
restart from silently moving to a newer application release. Review release
notes, update the tag in every production and local Compose file that uses the
image, and test the local stack before a production update.

Sites listed for [automatic updates](#automatic-site-updates) receive image and
configuration changes from the template, the canary site first and the others
a day later. To apply a change to
one site now, run `./scripts/deploy.sh site example-com`. Existing WordPress
core files are persistent and must be updated through WordPress itself.
MariaDB is pinned to
`12.3.3-noble` LTS; version changes require a separate database upgrade plan.

Version tags can still be changed in a container registry. Pin image digests as
well if deployments need immutable image content.

For shared-service maintenance, see [shared services](../shared/README.md#shared-service-updates).

## Automatic site updates

The server applies merged changes to sites by itself: first to one canary site,
then a day later to all other sites, with automatic rollback. The repository template is the source of truth for each
site's configuration; per-site differences live in
[override files](../templates/site/README.md#per-site-overrides) that the
update never touches.

### What runs

A systemd timer runs `deploy.sh fetch` and then `deploy.sh rollout` daily at
06:00 Europe/Prague. Install or change the schedule as root:

```bash
sudo ./scripts/install-deploy-timer.sh            # daily at 06:00 Europe/Prague
sudo ./scripts/install-deploy-timer.sh 05:30 UTC  # another time or timezone
```

`fetch` fast-forwards the server checkout to `origin/main`. It refuses to run
when the checkout is on another branch, has diverged, or has local changes to
tracked files. It needs no credentials: the repository is public.

`rollout` compares each site's managed files (`docker-compose.yml`,
`nginx.conf`, `php-fpm.conf`, `uploads.ini`) with the template:

- Sites whose files already match are recorded as up to date without a restart.
- Before changing anything, every listed site must answer over HTTPS with a
  status below 500. One unhealthy site stops the rollout.
- The first site in `sites/rollout.list` is the **canary**; the others are
  **followers**. Each run first moves the followers to the version the canary
  runs, then moves the canary to the current template.
- Followers take the canary's version only after it has run there healthy for
  at least 20 hours (`DEPLOY_SOAK_HOURS`), so with a daily timer every change
  reaches the followers the day after the canary. They never get a version the
  canary has not run, and never one the canary only has because of hand edits.

With a template change merged every day:

| Run | Canary | Followers |
|---|---|---|
| Day 1 | A | previous version |
| Day 2 | B | A |
| Day 3 | C | B |

At most two versions run at the same time: the canary's and the followers'.
A follower that fails stops the followers listed after it, so they can stay on
an older version until the failure is fixed.

Only changes to the managed files start an update. Merges that change docs,
scripts, CI, or `infra/` are fetched but restart no site.

Updating one site:

1. Validate the new Compose file, then test the new Nginx and PHP-FPM files,
   with the site's overrides, in the pinned images. Pull the images.
2. Dump the site database with `backup-site.sh` to `/var/backups/wordpress`.
3. Keep the current files in `/var/lib/wordpress-deploy/previous/<site>/`,
   copy the new files (from the template for the canary, from the canary for
   followers) into the site, and recreate both containers.
   The site is unavailable for about 15–30 seconds.
4. Request `https://<domain>/` through Traefik on the server, bypassing
   Cloudflare. Any HTTP status below 500 within one minute counts as healthy.
5. On failure, restore the previous files, recreate the containers, and block
   that version. A failed step 1 changes nothing and needs no rollback. The
   rollout stops; a blocked version is not tried again on any site. A version
   that fails on the canary therefore never reaches the followers; the next
   merged template change starts a new version. If the rollback also fails, the
   status is `rollback-failed` and the site needs manual repair.

When a follower rejects a version that works on the canary, it is usually that
site's overrides, for example an `nginx.d/` file repeating a directive the new
template adds. Fix the override, then run `deploy.sh unblock`; the next run
retries the follower.

### Database password

Recreating the PHP-FPM container needs the site database password. The update
reads it from the site's own running PHP-FPM container
(`/run/secrets/wordpress_db_password`), where Compose placed it when the
container was created. If the per-site variable, such as
`EXAMPLE_COM_DB_PASSWORD`, is already in the environment, that value is used
instead. The password stays in memory: it is not printed, logged, written to a
file, or passed as a command-line argument. No credential that can fetch
secrets is stored on the server.

If the container is not running, the password cannot be read and the site is
marked `manual`. Run `./scripts/deploy.sh site <site>` in
`scripts/bws-shell.sh`.

Shared services, new sites, and password rotation stay manual. When `shared/`
changes, `fetch` prints a notice; apply it with `scripts/bootstrap.sh`.

### Selecting sites

Only sites listed in `sites/rollout.list` are updated automatically. The file is
on the server only, like the rest of `sites/`. List one site per line. Lines
starting with `#` are ignored. The first site is the canary: choose the one you
watch most closely. The order of the other sites only matters after a failure.

```text
# First line is the canary.
jvasak-com
example-com
```

Before you list an existing site, compare it with the template:

```bash
./scripts/deploy.sh diff example-com
```

Lines marked `-` are in the site but not in the template: older template
lines or hand edits. The first update removes them. Move each hand edit into the
site's
[override files](../templates/site/README.md#per-site-overrides), then run
`diff` again. The site is ready when only template lines (`+`) remain.

### Operator commands

```bash
./scripts/deploy.sh status                # versions, schedule, and each site's result
./scripts/deploy.sh diff [site]           # dry run: differences from the template
./scripts/deploy.sh site <site> [--force] # update one site to the template now
./scripts/deploy.sh pause                 # stop automatic fetch and rollout
./scripts/deploy.sh resume
./scripts/deploy.sh unblock               # retry versions that failed
journalctl -u wordpress-deploy            # output of the automatic runs
```

`site` ignores pause, blocks, and the canary order; it can therefore add a
third running version. It recreates the site only when its files differ from
the template, unless `--force` is given. Rollout state is kept in
`/var/lib/wordpress-deploy/`.

A failed update exits with an error, so `systemctl --failed` lists the unit.
A rollback leaves the site running, so an uptime monitor does not report it;
check `deploy.sh status` after merging changes.

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
