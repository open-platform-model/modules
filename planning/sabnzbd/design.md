# SABnzbd OPM Module — Design

> For reusable CUE patterns used in implementing this module, see [`modules/DESIGN_PATTERNS.md`](../../DESIGN_PATTERNS.md).

## Overview

SABnzbd is a Usenet binary newsreader and download client. It monitors NZB files, manages a
download queue, decodes binaries from Usenet servers, and runs post-processing scripts (repair,
unpack, move). It exposes a web UI and REST API on port 8080. In the arr-stack, SABnzbd acts
as the download backbone — Sonarr and Radarr push NZB files to it and poll for completion.

## Architecture

| Aspect | Detail |
|--------|--------|
| Workload type | Stateful (single replica, PVC-backed) |
| Container count | 2 (init: `config-seed`, main: `sabnzbd`) |
| Image family | LinuxServer.io (PUID/PGID pattern) |
| Config format | INI file at `/config/sabnzbd.ini` |
| Config strategy | CUE-rendered INI → ConfigMap → init container seeds on first start |
| Health check | HTTP GET `/api?mode=version` on port 8080 |

### Init container: `config-seed`

Uses `alpine` (or `busybox`) to check whether `/config/sabnzbd.ini` already exists. If it does
not, it copies the rendered seed file from the mounted ConfigMap. This preserves runtime-managed
state (API key, paired servers, runtime-written settings) across restarts and module upgrades.

```
[ -f /config/sabnzbd.ini ] || cp /seed/sabnzbd.ini /config/sabnzbd.ini
```

The ConfigMap is mounted read-only at `/seed`; the config PVC is mounted read-write at `/config`.

### Main container: `sabnzbd`

Standard LinuxServer.io container. Receives `PUID`, `PGID`, `TZ`, and optional `UMASK`. Writes
all persistent state (database, queue, history, incomplete files) under `/config`.

## Container Image

| Field | Value |
|-------|-------|
| Registry | `lscr.io` |
| Repository | `linuxserver/sabnzbd` |
| Default tag | `latest` |
| Pinned version | `v4.5.5` (set `tag: "v4.5.5"` in release) |
| Digest | `""` (pull by tag) |
| Architecture | multi-arch (amd64, arm64) |

Tag strategy: default `latest` for development; pin to a semver tag in production releases.

## OPM Module Design

| Field | Value |
|-------|--------|
| Module path | `opmodel.dev/modules/sabnzbd` |
| CUE package | `sabnzbd` |
| `cue.mod` module | `opmodel.dev/modules/sabnzbd@v1` |
| Default namespace | `sabnzbd` |
| Version | `0.1.0` |

## `#config` Schema

```cue
package sabnzbd

import (
    m       "opmodel.dev/core/v1alpha1/module@v1"
    schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)

m.#Module

// #storageVolume is the shared schema for all volume entries.
#storageVolume: {
    mountPath:     string
    type:          "pvc" | "emptyDir" | "nfs"
    size?:         string // required when type == "pvc"
    storageClass?: string // optional storage class for pvc
    server?:       string // required when type == "nfs"
    path?:         string // required when type == "nfs"
}

// #usenetServer describes a single Usenet provider connection.
#usenetServer: {
    name:        string
    host:        string
    port:        int | *563
    ssl:         bool | *true
    connections: int | *8
    username?:   schemas.#Secret
    password?:   schemas.#Secret
}

// #downloadCategory describes a SABnzbd post-processing category.
#downloadCategory: {
    name:    string
    dir?:    string  // subdirectory under complete_dir for this category
    pp?:     int | *3  // post-processing level: 0=none,1=repair,2=+unpack,3=+delete
    script?: string  // post-processing script name
}

// #sabnzbdIniConfig holds optional INI settings to pre-seed.
// When set, a ConfigMap is rendered and an init container seeds
// /config/sabnzbd.ini on first start only.
#sabnzbdIniConfig: {
    // Comma-separated hostnames allowed to reach the web UI.
    // Use "*" to allow any host (development only).
    hostWhitelist?: string

    // Override the download directory (defaults to storage.downloads.mountPath).
    downloadDir?: string

    // Override the completed download directory.
    completeDir?: string

    // Override the incomplete download directory.
    incompleteDir?: string

    // SABnzbd API key — if not set, SABnzbd auto-generates one on first start.
    apiKey?: schemas.#Secret & {
        $secretName:  "sabnzbd"
        $dataKey:     "api-key"
        $description: "SABnzbd REST API key"
    }

    // Usenet server connections.
    servers?: [...#usenetServer]

    // Download categories for Sonarr/Radarr routing.
    categories?: [...#downloadCategory]
}

#config: {
    // Container image
    image: schemas.#Image & {
        repository: string | *"linuxserver/sabnzbd"
        tag:        string | *"latest"
        digest:     string | *""
    }

    // Web UI port
    port: int & >0 & <=65535 | *8080

    // LinuxServer.io identity
    puid: int | *1000
    pgid: int | *1000

    // Container timezone
    timezone: string | *"Europe/Stockholm"

    // Optional: file creation mask (e.g. "002" for group-writable files)
    umask?: string

    // All storage volumes in one place.
    storage: {
        // Application data — queue, history, database, config file.
        config: #storageVolume & {
            mountPath: *"/config" | string
            type:      *"pvc" | "emptyDir" | "nfs"
            size:      string | *"10Gi"
        }
        // Completed downloads — Sonarr/Radarr import from here.
        downloads: #storageVolume & {
            mountPath: string | *"/downloads"
        }
        // In-progress downloads (optional — saves config volume space).
        incomplete?: #storageVolume & {
            mountPath: string | *"/incomplete-downloads"
        }
    }

    // Kubernetes Service type
    serviceType: "ClusterIP" | "NodePort" | "LoadBalancer" | *"ClusterIP"

    // Resource requests and limits (optional)
    resources?: schemas.#ResourceRequirementsSchema

    // Optional: pre-seed sabnzbd.ini on first start.
    // When absent, SABnzbd starts with its built-in defaults.
    sabnzbdConfig?: #sabnzbdIniConfig

    // Image used by the config-seed init container.
    // Needs only a POSIX shell with cp and test. Alpine or busybox are suitable.
    seedImage: schemas.#Image & {
        repository: string | *"alpine"
        tag:        string | *"3.21"
        digest:     string | *""
    }
}
```

## Storage Layout

| Volume name | Mount path (main) | Type | Default size | Notes |
|-------------|-------------------|------|--------------|-------|
| `config` | `/config` | PVC | `10Gi` | All app state, DB, rendered INI |
| `downloads` | `/downloads` | PVC or NFS | user-defined | Completed download target |
| `incomplete` | `/incomplete-downloads` | PVC (optional) | user-defined | In-progress files |
| `sabnzbd-config-seed` | `/seed` (init only) | ConfigMap | — | Read-only seed INI, init container only |

## Network Configuration

| Port | Protocol | Name | Purpose |
|------|----------|------|---------|
| `8080` | TCP | `http` | Web UI + REST API |

`serviceType` defaults to `ClusterIP`. Use `LoadBalancer` when exposing via MetalLB or `NodePort`
for bare-metal without a load balancer controller.

## Environment Variables

| Variable | Source | Default | Notes |
|----------|--------|---------|-------|
| `PUID` | `#config.puid` | `1000` | Run as user ID |
| `PGID` | `#config.pgid` | `1000` | Run as group ID |
| `TZ` | `#config.timezone` | `"Europe/Stockholm"` | Container timezone |
| `UMASK` | `#config.umask` | — | Only emitted when set |

## Declarative Configuration Strategy

SABnzbd stores all settings in `/config/sabnzbd.ini`. This file is runtime-managed: SABnzbd
writes back to it when settings change, API keys are generated, or servers are modified through
the UI. A pure ConfigMap mount would be overwritten on every restart.

**Strategy: seed-once via init container**

1. CUE renders `sabnzbd.ini` as a template string using string interpolation (CUE has no native
   INI encoder). The rendered content is stored in a ConfigMap `sabnzbd-config-seed` keyed as
   `sabnzbd.ini`.
2. An init container `config-seed` (Alpine/busybox) mounts the ConfigMap read-only at `/seed`
   and the config PVC read-write at `/config`.
3. The init container runs: `[ -f /config/sabnzbd.ini ] || cp /seed/sabnzbd.ini /config/sabnzbd.ini`
4. On first start: the seed file is copied. On subsequent starts: the existing file (with runtime
   mutations) is left untouched.
5. The init container is only present in `#components` when `#config.sabnzbdConfig != _|_`.

**INI rendering approach in components.cue:**

```cue
// Rendered by CUE string interpolation — CUE has no encoding/ini package.
// Only the [misc] section is pre-rendered; [servers] and [categories] are
// appended as additional sections via string interpolation.
let _ini = """
[misc]
host_whitelist = \(#config.sabnzbdConfig.hostWhitelist)
port = \(#config.port)
download_dir = \(#config.sabnzbdConfig.downloadDir)
complete_dir = \(#config.sabnzbdConfig.completeDir)
"""
```

For secret fields (API key, server credentials), use `from: schemas.#Secret` in env vars rather
than embedding raw values into the INI string. The seeded INI omits the `api_key` field so
SABnzbd generates one on first start, or injects it via a post-start hook if `apiKey` is set.

## ConfigMap Design

| ConfigMap name | Key | Condition | Immutable | Notes |
|----------------|-----|-----------|-----------|-------|
| `sabnzbd-config-seed` | `sabnzbd.ini` | `#config.sabnzbdConfig != _|_` | `false` | Mutable so config changes don't require name rotation |

The ConfigMap is `immutable: false` because the seed-once pattern means runtime changes are
preserved in the PVC regardless of ConfigMap mutations. Changing the ConfigMap only affects
fresh deployments or pods manually reset by deleting `/config/sabnzbd.ini`.

## Secrets

| Secret reference | Field | Description |
|-----------------|-------|-------------|
| `schemas.#Secret { $secretName: "sabnzbd", $dataKey: "api-key" }` | `sabnzbdConfig.apiKey` | SABnzbd REST API key |
| `schemas.#Secret { $secretName: "usenet-<name>", $dataKey: "username" }` | `sabnzbdConfig.servers[].username` | Usenet provider username |
| `schemas.#Secret { $secretName: "usenet-<name>", $dataKey: "password" }` | `sabnzbdConfig.servers[].password` | Usenet provider password |

## Dev Release Values

```cue
// releases/kind_opm_dev/sabnzbd/release.cue
package sabnzbd

import (
    mr "opmodel.dev/core/v1alpha1/modulerelease@v1"
    m  "opmodel.dev/modules/sabnzbd@v1"
)

mr.#ModuleRelease

metadata: {
    name:      "sabnzbd"
    namespace: "sabnzbd"
}

#module: m

values: {
    port:        8080
    puid:        3005
    pgid:        3005
    timezone:    "Europe/Stockholm"
    serviceType: "ClusterIP"

    resources: {
        requests: {
            cpu:    "250m"
            memory: "512Mi"
        }
        limits: {
            cpu:    "2000m"
            memory: "2Gi"
        }
    }

    storage: {
        config: {
            type:         "pvc"
            size:         "10Gi"
            storageClass: "standard"
        }
        downloads: {
            mountPath: "/downloads"
            type:      "pvc"
            size:      "100Gi"
            storageClass: "standard"
        }
    }

    sabnzbdConfig: {
        hostWhitelist: "sabnzbd.kind.larnet.eu,localhost"
        downloadDir:   "/downloads"
        completeDir:   "/downloads/complete"
    }
}
```
