# Jellystat Module

Playback statistics and monitoring dashboard for Jellyfin (and Emby). Jellystat polls the media server for sessions, library contents and watch history, stores them in PostgreSQL, and serves a dashboard on top.

- **Image:** `cyfershepard/jellystat`
- **Version:** 1.1.11 (latest upstream release, 2026-06-23)
- **Port:** 3000
- **Upstream:** https://github.com/CyferShepard/Jellystat
- **Module path:** `opmodel.dev/modules/jellystat@v1`

> **Jellystat is not self-contained.** Unlike `jellyfin`, `seerr` and the `*arr`
> modules, it has no SQLite mode — PostgreSQL is mandatory. This module renders
> the database for you by default (`database.mode: "bundled"`), mirroring the
> upstream `docker-compose.yml`, or wires up an existing server with
> `database.mode: "external"`.

## Architecture

```text
opm-secrets (Secret)            — jwt-secret, postgres-password, optional GeoLite creds
jellystat (StatefulSet, replicas: 1)
  ├── initContainer wait-for-db — blocks until PostgreSQL accepts connections
  └── jellystat container (port 3000)
        └── /app/backend/backup-data (PVC) — Jellystat's own backup exports
postgres (StatefulSet, replicas: 1)   — only when database.mode == "bundled"
  └── postgres container (port 5432)
        └── /var/lib/postgresql (PVC)
```

Both workloads compose the catalog's `#StatefulWorkload` blueprint plus an `#Expose` trait; `jellystat` adds `#HttpRoute` when `httpRoute` is set, and `postgres` adds a `#SecurityContext` trait. All persistent application state lives in PostgreSQL — the app's own PVC only holds backup exports, so back up the **database**, not just the volume.

### Three details worth knowing

**The secrets component is named `opm-secrets` on purpose.** The catalog's secret transformer renders that component's secrets as `{instance}-{secretName}`, and that is the only shape a container's `env.from` secretKeyRef resolves to. Under any other component name the Secret would render as `{instance}-{component}-{secretName}` and every env reference would point at an object that does not exist.

**`POSTGRES_DB` is deliberately not set on the bundled database.** Jellystat's `create_database.js` connects with no database named, so node-pg falls back to a database matching the *role name*, and only then issues `CREATE DATABASE jfstat`. The official Postgres image creates a database named after `POSTGRES_USER` when `POSTGRES_DB` is unset — which is exactly the database that bootstrap needs. Setting it would break first start. Upstream's compose omits it for the same reason.

In **external** mode the same requirement applies: the server must already have a database named after `database.user`, and that role must be allowed to `CREATE DATABASE`.

**The bundled database Service name is pinned, not instance-prefixed.** A module cannot know its own instance name at build time, but the app needs a concrete `POSTGRES_IP`. `database.bundled.serviceName` (default `jellystat-db`) is therefore rendered verbatim and also becomes the StatefulSet's governing service name. Two instances of this module in one namespace must override it.

## Post-Deploy Setup

1. Open the Jellystat UI (port 3000, or via your HTTPRoute).
2. Create the admin account — the first account registered becomes the admin.
3. Under **Settings → Jellyfin**, enter the Jellyfin server URL and an API key
   (Jellyfin: *Dashboard → API Keys*).
4. Run the initial **sync** to backfill libraries and watch history.

## Quick Start (ModuleRelease)

Bundled database, which is the common case:

```yaml
apiVersion: releases.opmodel.dev/v1alpha1
kind: ModuleRelease
metadata:
  name: jellystat
  namespace: jellystat
spec:
  module:
    path: opmodel.dev/modules/jellystat@v1
    version: v0.1.0
  serviceAccountName: opm-applier
  prune: true
  values:
    timezone: Europe/Stockholm
    serviceType: ClusterIP
    jwtSecret:
      $secretName: jellystat
      $dataKey: jwt-secret
      secretName: jellystat-credentials   # pre-existing cluster Secret
      remoteKey: jwt-secret
    database:
      mode: bundled
      password:
        $secretName: jellystat
        $dataKey: postgres-password
        secretName: jellystat-credentials
        remoteKey: postgres-password
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

`jwtSecret` and `database.password` are required and accept either form of the catalog's `#Secret` contract:

- **`#SecretK8sRef`** (`secretName` + `remoteKey`, as above) — points at a Secret that already exists in the cluster. OPM emits no Secret of its own. Use this with SOPS/SealedSecrets.
- **`#SecretLiteral`** (`value`) — OPM creates the Secret as `{instance}-jellystat`. Convenient for testing; do not commit real values.

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
    password:
      $secretName: jellystat
      $dataKey: postgres-password
      secretName: jellystat-credentials
      remoteKey: postgres-password
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
| `jwtSecret` | `#Secret` | *(required)* | Key used to sign authentication JWTs |
| `database.mode` | `bundled`\|`external` | `bundled` | Whether this module renders PostgreSQL |
| `database.name` | string | `jfstat` | `POSTGRES_DB` — created by Jellystat on first start |
| `database.user` | string | `jellystat` | Role Jellystat authenticates as |
| `database.password` | `#Secret` | *(required)* | Password for that role |
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
| `geolite.accountId` / `geolite.licenseKey` | `#Secret` | *(unset)* | MaxMind GeoLite2 credentials for session geolocation |
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
