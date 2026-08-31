# Jellystat Module

Playback statistics and monitoring dashboard for Jellyfin (and Emby). Jellystat polls the media server for sessions, library contents and watch history, stores them in PostgreSQL, and serves a dashboard on top.

- **Image:** `cyfershepard/jellystat`
- **Version:** 1.1.11 (latest upstream release, 2026-06-23)
- **Port:** 3000
- **Upstream:** https://github.com/CyferShepard/Jellystat
- **Module path:** `opmodel.dev/modules/jellystat@v3`

> **Jellystat is not self-contained.** Unlike `jellyfin`, `seerr` and the `*arr`
> modules, it has no SQLite mode — PostgreSQL is mandatory. This module renders
> the database for you by default (`database.mode: "bundled"`), mirroring the
> upstream `docker-compose.yml`, or wires up an existing server with
> `database.mode: "external"`.

## Architecture

```text
jellystat (StatefulSet, replicas: 1)
  ├── initContainer wait-for-db — blocks until PostgreSQL accepts connections
  └── jellystat container (port 3000)
        └── /app/backend/backup-data (PVC) — Jellystat's own backup exports
postgres (StatefulSet, replicas: 1)   — only when database.mode == "bundled"
  └── postgres container (port 5432)
        └── /var/lib/postgresql (PVC)
```

Both workloads compose the catalog's `#StatefulWorkload` blueprint plus an `#Expose` trait; `jellystat` adds `#HttpRoute` when `httpRoute` is set, and `postgres` adds a `#SecurityContext` trait. All persistent application state lives in PostgreSQL — the app's own PVC only holds backup exports, so back up the **database**, not just the volume.

### Two details worth knowing

**`POSTGRES_DB` is deliberately not set on the bundled database.** Jellystat's `create_database.js` connects with no database named, so node-pg falls back to a database matching the *role name*, and only then issues `CREATE DATABASE jfstat`. The official Postgres image creates a database named after `POSTGRES_USER` when `POSTGRES_DB` is unset — which is exactly the database that bootstrap needs. Setting it would break first start. Upstream's compose omits it for the same reason.

In **external** mode the same requirement applies: the server must already have a database named after `database.user`, and that role must be allowed to `CREATE DATABASE`.

**The bundled database Service name is pinned, not instance-prefixed.** A module cannot know its own instance name at build time, but the app needs a concrete `POSTGRES_IP`. `database.bundled.serviceName` (default `jellystat-db`) is therefore rendered verbatim and also becomes the StatefulSet's governing service name. Two instances of this module in one namespace must override it.

> **Why that pin is safe here, given the `serviceName` + `httpRoute` bug on alpha.6.**
> On `catalogs/opm@v1.0.0-alpha.6` the four route transformers build their
> `backendRef` from a hardcoded `{instance}-{component}` and never consult
> `expose.name`, so a component that pins an exact Service name *and* carries a
> route emits a route pointing at a Service that does not exist — `cue vet`
> passes, the render succeeds, and it fails only at request time as a 503. (Same
> bug `sonarr`/`sabnzbd` work around with a separate alias Service.)
>
> This module is unaffected because the two concerns sit on different
> components: the **app** leaves `expose.name` unset, so its Service and its
> HTTPRoute backendRef both resolve to `{instance}-jellystat`; the pinned
> `jellystat-db` is on the **postgres** component, which has no route and is
> reached only by DNS from the app. Do not add a route to the database
> component, and do not pin the app's Service name.

## Post-Deploy Setup

1. Open the Jellystat UI (port 3000, or via your HTTPRoute).
2. Create the admin account — the first account registered becomes the admin.
3. Under **Settings → Jellyfin**, enter the Jellyfin server URL and an API key
   (Jellyfin: *Dashboard → API Keys*).
4. Run the initial **sync** to backfill libraries and watch history.

## Quick Start (ModuleInstance)

Bundled database, which is the common case:

```yaml
apiVersion: opmodel.dev/v1alpha1
kind: ModuleInstance
metadata:
  name: jellystat
  # The namespace must already exist — a ModuleInstance is itself namespaced,
  # so the operator cannot accept one into a namespace it would have created.
  namespace: jellystat
spec:
  module:
    path: opmodel.dev/modules/jellystat@v3
    version: v2.0.0
  # No serviceAccountName: the operator applies rendered resources as its own
  # identity. Set one only if that identity is deliberately scoped down.
  prune: true
  values:
    timezone: Europe/Stockholm
    serviceType: ClusterIP
    jwtSecret: "<generated jwt secret>"
    database:
      mode: bundled
      password: "<generated postgres password>"
      bundled:
        storage:
          type: pvc
          size: 10Gi
          storageClass: standard
    storage:
      backup:
        type: pvc
        size: 5Gi
        storageClass: standard
    httpRoute:
      hostnames:
        - jellystat.example.com
      gatewayRef:
        name: gateway-gateway
        namespace: istio-ingress
```

### Secrets

`jwtSecret` and `database.password` are required plain strings for the interim: the value
lands in the rendered manifest in clear (no pre-existing cluster Secret can be referenced
until `core` ships the new `#Secret`, enhancement 0013).

Generate a JWT key with `openssl rand -hex 32`.

### External database

```yaml
values:
  database:
    mode: external
    host: postgres.databases.svc.cluster.local
    port: 5432
    user: jellystat
    name: jfstat
    ssl:
      enabled: true
      rejectUnauthorized: true
    password: "<generated postgres password>"
```

No `postgres` component is rendered; the `wait-for-db` init container still runs and gates startup on the external server.

## Configuration Reference

| Field | Type | Default | Description |
| --- | --- | --- | --- |
| `image` | `#Image` | `cyfershepard/jellystat:1.1.11` (digest-pinned) | Container image |
| `servicePort` | int | `3000` | **Service** port. The container port is fixed — upstream hardcodes `const PORT = 3000` and exposes no override |
| `timezone` | string | `Europe/Stockholm` | `TZ` |
| `listenIp` | string | `0.0.0.0` | `JS_LISTEN_IP` |
| `baseUrl` | string | *(unset)* | `JS_BASE_URL`, e.g. `/jellystat`. Must start with `/` and not end with one. Probe paths and the HTTPRoute match are shifted under it automatically |
| `jwtSecret` | string | *(required)* | Key used to sign authentication JWTs |
| `database.mode` | `bundled`\|`external` | `bundled` | Whether this module renders PostgreSQL |
| `database.name` | string | `jfstat` | `POSTGRES_DB` — created by Jellystat on first start |
| `database.user` | string | `jellystat` | Role Jellystat authenticates as |
| `database.password` | string | *(required)* | Password for that role |
| `database.port` | int | `5432` | Port the app dials |
| `database.ssl.enabled` | bool | `false` | `POSTGRES_SSL_ENABLED` |
| `database.ssl.rejectUnauthorized` | bool | `true` | `POSTGRES_SSL_REJECT_UNAUTHORIZED` |
| `database.host` | string | *(unset)* | Required when `mode: external`; ignored when bundled |
| `database.bundled.serviceName` | string | `jellystat-db` | Pinned Service name / DB hostname |
| `database.bundled.image` | `#Image` | `postgres:18.1` (digest-pinned) | Bundled database image |
| `database.bundled.storage` | `#storageVolume` | pvc `10Gi` at `/var/lib/postgresql` | PG 18 keeps PGDATA in a `18/docker` subdirectory, so the PVC mounts at the parent |
| `database.bundled.resources` | `#ResourceRequirementsSchema` | *(unset)* | Database resource requests/limits |
| `server.isEmbyApi` | bool | `false` | `IS_EMBY_API` — target Emby instead of Jellyfin |
| `server.useWebsockets` | bool | `true` | `JF_USE_WEBSOCKETS` |
| `server.rejectSelfSignedCertificates` | bool | `true` | Set `false` for a media server behind an internal CA |
| `server.newWatchEventThresholdHours` | int | *(unset)* | `NEW_WATCH_EVENT_THRESHOLD_HOURS` |
| `geolite.accountId` / `geolite.licenseKey` | string | *(unset)* | MaxMind GeoLite2 credentials for session geolocation |
| `storage.backup` | `#storageVolume` | pvc `5Gi` at `/app/backend/backup-data` | Jellystat's backup exports |
| `serviceType` | enum | `ClusterIP` | Service type |
| `httpRoute` | struct | *(unset)* | Gateway API HTTPRoute (`hostnames`, optional `gatewayRef`) |
| `resources` | `#ResourceRequirementsSchema` | *(unset)* | App resource requests/limits |

## Health Checks

Both probes hit `/auth/isConfigured` — upstream's own compose healthcheck endpoint — shifted under `baseUrl` when set. First start runs `CREATE DATABASE` plus the full migration chain, so the liveness probe waits 90s before its first check and tolerates 5 failures.

## Build

```bash
cue fmt ./...
cue vet -c ./...
opm module build .        # render via a synthetic instance
```
