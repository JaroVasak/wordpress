# Site Template

[Project overview](../../README.md) · [Site operator commands](../../scripts/README.md#adding-a-new-site)

This directory is copied to `sites/<site-name>/` when a site is provisioned.
Editing the template affects future sites; existing sites keep their own copies.

## Generated configuration

[.env.example](.env.example) documents the site's configuration fields; do not
edit or copy it to provision a site. `new-site.sh` reads its inputs from the
command line or exported environment variables, then generates
`sites/<site-name>/.env`, including a random WordPress table prefix. It does not
load a `.env` file as provisioning input. Keep database passwords in your secret
manager, not in these files.

| Field | Purpose |
|---|---|
| `SITE_NAME` | Compose project, container, and router names |
| `DOMAIN` | Normalized hostname used by Traefik |
| `DB_NAME` | Site database in the shared MariaDB service |
| `DB_USER` | Database user restricted to that site |
| `WORDPRESS_TABLE_PREFIX` | Random table prefix generated during provisioning |

## Persistent data

Each site has a `wordpress_files` Docker volume for WordPress core and its
generated configuration. Nginx and PHP-FPM share this volume. The host directory
`sites/<site-name>/wp-content/` stores uploads, plugins, and themes. Nginx mounts
WordPress content read-only. WordPress disables PHP file editing in the dashboard.

WordPress generates authentication keys in its persistent configuration during
initialization. Update existing WordPress core through WordPress itself; changing
the container image does not replace existing core files in the volume.

## WordPress runtime

The template and local stack use the official
`wordpress:7.1.4-php8.5-fpm-alpine` image. It keeps the WordPress and PHP release
lines while using Alpine instead of Debian. Renovate's Docker versioning keeps
the `php8.5-fpm-alpine` compatibility suffix when proposing WordPress updates.

Alpine uses musl instead of glibc. WordPress runs as `www-data` with UID/GID 82,
which owns its writable core files and `wp-content` data. Bundled native
binaries and custom PHP extensions must be compatible with Alpine.

## PHP settings

[uploads.ini](uploads.ini) sets both `upload_max_filesize` and `post_max_size` to
64 MB. [php-fpm.conf](php-fpm.conf) starts PHP workers on demand, allows two
concurrent PHP requests, stops idle workers after 20 seconds, and recycles each
worker after 500 requests. Additional requests queue until a worker is free.

## Resource limits

| Container | Memory cap | CPU cap | Process/thread cap |
|---|---:|---:|---:|
| WordPress PHP-FPM | 768 MiB | 0.75 CPU | 128 |
| Nginx | 32 MiB | 0.25 CPU | 64 |

These are ceilings, not reserved resources. The 768 MiB cap covers the entire
PHP container, including workers, OPcache, and native allocations. PHP's own
memory limit applies separately to each request. A container can have processes
killed when it exceeds its memory cap; validate backups, updates, and image
processing as well as normal page requests.

Each site adds 800 MiB to the combined memory ceilings, in addition to the
[shared-service caps](../../shared/README.md#resource-limits). These ceilings may
overcommit the host: simultaneous peaks can exhaust physical RAM before
individual caps are reached. Monitor usage and revisit capacity when adding sites.

## Nginx request safeguards

The template and local stack use the official stable `nginx:1.30.7-alpine-slim`
image. It omits the optional XSLT/image-filter/GeoIP module bundle, which these
configurations do not use. The XSLT bundle in the larger Alpine variant brings
in `libxslt`, the source of the three findings identified in the initial scan.
Renovate preserves the stable Alpine slim variant when proposing updates.

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
