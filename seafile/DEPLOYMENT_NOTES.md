# Seafile deployment notes

Issues and operational details discovered while deploying this module. Update as
new ones surface.

## Behind a reverse proxy / TLS terminated upstream (gateway) — handled

TLS is terminated by an upstream gateway (Istio/Gateway API); the pod serves
plain HTTP on `:80`, so `SEAFILE_SERVER_LETSENCRYPT=false`. Two image behaviours
break Seafile in this setup, and the module fixes both automatically:

1. `bootstrap.py` derives `SERVICE_URL`/`FILE_SERVER_ROOT` from the scheme and
   only writes the config on **first boot**. Seahub runs **Django 4.2**, which
   rejects the `https://` login POST with **CSRF 403** unless the request scheme
   and `CSRF_TRUSTED_ORIGINS` agree.
2. The cache host is **hardcoded** to `memcached:11211`, which does not resolve —
   OPM emits the Service as `<release>-memcached`.

Fixes baked into the module:

- `FORCE_HTTPS_IN_CONF=true` (env, honoured by `bootstrap.py`) so first-boot URLs
  use `https`.
- A **`seahub-config` init container** idempotently appends an
  `# OPM-MANAGED-OVERRIDES` block to `conf/seahub_settings.py` (Python
  last-assignment-wins), setting:
  - `SERVICE_URL` / `FILE_SERVER_ROOT` → `https://<hostname>`
  - `CSRF_TRUSTED_ORIGINS = ["https://<hostname>"]`
  - `SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")`
  - `CACHES` default `LOCATION` → `<release>-memcached:11211`

The init container only patches once the settings file exists. On a **brand-new
install**, the file is generated during first boot (after init containers run),
so the override lands on the **first pod restart** — `FORCE_HTTPS_IN_CONF` keeps
the URLs https in the meantime, but the CSRF/cache fix needs that one restart.
On any redeploy of an existing instance (config already on the Retain PVC) the
override applies immediately, before the server starts.

## First boot is slow

Seafile initialises three databases and runs Django migrations on first start.
The readiness probe allows ~10 minutes (`failureThreshold: 40 × 15s`) and the
liveness probe waits 5 minutes before its first check. Watch
`kubectl logs <seafile-pod>` for `This is your first time to run seafile server`.

## Startup ordering

A `wait-for-mariadb` init container blocks Seafile until MariaDB accepts TCP on
`<release>-mariadb:3306`. MariaDB itself still needs a few seconds to initialise
its own data dir on first boot; the init container's retry loop covers this.

## Secrets

`adminPassword` and `dbRootPassword` resolve into a single Kubernetes Secret
`seafile-secret` (keys `admin-password`, `db-root-password`). The DB root
password is consumed by MariaDB (`MARIADB_ROOT_PASSWORD`) and Seafile
(`DB_ROOT_PASSWD`) — keep them in sync by referencing the same `#config` field
(already wired). Changing `dbRootPassword` after first boot does **not**
re-key the existing MariaDB root account.
