# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Infrastructure-as-code for a multi-site WordPress host on one Hetzner server. There is no application code: it is Bash operator scripts, Docker Compose stacks, Nginx/PHP-FPM config, Terraform, and GitHub Actions. On the server the repo is checked out at `/opt/wordpress` and scripts run from there. Each directory has a README with operator detail; [README.md](README.md) is the index.

Request path: `Browser -> Cloudflare (proxied) -> Traefik (HTTPS) -> site Nginx -> site WordPress PHP-FPM -> shared MariaDB`.

## Commands

```bash
./scripts/validate.sh                      # main check: bash -n, ShellCheck, cloud-init schema, compose config, nginx -t, php-fpm -t, git diff --check
terraform -chdir=infra fmt -check -recursive
terraform -chdir=infra init -backend=false -input=false -lockfile=readonly
terraform -chdir=infra validate
terraform -chdir=infra test                 # firewall policy tests, mocked provider, no credentials needed

cd local && cp .env.example .env && docker compose up -d   # isolated dev stack on http://localhost:8080
```

`validate.sh` needs `docker`, `shellcheck`, `yamllint`, and `cloud-init` installed, and pulls the pinned nginx/wordpress images to test their configs. CI ([.github/workflows/validate.yml](.github/workflows/validate.yml)) runs exactly these plus actionlint and `renovate-config-validator --strict`. Terraform version is pinned in [mise.toml](mise.toml) and must match the CI pin and `infra/versions.tf` (Renovate groups them).

## Architecture

Three layers, each a separate Compose project:

- **`shared/`**: one per server. `socket-proxy` (read-only Docker API) → `traefik` (ACME via Cloudflare DNS-01, `exposedbydefault=false`) and `mariadb`. Creates the external networks `proxy` (Traefik ↔ site Nginx) and `db` (MariaDB ↔ site PHP-FPM). Started by `scripts/bootstrap.sh`.
- **`templates/site/`**: copied verbatim to `sites/<site-name>/` by `scripts/new-site.sh`. Each site gets its own `nginx` + `wordpress` (FPM) containers, an `internal` network, a `wordpress_files` volume, and a host-mounted `wp-content/`. Traefik routing comes from labels on the site's nginx service. **Editing the template affects only future sites**; existing `sites/*` keep their own copies and must be updated by hand, then recreated with `scripts/site-compose.sh <site> up -d --wait`.
- **`local/`**: standalone stack (own MariaDB, no Traefik) for testing. Its `php-fpm.conf` and `uploads.ini` are identical to the template's, and its `nginx.conf` differs only by omitting the Cloudflare real-IP block (no Cloudflare locally). It uses the same image tags and resource limits. **Keep `local/` and `templates/site/` in sync** when changing Nginx/PHP config or images (see commit `14b9bab` for the pattern: both configs plus the template README).

`infra/` (Terraform, HCP remote state in `jarovasak/wordpress-hetzner`, local execution) provisions the server, a web firewall limited to Cloudflare IPs from [infra/cloudflare-ips.json](infra/cloudflare-ips.json), and a separate SSH firewall whose rules are managed in the Hetzner GUI (Terraform ignores rule changes). `cloud-init.yaml.tftpl` runs only on first boot, so changes there do not affect the existing host.

### Secrets and naming conventions

- Secrets are never in files. They come from environment variables (optionally via `scripts/bws-shell.sh` for Bitwarden) and are passed to containers as Compose `secrets:` with `environment:` sources, read via `*_FILE` env vars. `.env` files hold only non-secret config.
- Shared: `CF_DNS_API_TOKEN`, `MYSQL_ROOT_PASSWORD`. Terraform: `HCLOUD_TOKEN`.
- Per site, names derive from the domain: `example.com` → `SITE_NAME=example-com`, `DB_NAME=example_com`, `DB_USER=example_com_user`, secret `EXAMPLE_COM_DB_PASSWORD`. Containers are `<site>-nginx` / `<site>-fpm`; the Compose project name is the site name. `site-compose.sh` maps the per-site secret to `DB_PASSWORD` before calling `docker compose`, so always use it rather than raw `docker compose` for sites.
- All user input goes through the allowlist validators in [scripts/lib/validation.sh](scripts/lib/validation.sh) before being used in paths, `.env`, or SQL. `new-site.sh` builds SQL by interpolation and relies on those validators; keep that invariant if you touch it. It also has a rollback trap that removes only resources it created in that run.

## Conventions

- **New shell scripts must be added to the `SHELL_SCRIPTS` array in [scripts/validate.sh](scripts/validate.sh)**, or they won't be linted. Scripts locate the repo via `BASH_SOURCE`, use `set -euo pipefail`, and source `scripts/lib/validation.sh` for `die`/`require_command`.
- Image tags are exact versions (no `latest`); Renovate updates every copy of an image in one PR, so when bumping by hand change all Compose files that use it. MariaDB updates are disabled in Renovate and pinned to `12.3.3-noble` (upgrades need a separate plan). Nginx stays on stable even-minor `alpine-slim`; WordPress keeps the `-php8.5-fpm-alpine` suffix.
- GitHub Actions are pinned to commit SHAs with a version comment. CI helper images in workflows use `# renovate: datasource=... depName=...` comments above an `ENV_VAR: image:x.y.z` line so the regex manager can update them.
- Containers all set `mem_limit`, `cpus`, `pids_limit`, `no-new-privileges`, and the shared `x-logging` anchor. Resource caps are documented in the shared and template READMEs; update those tables when changing limits.
- Commits use Conventional Commits with a scope, e.g. `perf(nginx): ...`, `fix(infra): ...`, `chore(deps): ...`. `main` is protected; work on branches and open PRs.
- Branch names use the same Conventional Commits type as a prefix: `<type>/<short-kebab-description>`, e.g. `perf/static-cache-1y`, `ci/advisory-container-scan`, `docs/wordpress-7.1.5`. Branch from `main`.
- Docs changes accompany behavior changes: the per-directory READMEs describe exact behavior (cache headers, PHP worker counts, image tags), so keep them accurate.
- Security scanning ([.github/workflows/security.yml](.github/workflows/security.yml)) uses Trivy. Container findings are advisory; repo findings fail. The only exclusion is the reviewed MariaDB `gosu` helper, pinned by SHA-256 with an expiry ([.github/security/README.md](.github/security/README.md)); don't widen it to silence new findings.
- Gitignored runtime data: `.env`, `shared/traefik/acme.json`, `shared/mariadb/`, `sites/*/wp-content/`, Terraform state/tfvars. `sites/` and `backups/` are excluded from Renovate.
