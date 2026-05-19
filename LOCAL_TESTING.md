# Local Testing Guide

Test the WordPress stack locally on Docker Desktop without needing a real server or domain.

## Prerequisites

- Docker Desktop (running)
- `openssl` (usually pre-installed on macOS/Linux; Windows users, use WSL)

## Quick Start

### 1. Generate self-signed certificate and add hosts entry

```bash
./scripts/generate-local-cert.sh
```

This:
- Generates a self-signed certificate valid for all `*.local` domains
- Adds `127.0.0.1 example.local` to your `/etc/hosts` (prompts for sudo password)

### 2. Start the base stack

```bash
cd shared

# Use both the base and local-override compose files
docker compose -f docker-compose.yml -f docker-compose.local.override.yml up -d
```

This starts:
- **Traefik** (reverse proxy) — listens on port 80/443 locally, uses self-signed cert
- **MariaDB** — database server
- Networks: `proxy` and `db`

Wait 10–15 seconds for both containers to be healthy.

### 3. Create your first local site

```bash
cd ../sites

# Run new-site.sh
./new-site.sh
```

When prompted:
- **Site name**: `example-com` (or any slug)
- **Domain**: `example.local` (or `mysite.local` — anything ending in `.local`)
- **DB name/user/password**: anything you want (only used locally)

This:
- Copies the template
- Generates WordPress secret keys and random table prefix
- Creates the database and user in MariaDB
- Starts the WordPress FPM + nginx stack with the local override (HTTP on port 80)
- Registers the site with Traefik

**Important:** Site containers are started with the local override by default. If you need to restart a site manually, always include both files:
```bash
cd sites/example-com
docker compose -f docker-compose.yml -f docker-compose.local.override.yml up -d
```

### 4. Access WordPress

Open your browser and go to:

```
http://example.local
```

(Use `http://`, not `https://` — local testing runs on plain HTTP via the override config)

WordPress installer should load. Follow the standard setup (site title, admin user, etc.).

---

## Troubleshooting

### "Connection refused" / Can't reach example.local

1. Check containers are running: `docker ps` (look for traefik, mariadb, wordpress)
2. Check `/etc/hosts` has the entry: `cat /etc/hosts | grep example.local`
3. Restart Docker Desktop if containers won't start
4. **For site containers:** Ensure you started them with the override file (see step 3)
   ```bash
   cd sites/your-site
   docker compose -f docker-compose.yml -f docker-compose.local.override.yml up -d
   ```
   Without the override, the nginx router looks for a `websecure` entrypoint that doesn't exist in local mode, causing 404s.

### WordPress shows "Error establishing database connection"

MariaDB takes ~10–15 seconds to start. Wait and refresh the browser. If it persists:

```bash
docker logs mariadb  # see if MariaDB is actually running
```

### Browser says "certificate not secure"

Local testing uses plain HTTP (no SSL). If you're trying to access `https://example.local`, it won't work. Use `http://example.local` instead.

### I want to access WordPress on a different domain (e.g., mysite.local)

1. Run `./scripts/generate-local-cert.sh mysite.local` to add it to /etc/hosts
2. When running `new-site.sh`, enter `mysite.local` as the domain
3. Visit `https://mysite.local`

---

## Switching Back to Production Config

When you're ready to deploy to your server:

1. Update `shared/.env` with your real Cloudflare token and email
2. Update `shared/docker-compose.yml` to use the production config (remove the local override)
3. Configure your domains' DNS to point to your server
4. Deploy using the normal `bootstrap.sh` and `new-site.sh` flow

The setup is identical — you're just swapping config files.

---

## Useful Commands

```bash
# Stop everything
docker compose down

# View logs
docker compose logs traefik
docker compose logs mariadb
docker compose logs -f wordpress  # follow logs in real-time

# Manage a specific site (always use the override file)
cd sites/example-com
docker compose -f docker-compose.yml -f docker-compose.local.override.yml up -d    # start
docker compose -f docker-compose.yml -f docker-compose.local.override.yml down -v   # stop + remove volumes
docker compose -f docker-compose.yml -f docker-compose.local.override.yml logs -f   # view logs

# Remove a local site completely
cd sites && rm -rf example-com

# List running containers
docker ps
```
