# Zot TTL Registry Module

Ephemeral OCI registry with automatic image expiration for CI/CD and short-lived workloads.

## Overview

This OPM module deploys a self-hosted [Zot](https://zotregistry.dev) registry configured for ephemeral use — a self-hosted alternative to [ttl.sh](https://ttl.sh). Images are automatically expired and garbage-collected based on retention policies keyed to the repository path. There is no authentication by default, making it suitable for throwaway CI artifacts, integration test images, and developer scratch builds.

Use this module when you need:

- Anonymous push and pull without managing credentials
- Automatic cleanup of stale images without manual intervention
- A private, in-cluster alternative to public ephemeral registries
- Short-lived images for pipelines that should not accumulate in a long-lived registry

## Features

| Feature | Description |
|---------|-------------|
| **No auth** | Anonymous push and pull by default |
| **TTL policies** | Retention rules expire images by push/pull age per repo path |
| **Path-based TTL routing** | Route to `1h/`, `6h/`, `24h/` paths to select expiry window |
| **Frequent GC** | Garbage collection runs every 1h to reclaim space promptly |
| **Lightweight storage** | Defaults to `emptyDir`; opt into PVC for persistence across restarts |
| **Health probes** | Startup, liveness, and readiness probes |
| **Ingress** | Optional HTTPRoute for Gateway API |

## Quick Start

### 1. Deploy with Default Settings

```bash
opm mod apply ./zot-registry-ttl
```

This creates:

- 1 replica with `emptyDir` storage (ephemeral across pod restarts)
- Anonymous push and pull enabled
- Default 24h TTL for unmatched paths
- Garbage collection every 1h
- TTL paths: `1h/`, `6h/`, `24h/`

### 2. Deploy with Custom TTL Windows

```cue
values: {
    ttl: {
        policies: [{
            repositories: ["30m/**"]
            pushedWithin: "30m"
            pulledWithin: "30m"
        }, {
            repositories: ["1h/**"]
            pushedWithin: "1h"
            pulledWithin: "1h"
        }, {
            repositories: ["12h/**"]
            pushedWithin: "12h"
            pulledWithin: "12h"
        }]
        defaultTTL: "12h"
    }
}
```

## Configuration

### TTL Policies

Zot does not support per-tag TTL in the image name. Instead, retention is configured per repository path using `pushedWithin` and `pulledWithin` durations. When GC runs, any image tag that has not been pushed or pulled within the configured window is eligible for deletion after the grace `delay`.

```cue
ttl: {
    policies: [{
        repositories: ["1h/**"]
        pushedWithin: "1h"
        pulledWithin: "1h"
    }, {
        repositories: ["6h/**"]
        pushedWithin: "6h"
        pulledWithin: "6h"
    }, {
        repositories: ["24h/**"]
        pushedWithin: "24h"
        pulledWithin: "24h"
    }]
    defaultTTL: "24h"  // applied to paths not matched by any policy
    delay:      "1h"   // grace period before a matched image is deleted
}
```

- `pushedWithin` — keep the tag if it was pushed within this duration
- `pulledWithin` — keep the tag if it was pulled within this duration
- `defaultTTL` — fallback window for repositories not matched by any policy entry
- `delay` — minimum time between a tag becoming eligible and its actual deletion

### Storage

By default the registry uses `emptyDir` storage, which means images are lost if the pod is rescheduled. For CI use cases this is usually acceptable. Switch to `pvc` to survive pod restarts:

```cue
storage: {
    type:         "pvc"
    size:         "50Gi"
    storageClass: "standard"
    gc: {
        delay:    "1h"
        interval: "1h"
    }
}
```

| Field | Default | Description |
|-------|---------|-------------|
| `type` | `"emptyDir"` | Storage backend: `"emptyDir"` or `"pvc"` |
| `size` | `"20Gi"` | PVC capacity (ignored when `type` is `"emptyDir"`) |
| `storageClass` | `"standard"` | StorageClass for the PVC |
| `gc.delay` | `"1h"` | Wait after a blob loses all references before deleting it |
| `gc.interval` | `"1h"` | How often the GC loop runs |

### Ingress

Expose the registry outside the cluster with a Gateway API HTTPRoute:

```cue
httpRoute: {
    hostnames: ["registry.example.com"]

    tls: {
        secretName: "registry-tls"
    }

    gatewayRef: {
        name:      "cluster-gateway"
        namespace: "gateway-system"
    }
}
```

## How TTL Routing Works

Zot retention policies match on repository path prefixes. This module uses a path-as-TTL convention: push your image under a path that names the desired expiry window, and the matching policy takes effect.

```text
registry.example.com/1h/myimage:tag   -> expires ~1h after last push or pull
registry.example.com/6h/myimage:tag   -> expires ~6h after last push or pull
registry.example.com/24h/myimage:tag  -> expires ~24h after last push or pull
registry.example.com/myimage:tag      -> expires per defaultTTL (24h by default)
```

Push example:

```bash
docker push registry.example.com/1h/ci-build-${BUILD_ID}:latest
```

Pull the image in a subsequent pipeline step as normal:

```bash
docker pull registry.example.com/1h/ci-build-${BUILD_ID}:latest
```

The tag is eligible for deletion once its `pushedWithin` and `pulledWithin` windows have both elapsed and the GC interval fires. The `delay` adds an additional grace period before the blob is removed from disk.

Note: unlike ttl.sh, the TTL is not encoded in the tag itself (`:1h`). The path prefix (`1h/`) is what determines the retention policy. Tags may be named freely.

## Comparison: zot_registry_ttl vs ttl.sh

| Capability | zot_registry_ttl | ttl.sh |
|------------|-----------------|--------|
| Self-hosted | [x] | [ ] |
| Anonymous push/pull | [x] | [x] |
| TTL encoded in tag name | [ ] | [x] (`:1h`, `:24h`) |
| TTL encoded in path | [x] (`1h/`, `24h/`) | [ ] |
| Per-tag TTL granularity | [ ] | [x] |
| Private / in-cluster | [x] | [ ] |
| No rate limits | [x] | dependent on service |
| Persistent across restarts | optional (PVC) | n/a |
| Authentication support | [ ] (by design) | [ ] |

## Examples

### Example 1: Default Ephemeral Registry

Zero configuration. Ships with `1h`, `6h`, and `24h` TTL paths and `emptyDir` storage.

```cue
values: {}
```

Push an image and it will expire after 24h (the default) if it is not pulled:

```bash
docker push registry.svc.cluster.local:5000/24h/my-test-image:latest
```

### Example 2: Custom TTL Windows

Add a short-lived 15-minute window for fast-feedback loops and remove the 6h window:

```cue
values: {
    ttl: {
        policies: [{
            repositories: ["15m/**"]
            pushedWithin: "15m"
            pulledWithin: "15m"
        }, {
            repositories: ["1h/**"]
            pushedWithin: "1h"
            pulledWithin: "1h"
        }, {
            repositories: ["24h/**"]
            pushedWithin: "24h"
            pulledWithin: "24h"
        }]
        defaultTTL: "1h"
        delay:      "15m"
    }
    storage: {
        gc: {
            delay:    "15m"
            interval: "15m"
        }
    }
}
```

### Example 3: Persistent Registry with Ingress

Use PVC storage so images survive pod restarts, and expose the registry over TLS:

```cue
values: {
    storage: {
        type:         "pvc"
        size:         "100Gi"
        storageClass: "fast-ssd"
        gc: {
            delay:    "1h"
            interval: "1h"
        }
    }

    ttl: {
        policies: [{
            repositories: ["1h/**"]
            pushedWithin: "1h"
            pulledWithin: "1h"
        }, {
            repositories: ["24h/**"]
            pushedWithin: "24h"
            pulledWithin: "24h"
        }]
        defaultTTL: "24h"
        delay:      "1h"
    }

    httpRoute: {
        hostnames: ["ephemeral-registry.example.com"]
        tls: {
            secretName: "ephemeral-registry-tls"
        }
        gatewayRef: {
            name:      "cluster-gateway"
            namespace: "gateway-system"
        }
    }
}
```

## Configuration Reference

See [module.cue](./module.cue) for the complete `#config` schema.

## Resources

- [Zot Documentation](https://zotregistry.dev)
- [Zot GitHub](https://github.com/project-zot/zot)
- [Zot Retention Policies](https://zotregistry.dev/latest/articles/retention/)
- [OCI Distribution Spec](https://github.com/opencontainers/distribution-spec)

## License

This module follows the same license as the OPM project. Zot itself is Apache 2.0 licensed.
