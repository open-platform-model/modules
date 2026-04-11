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

## K8up Backup

Optional K8up integration for backing up the config PVC (which holds the SQLite database and settings) to S3.

When `backup` is configured, the module creates:
- A **K8up Schedule** CR for recurring backup, check, and prune jobs
- A **PreBackupPod** CR that runs `PRAGMA wal_checkpoint(TRUNCATE)` on the SQLite database before each backup (SQLite mode only — skipped when `postgres` is configured)

```cue
config: seerr.#config & {
    storage: config: {
        type:         "pvc"
        size:         "5Gi"
        storageClass: "local-path"
    }
    backup: {
        configPvcName: "seerr-seerr-config"
        s3: {
            endpoint: "http://garage.storage.svc:3900"
            bucket:   "seerr-backup"
            accessKeyID: {
                $secretName: "backup-s3"
                $dataKey:    "access-key-id"
            }
            secretAccessKey: {
                $secretName: "backup-s3"
                $dataKey:    "secret-access-key"
            }
        }
        repoPassword: {
            $secretName: "backup-restic"
            $dataKey:    "password"
        }
    }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `backup` | `struct?` | — | K8up backup configuration |
| `backup.configPvcName` | `string` | — | PVC name as rendered by OPM |
| `backup.schedule` | `string` | `0 2 * * *` | Backup cron (daily 2 AM) |
| `backup.s3.endpoint` | `string` | — | S3 endpoint URL |
| `backup.s3.bucket` | `string` | — | S3 bucket name |
| `backup.s3.accessKeyID` | `#Secret` | — | S3 access key secret |
| `backup.s3.secretAccessKey` | `#Secret` | — | S3 secret key secret |
| `backup.repoPassword` | `#Secret` | — | Restic repository password |
| `backup.retention.keepDaily` | `int` | `7` | Daily snapshots to keep |
| `backup.retention.keepWeekly` | `int` | `4` | Weekly snapshots to keep |
| `backup.retention.keepMonthly` | `int` | `6` | Monthly snapshots to keep |
| `backup.checkSchedule` | `string` | `0 4 * * 0` | Integrity check cron |
| `backup.pruneSchedule` | `string` | `0 5 * * 0` | Prune cron |

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
