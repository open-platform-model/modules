# Seafile deployment notes

Issues and operational details discovered while deploying this module. Update as
new ones surface.

## Behind a reverse proxy / TLS terminated upstream (gateway)

This module sets `SEAFILE_SERVER_LETSENCRYPT=false` because TLS is expected to be
terminated by an upstream gateway (Istio/Gateway API) and the pod serves plain
HTTP on `:80`. With Let's Encrypt disabled, the `seafile-mc` entrypoint derives
`SERVICE_URL`/`FILE_SERVER_ROOT` using the **http** scheme.

When users reach Seafile over **https**, file up/download links and CSRF checks
break unless the external scheme is corrected. After the first boot, set the
external URL via **one** of:

- **Admin UI** (simplest, persists to DB): System Admin → Settings →
  `SERVICE_URL = https://<host>` and `FILE_SERVER_ROOT = https://<host>/seafhttp`.
- **Config files** on the `/shared` PVC:
  - `conf/seahub_settings.py`: `SERVICE_URL = 'https://<host>'`,
    `CSRF_TRUSTED_ORIGINS = ['https://<host>']`
  - `conf/seafile.conf` `[fileserver]`: derived from `SERVICE_URL`; set
    `FILE_SERVER_ROOT = https://<host>/seafhttp` if needed.
  Then restart the seafile pod.

## Memcached host

The official `seafile-mc` config points Seahub's cache at host `memcached:11211`.
OPM emits the cache Service as `<release>-memcached`, which does **not** match.
Options:

- Point Seahub at the real Service by editing `conf/seahub_settings.py` on the
  `/shared` PVC:

  ```python
  CACHES = {'default': {
      'BACKEND': 'django_pylibmc.memcached.PyLibMCCache',
      'LOCATION': '<release>-memcached:11211',
  }}
  ```

  then restart the seafile pod.
- Memcached is a performance optimisation; Seafile remains functional if the
  cache is unreachable (degraded session/metadata caching only).

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
