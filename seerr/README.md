# Seerr Module

Media request management for Jellyfin, Plex, and Emby. Allows users to request movies and TV shows which are automatically sent to Radarr/Sonarr for download.

- **Image:** `ghcr.io/seerr-team/seerr`
- **Port:** 5055
- **Upstream:** https://github.com/seerr-team/seerr
- **Module path:** `opmodel.dev/modules/seerr@v1`

> **v1 — rebased onto the OPM core catalog** (`opmodel.dev/catalogs/opm@v0`). The
> previous K8up backup, external PostgreSQL, and API-key-secret options were
> dropped to keep the module minimal: Seerr runs standalone on SQLite stored on
> the config PVC.

## Architecture

Single stateful container with a persistent volume for the SQLite database and application settings. Seerr stores all configuration (media server connections, Radarr/Sonarr integrations, user permissions, notifications) in its database.

```text
seerr (StatefulSet, replicas: 1)
  └── seerr container (port 5055)
        └── /app/config (PVC) — SQLite DB, settings.json, logs
```

The component composes the catalog's `#StatefulWorkload` blueprint (Container + Volumes + scaling/restart/update/init traits), an `#Expose` trait for the Service, a `#SecurityContext` trait (`fsGroup: 1000`), and — when `httpRoute` is set — an `#HttpRoute` trait.

## Post-Deploy Setup

Seerr requires a **mandatory setup wizard** on first access via the web UI. This cannot be bypassed or pre-configured via files or environment variables.

1. Open the Seerr web UI (port 5055 or via your HTTPRoute)
2. Create the admin account
3. Connect your media server (Jellyfin, Plex, or Emby)
4. Configure Radarr and/or Sonarr integrations
5. Set up user permissions and notification agents as needed

All subsequent configuration changes can be made through the web UI or the REST API at `/api/v1/`.

## Quick Start (ModuleRelease)

```yaml
apiVersion: releases.opmodel.dev/v1alpha1
kind: ModuleRelease
metadata:
  name: seerr
  namespace: seerr
spec:
  module:
    path: opmodel.dev/modules/seerr@v1
    version: v1.0.0
  serviceAccountName: opm-applier
  prune: true
  values:
    timezone: Europe/Stockholm
    serviceType: ClusterIP
    storage:
      config:
        type: pvc
        size: 5Gi
        storageClass: standard
```

## Configuration Reference

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `image` | `#Image` | `ghcr.io/seerr-team/seerr:v3.1.0` | Container image (digest-pinned) |
| `port` | `int` | `5055` | Web UI and API port |
| `timezone` | `string` | `Europe/Stockholm` | Container timezone (TZ format) |
| `logLevel` | `string?` | — | Log level: `debug`, `info`, `warn`, `error` |
| `storage.config` | `#storageVolume` | PVC 5Gi at `/app/config` | Application data volume (`pvc` / `emptyDir` / `nfs`) |
| `serviceType` | `string` | `ClusterIP` | Kubernetes Service type |
| `httpRoute` | `struct?` | — | Gateway API HTTPRoute config |
| `resources` | `#ResourceRequirementsSchema?` | — | CPU/memory requests and limits |
