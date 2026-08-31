# Isolated Local Test Stack

This directory contains a local-only WordPress stack. It does not read or modify files under `shared/` or `sites/`.

The stack includes:

- Nginx on `http://localhost:8080`
- WordPress PHP-FPM
- MariaDB
- Local Docker networks and named volumes

It does not test Traefik, Cloudflare, public DNS, or ACME certificates. Test those parts later in a production-like staging environment.

## Start

From the repository root:

```bash
cd local
cp .env.example .env
docker compose config --quiet
docker compose up -d
docker compose ps
```

Open `http://localhost:8080` and complete the WordPress installer.

Change `LOCAL_PORT` in `local/.env` if port 8080 is already in use.

## Logs

```bash
cd local
docker compose logs --follow
```

## Stop

```bash
cd local
docker compose down
```

The named volumes keep the database and WordPress files.

To delete all local data, run `docker compose down --volumes`. This action cannot be undone.

## Local-only credentials

The values in `.env.example` are public development defaults. Do not reuse them in production. The real `local/.env` file is ignored by Git.
