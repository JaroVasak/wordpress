# WordPress + Traefik Docker Setup — Interview Summary

## What This Project Demonstrates

A proof-of-concept multi-site WordPress infrastructure using Docker Compose, showing:
- **Container orchestration** (Docker Compose with multiple services)
- **Reverse proxy routing** (Traefik for domain-based routing)
- **Environment management** (.env files, secrets handling)
- **Networking** (multiple networks: proxy, db, internal)
- **Health checks** (service dependencies, graceful startup)
- **Environment separation** (an isolated local stack)
- **Infrastructure as code** (reproducible automation)

---

## Architecture

```
┌─────────────────────────────────────────────────┐
│           Shared Infrastructure (shared/)       │
├─────────────────────────────────────────────────┤
│  ├─ Traefik (reverse proxy)                     │
│  │  ├─ Listens on 80/443                        │
│  │  ├─ Routes by domain (Host rule)             │
│  │  └─ Handles TLS (Let's Encrypt via CF)       │
│  │                                              │
│  └─ MariaDB (database)                          │
│     └─ Shared across all sites                  │
└─────────────────────────────────────────────────┘
           ↓ (through networks: proxy, db)
┌─────────────────────────────────────────────────┐
│        Per-Site Stack (sites/example-com/)      │
├─────────────────────────────────────────────────┤
│  ├─ nginx (web server)                          │
│  │  ├─ Reverse proxies to WordPress FPM         │
│  │  ├─ Serves static files                      │
│  │  └─ Registered with Traefik (via labels)    │
│  │                                              │
│  └─ WordPress (PHP-FPM)                         │
│     ├─ Connects to MariaDB                      │
│     ├─ Mounts wp-content (persistent)           │
│     └─ Health check via php-fpm -t              │
└─────────────────────────────────────────────────┘
```

**Key networking insight:** Services use Docker networks for isolation:
- `proxy` — Traefik ↔ nginx (public-facing)
- `db` — MariaDB ↔ WordPress (database access only)
- `internal` — nginx ↔ WordPress (no external access)

---

## Technical Highlights

### 1. Service Discovery & Routing (Traefik)

Traefik uses **Docker labels** to discover services dynamically:

```yaml
labels:
  - "traefik.enable=true"                                    # register with Traefik
  - "traefik.http.routers.example-com.rule=Host(`example.com`)"  # domain routing
  - "traefik.http.routers.example-com.entrypoints=websecure"     # use HTTPS
  - "traefik.http.routers.example-com.tls.certresolver=cloudflare"  # auto-renew certs
  - "traefik.docker.network=proxy"                           # network to use
```

**Why this matters:** Zero configuration needed in Traefik when adding a new site — just start the container and it's automatically wired up.

### 2. Health Checks & Service Dependencies

```yaml
depends_on:
  wordpress:
    condition: service_healthy  # nginx waits for WordPress to be ready

healthcheck:
  test: ["CMD", "php-fpm", "-t"]  # verify PHP-FPM config is valid
  start_period: 20s               # give time for startup
```

**Why this matters:** Prevents nginx from trying to connect to an unavailable backend.

### 3. Environment Management

- **`.env` files are gitignored** — secrets never committed
- **`.env.example` files are committed** — documents what variables are needed
- **Per-site secrets** — each site has unique DB password, WordPress keys

```bash
# .env example for new site
WORDPRESS_TABLE_PREFIX=wp_3f9a2c_    # random prefix per site
WORDPRESS_AUTH_KEY=<64-char random>  # generated per site (no leaks across sites)
```

**Why this matters:** Developers can clone the repo, copy `.env.example` to `.env`, and run it without worrying about hardcoded credentials.

### 4. Persistent Data & Volumes

```yaml
volumes:
  wordpress_files:              # WordPress core (recreated each container restart)
  - ./wp-content:/var/www/html/wp-content  # uploads, plugins, themes (persistent)
  - ./mariadb/data:/var/lib/mysql          # database (persistent)
```

**Why this matters:** Separates ephemeral container files from data that must survive restarts.

### 5. Local and Production Separation

**Production (shared/):**
```bash
docker compose -f docker-compose.yml up -d
# Uses: traefik.yml (Cloudflare ACME), acme.json (cert storage)
```

**Local testing (`local/`):**
```bash
cd local
docker compose up -d
# Uses a local Nginx, WordPress, and MariaDB stack without Traefik or Cloudflare
```

**Why this matters:** Local testing cannot change or obscure the production configuration.

### 6. Automation Scripts

- **`bootstrap.sh`** — one-command base stack setup with credential validation
- **`new-site.sh`** — provisions a new site: copies template → generates secrets → creates DB user → starts containers

**Why this matters:** Reduces manual steps, prevents configuration errors.

---

## Docker Concepts Demonstrated

| Concept | Example in This Project |
|---------|------------------------|
| **Multi-container orchestration** | Traefik + MariaDB + WordPress managed by Compose |
| **Networks** | 3 networks (proxy, db, internal) for security isolation |
| **Volumes** | Persistent storage for uploads, database, configs |
| **Health checks** | Services wait for dependencies to be healthy |
| **Labels** | Traefik auto-discovers services via Docker labels |
| **Environment variables** | .env files for secrets management |
| **Environment separation** | Local services are contained under `local/` |
| **Container dependencies** | `depends_on: condition: service_healthy` |
| **Image pinning** | Specific version tags (e.g., `wordpress:php8.5-fpm`, `mariadb:12.2.2-noble`) |

---

## Production-Readiness Features

✅ **Secrets management** — `.env` files gitignored, credentials never in code  
✅ **Health checks** — Services verify readiness before accepting traffic  
✅ **Network isolation** — Database only accessible from WordPress, not from internet  
✅ **Persistent data** — Uploads, plugins, database survive container restarts  
✅ **TLS/HTTPS** — Auto-provisioned via Cloudflare ACME (Let's Encrypt)  
✅ **Scalability** — New sites spun up with `new-site.sh` (same template, different config)  
✅ **Reproducibility** — Exact image versions pinned, compose files define everything  

---

## If Asked "What Would You Improve?"

1. **Logging** — Add ELK stack or centralized logging (Loki)
2. **Monitoring** — Prometheus + Grafana for metrics
3. **Backups** — Automated backup script for uploads + database
4. **CI/CD** — GitHub Actions to auto-deploy when code changes
5. **Secrets management** — Use Docker Secrets or HashiCorp Vault instead of .env
6. **Load balancing** — Multiple WordPress instances behind a load balancer
7. **HTTPS locally** — Proper self-signed cert generation (mkcert)

---

## Interview Talking Points

**"This project shows I understand..."**

1. **Docker fundamentals** — images, containers, networks, volumes
2. **Compose best practices** — multi-container apps, overrides for environments, health checks
3. **Infrastructure patterns** — reverse proxy routing, service isolation, persistent data
4. **DevOps mindset** — automation (scripts), reproducibility (IaC), secrets management
5. **Real-world complexity** — multi-site support, local vs production, security concerns
6. **Problem-solving** — when something breaks, I diagnose (logs, networking, health checks)

**Strong closing:** "I built this to understand how production stacks work. I could explain any part — why certain networks exist, how Traefik discovers services, why health checks matter, how to add a new site."
