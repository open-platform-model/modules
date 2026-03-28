# Seerr Module

Media request management for Jellyfin, Plex, and Emby. Allows users to request movies and TV shows which are automatically sent to Radarr/Sonarr for download.

- **Image:** `ghcr.io/seerr-team/seerr`
- **Port:** 5055
- **Upstream:** https://github.com/seerr-team/seerr

## Architecture

Single stateful container with a persistent volume for the SQLite database and application settings. Seerr stores all configuration (media server connections, Radarr/Sonarr integrations, user permissions, notifications) in its database.

```text
seerr (Deployment, replicas: 1)
  └── seerr container (port 5055)
        └── /app/config (PVC) — SQLite DB, settings.json, logs
```

## Post-Deploy Setup

Seerr requires a **mandatory setup wizard** on first access via the web UI. This cannot be bypassed or pre-configured via files or environment variables.

1. Open the Seerr web UI (port 5055 or via your HTTPRoute)
2. Create the admin account
3. Connect your media server (Jellyfin, Plex, or Emby)
4. Configure Radarr and/or Sonarr integrations
5. Set up user permissions and notification agents as needed

All subsequent configuration changes can be made through the web UI or the REST API at `/api/v1/`.

## Quick Start

```cue
import "opmodel.dev/modules/seerr@v0"

config: seerr.#config & {
    timezone: "Europe/Stockholm"
    storage: config: {
        type:         "pvc"
        size:         "5Gi"
        storageClass: "local-path"
    }
}

components: (seerr.#components & {"#config": config})
```

## Configuration Reference

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `image` | `#Image` | `ghcr.io/seerr-team/seerr:v3.1.0` | Container image (digest-pinned) |
| `port` | `int` | `5055` | Web UI and API port |
| `timezone` | `string` | `Europe/Stockholm` | Container timezone (TZ format) |
| `logLevel` | `string?` | — | Log level: `debug`, `info`, `warn`, `error` |
| `apiKey` | `#Secret?` | — | Pre-set API key via Kubernetes secret |
| `postgres` | `struct?` | — | PostgreSQL connection (default: SQLite) |
| `postgres.host` | `string` | — | PostgreSQL hostname |
| `postgres.port` | `int` | `5432` | PostgreSQL port |
| `postgres.user` | `string` | — | PostgreSQL username |
| `postgres.password` | `#Secret` | — | PostgreSQL password secret |
| `postgres.name` | `string` | `seerr` | PostgreSQL database name |
| `postgres.useSSL` | `bool` | `false` | Enable SSL for PostgreSQL |
| `storage.config` | `#storageVolume` | PVC 5Gi at `/app/config` | Application data volume |
| `serviceType` | `string` | `ClusterIP` | Kubernetes Service type |
| `httpRoute` | `struct?` | — | Gateway API HTTPRoute config |
| `resources` | `#Resources?` | — | CPU/memory requests and limits |

## PostgreSQL Example

```cue
config: seerr.#config & {
    postgres: {
        host: "postgres.db.svc.cluster.local"
        user: "seerr"
        password: {
            $secretName: "seerr-db"
            $dataKey:    "password"
        }
    }
}
```
