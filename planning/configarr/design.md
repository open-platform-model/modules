# Configarr OPM Module — Design

> For reusable CUE patterns used in implementing this module, see [`modules/DESIGN_PATTERNS.md`](../../DESIGN_PATTERNS.md).

## Overview

Configarr is a declarative sync tool for Sonarr and Radarr custom formats and quality profiles.
It reads a YAML configuration file that references TRaSH Guides custom format IDs and quality
profile definitions, then pushes them to Sonarr/Radarr via their REST APIs. It runs to
completion (exits 0 on success) — making it a natural fit for a Kubernetes Job. In the
arr-stack, Configarr is the "GitOps layer" for media quality settings: run it once after
deploying Sonarr/Radarr, or on a schedule to keep settings in sync with upstream TRaSH updates.

## Architecture

| Aspect | Detail |
|--------|--------|
| Workload type | Task/Job (run-to-completion, no service) |
| Container count | 1 (main: `configarr`) |
| Image family | Custom (raydak-labs), NOT LinuxServer — no PUID/PGID |
| Runtime | Node.js process |
| Config format | YAML at `/app/config/config.yml` — **fully declarative** |
| Config strategy | CUE renders config.yml via `yaml.Marshal` → ConfigMap → direct volume mount |
| Port | None — no service exposed |

Configarr is **fully declarative**: there is no runtime state to preserve. The entire
`config.yml` is rendered from CUE at build time, stored in a ConfigMap, and mounted directly
into the container. No init container is needed.

### Main container: `configarr`

Reads `/app/config/config.yml`, fetches TRaSH Guides definitions from GitHub (or a local
cache), and calls Sonarr/Radarr APIs to sync formats and quality profiles. Exits 0 on success,
non-zero on failure. The Job's `backoffLimit` controls retry behaviour.

Uses `blueprints_workload.#TaskWorkload` (the OPM Job blueprint), not `resources_workload.#Container`.

## Container Image

| Field | Value |
|-------|-------|
| Registry | `ghcr.io` |
| Repository | `ghcr.io/raydak-labs/configarr` |
| Default tag | `v1.24.0` |
| Digest | `""` (pull by tag) |
| Architecture | multi-arch (amd64, arm64) |

Tag strategy: pin to a semver tag. Configarr's YAML schema evolves with TRaSH Guides changes;
always test after upgrading.

## OPM Module Design

| Field | Value |
|-------|--------|
| Module path | `opmodel.dev/modules/configarr` |
| CUE package | `configarr` |
| `cue.mod` module | `opmodel.dev/modules/configarr@v1` |
| Default namespace | `configarr` |
| Version | `0.1.0` |

## `#config` Schema

```cue
package configarr

import (
    m       "opmodel.dev/core/v1alpha1/module@v1"
    schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)

m.#Module

// #profileAssignment links a custom format to a quality profile with an optional score.
#profileAssignment: {
    name:   string
    score?: int | null  // null resets to default TRaSH score
}

// #customFormatSync defines which TRaSH custom formats to sync and where to assign them.
#customFormatSync: {
    // TRaSH Guide custom format IDs to import/sync.
    trashIds?: [...string]

    // Quality profiles to assign these formats to (with optional score overrides).
    // Both field names are supported for compatibility with different Configarr versions.
    assign_scores_to?: [...#profileAssignment]
    quality_profiles?: [...#profileAssignment]
}

// #qualityProfileSync defines the shape of a synced quality profile.
#qualityProfileSync: {
    name:               string
    upgradeUntilScore?: int
    minFormatScore?:    int
    qualitySort?:       string  // e.g. "top" or "bottom"
    qualities?:         [...string]
}

// #configarrTarget describes a single Sonarr or Radarr instance to sync.
#configarrTarget: {
    // Base URL of the Sonarr/Radarr instance (e.g. "http://sonarr:8989").
    url: string

    // API key — injected from a Kubernetes Secret.
    apiKey: schemas.#Secret & {
        $secretName:  "configarr"
        $dataKey:     "api-key"
        $description: "Sonarr or Radarr API key for Configarr sync"
    }

    // TRaSH quality definition template to apply (e.g. "movie", "series", "anime").
    // When set, Configarr updates the quality definition sizes from TRaSH Guides.
    qualityDefinition?: {
        type: string
    }

    // Custom format sync rules. Each entry imports TRaSH format IDs and assigns
    // them to quality profiles with optional score overrides.
    customFormats?: [...#customFormatSync]

    // Quality profile shape definitions.
    qualityProfiles?: [...#qualityProfileSync]
}

// #jobConfig controls Kubernetes Job retry and timeout behaviour.
#jobConfig: {
    // Number of retry attempts before the Job is marked failed.
    backoffLimit: int | *3

    // Maximum seconds the Job may run before being terminated.
    activeDeadlineSeconds: int | *300
}

#config: {
    // Container image
    image: schemas.#Image & {
        repository: string | *"ghcr.io/raydak-labs/configarr"
        tag:        string | *"v1.24.0"
        digest:     string | *""
    }

    // Application log level
    logLevel: "debug" | "info" | "warn" | "error" | *"info"

    // When true, Configarr prints what it would change without making API calls.
    dryRun: bool | *false

    // Kubernetes Job configuration
    jobConfig: #jobConfig

    // Resource requests and limits (optional)
    resources?: schemas.#ResourceRequirementsSchema

    // Sonarr instances to sync. At least one of sonarr or radarr must be set.
    sonarr?: [...#configarrTarget]

    // Radarr instances to sync.
    radarr?: [...#configarrTarget]
}
```

## Storage Layout

Configarr has no persistent storage. The only volume is a ConfigMap-backed volume:

| Volume name | Mount path | Type | Notes |
|-------------|-----------|------|-------|
| `configarr-config` | `/app/config` | ConfigMap | Contains `config.yml` — always present |

No PVC is required. Configarr is stateless: each Job run is idempotent.

## Network Configuration

None. Configarr is a Job — no ports, no Service, no health checks. It communicates outbound
only (to Sonarr/Radarr REST APIs and GitHub for TRaSH Guides data).

## Environment Variables

| Variable | Source | Default | Notes |
|----------|--------|---------|-------|
| `LOG_LEVEL` | `#config.logLevel` | `"info"` | App log verbosity |
| `DRY_RUN` | `#config.dryRun` | `"false"` | Set to `"true"` for preview mode |

Sonarr/Radarr API keys are NOT passed as environment variables — they are embedded in
`config.yml` via `schemas.#Secret` references that the OPM transformer resolves to
`secretKeyRef` entries in the YAML.

**Important:** The `apiKey` field in `#configarrTarget` uses `schemas.#Secret`. When rendering
`config.yml`, the CUE code must dereference the secret value or use a supported Configarr
env-var substitution syntax. Check Configarr docs for `${ENV_VAR}` interpolation support
in `config.yml`. If supported, inject secrets as env vars and reference them in the YAML string.

## Declarative Configuration Strategy

Configarr's config.yml is **fully declarative** — there is no runtime state to preserve. The
entire file is rendered from CUE at build time.

**Strategy: direct ConfigMap mount**

1. CUE renders `config.yml` using `encoding/yaml.Marshal` in `components.cue`. The rendered
   YAML is stored in a ConfigMap `configarr-config` keyed as `config.yml`.
2. The ConfigMap is mounted directly at `/app/config` in the main container (no init container).
3. On every Job run, the container reads the freshly mounted `config.yml` — always up-to-date.

**YAML rendering approach in components.cue:**

```cue
import "encoding/yaml"

configMaps: {
    "configarr-config": {
        immutable: false
        data: {
            "config.yml": "\(yaml.Marshal({
                if #config.sonarr != _|_ {
                    sonarr: [
                        for s in #config.sonarr {
                            url:    s.url
                            api_key: s.apiKey
                            if s.qualityDefinition != _|_ {
                                quality_definition: s.qualityDefinition
                            }
                            if s.customFormats != _|_ {
                                custom_formats: s.customFormats
                            }
                            if s.qualityProfiles != _|_ {
                                quality_profiles: s.qualityProfiles
                            }
                        }
                    ]
                }
                if #config.radarr != _|_ {
                    radarr: [
                        for r in #config.radarr {
                            url:    r.url
                            api_key: r.apiKey
                            if r.qualityDefinition != _|_ {
                                quality_definition: r.qualityDefinition
                            }
                            if r.customFormats != _|_ {
                                custom_formats: r.customFormats
                            }
                            if r.qualityProfiles != _|_ {
                                quality_profiles: r.qualityProfiles
                            }
                        }
                    ]
                }
            }))"
        }
    }
}
```

**Secret handling in YAML:** Configarr v1.24+ supports `${ENV_VAR}` substitution in
`config.yml`. Use this pattern: inject the secret as an env var named e.g.
`SONARR_API_KEY`, and reference it in the YAML as `api_key: "${SONARR_API_KEY}"`. This keeps
the secret out of the ConfigMap data entirely. Document this in `components.cue` comments.

## ConfigMap Design

| ConfigMap name | Key | Condition | Immutable | Notes |
|----------------|-----|-----------|-----------|-------|
| `configarr-config` | `config.yml` | Always | `false` | Full config, always rendered from CUE |

`immutable: false` so that config changes take effect on the next Job run without requiring
a new ConfigMap name. Since the Job creates a fresh pod each run, it always reads the current
ConfigMap.

## Secrets

| Secret reference | Field | Description |
|-----------------|-------|-------------|
| `schemas.#Secret { $secretName: "configarr", $dataKey: "sonarr-api-key" }` | `sonarr[].apiKey` | Sonarr API key |
| `schemas.#Secret { $secretName: "configarr", $dataKey: "radarr-api-key" }` | `radarr[].apiKey` | Radarr API key |

Each target instance may use a different secret key. Recommend using a single `configarr`
Secret with multiple data keys: `sonarr-api-key`, `radarr-api-key`, `sonarr-4k-api-key`, etc.

## Dev Release Values

```cue
// releases/kind_opm_dev/configarr/release.cue
package configarr

import (
    mr "opmodel.dev/core/v1alpha1/modulerelease@v1"
    m  "opmodel.dev/modules/configarr@v1"
)

mr.#ModuleRelease

metadata: {
    name:      "configarr"
    namespace: "configarr"
}

#module: m

values: {
    logLevel: "info"
    dryRun:   false

    jobConfig: {
        backoffLimit:          3
        activeDeadlineSeconds: 300
    }

    resources: {
        requests: {
            cpu:    "100m"
            memory: "256Mi"
        }
        limits: {
            cpu:    "500m"
            memory: "512Mi"
        }
    }

    sonarr: [{
        url:    "http://sonarr.sonarr.svc.cluster.local:8989"
        apiKey: {secretKeyRef: {name: "configarr", key: "sonarr-api-key"}}
        qualityDefinition: {
            type: "series"
        }
        customFormats: [{
            trashIds: ["9c38ebb7384dada637be8899efa68e6f"]  // example: x265
            quality_profiles: [{name: "HD-1080p", score: 0}]
        }]
    }]

    radarr: [{
        url:    "http://radarr.radarr.svc.cluster.local:7878"
        apiKey: {secretKeyRef: {name: "configarr", key: "radarr-api-key"}}
        qualityDefinition: {
            type: "movie"
        }
        customFormats: [{
            trashIds: ["9c38ebb7384dada637be8899efa68e6f"]
            quality_profiles: [{name: "HD-1080p", score: 0}]
        }]
    }]
}
```
