# WordPress + Traefik Docker Setup

Multi-site WordPress stack with Traefik v3 as reverse proxy, Cloudflare DNS challenge for SSL, and MariaDB as a shared database.

**For isolated local testing**, see [local/README.md](local/README.md). The local stack does not use the production Traefik or Cloudflare configuration.

## Structure

```
wordpress/
  local/                      # Isolated local-only stack
  shared/                     # Traefik + MariaDB (shared infrastructure)
  sites/
    example-com/              # Template — copy this for each new site
```

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
6. Under **Zone Resources**, set to `Include` → `All zones`
   - This lets one token cover every domain you add in future
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
and then starts Traefik and MariaDB.

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

The script will prompt for the site slug, domain, and database credentials, copy the `sites/example-com` template, create the database and user in MariaDB, then start the site stack.

---

## Networks

| Network    | Purpose                                      |
|------------|----------------------------------------------|
| `proxy`    | Traefik ↔ nginx (public-facing)              |
| `db`       | MariaDB ↔ WordPress FPM (database access)    |
| `internal` | nginx ↔ WordPress FPM within a site (no external access) |

---

## Git safety

`.env` files and `acme.json` are gitignored. Commit only `.env.example` files with placeholder values.
