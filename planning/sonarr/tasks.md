# Sonarr OPM Module — Implementation Tasks

## Step 1: Scaffold Module Directory

```sh
mkdir -p modules/sonarr/cue.mod
```

Resulting layout:
```
modules/sonarr/
  cue.mod/
    module.cue
  module.cue
  components.cue
  README.md
```

## Step 2: Create cue.mod/module.cue

Create `modules/sonarr/cue.mod/module.cue`:

```cue
module: "opmodel.dev/modules/sonarr@v1"
language: {
    version: "v0.15.0"
}
source: {
    kind: "self"
}
deps: {
    "opmodel.dev/core/v1alpha1@v1": {
        v: "v1.3.1"
    }
    "opmodel.dev/opm/v1alpha1@v1": {
        v: "v1.5.3"
    }
}
```

> **Do not hand-edit version pins.** After writing this file, run `task update-deps` from the workspace root to resolve the latest compatible versions. The versions above are current as of the time of writing; they may need updating.

## Step 3: Write module.cue

Create `modules/sonarr/module.cue`. This file contains: module metadata, shared helper types (`#storageVolume`, `#servarrConfig`, `#exportarrSidecar`), the `#config` schema, and `debugValues`.

```cue
// Package sonarr defines the Sonarr TV series downloader module.
// Servarr-based stateful application using the LinuxServer.io image.
// - module.cue:     metadata, shared helpers, #config schema
// - components.cue: workload component definitions
package sonarr

import (
    m       "opmodel.dev/core/v1alpha1/module@v1"
    schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)

// Module definition
m.#Module

// Module metadata
metadata: {
    modulePath:       "opmodel.dev/modules"
    name:             "sonarr"
    version:          "0.1.0"
    description:      "Sonarr - automated TV series downloader (Servarr)"
    defaultNamespace: "sonarr"
}

// #storageVolume is the shared schema for all volume entries.
#storageVolume: {
    mountPath:     string
    type:          "pvc" | "emptyDir" | "nfs"
    size?:         string // required when type == "pvc"
    storageClass?: string // optional; only used when type == "pvc"
    server?:       string // required when type == "nfs"
    path?:         string // required when type == "nfs"
}

// #servarrConfig captures declarative Servarr config.xml fields.
// Rendered into a ConfigMap and seeded via init container on first run.
// This type is identical in the Radarr module — keep them in sync.
#servarrConfig: {
    apiKey?:       schemas.#Secret   // pre-seeded API key; Servarr auto-generates if absent
    authMethod?:   "Forms" | "Basic" | "External" | *"External"
    authRequired?: "Enabled" | "DisabledForLocalAddresses" | *"DisabledForLocalAddresses"
    branch?:       string | *"main"
    logLevel?:     "trace" | "debug" | "info" | "warn" | "error" | *"info"
    urlBase?:      string
    instanceName?: string
}

// #exportarrSidecar defines the optional Exportarr Prometheus metrics sidecar.
// When present in #config, a second container is injected into the pod.
#exportarrSidecar: {
    image: schemas.#Image & {
        repository: string | *"ghcr.io/onedr0p/exportarr"
        tag:        string | *"v2.3.0"
        digest:     string | *""
    }
    port:                    int | *9707
    apiKey:                  schemas.#Secret // required
    enableAdditionalMetrics: bool | *false
    enableUnknownQueueItems: bool | *false
    logLevel:                "debug" | "info" | "warn" | "error" | *"info"
    resources?:              schemas.#ResourceRequirementsSchema
}

// #config is the user-facing schema for this module.
#config: {
    image: schemas.#Image & {
        repository: string | *"lscr.io/linuxserver/sonarr"
        tag:        string | *"latest"
        digest:     string | *""
    }

    port: int & >0 & <=65535 | *8989

    puid:     int | *1000
    pgid:     int | *1000
    timezone: string | *"Europe/Stockholm"
    umask?:   string

    storage: {
        config: #storageVolume & {
            mountPath: *"/config" | string
            type:      *"pvc" | "emptyDir" | "nfs"
            size:      string | *"5Gi"
        }
        tv: #storageVolume & {
            mountPath: *"/tv" | string
        }
        downloads: #storageVolume & {
            mountPath: *"/downloads" | string
        }
    }

    serviceType: "ClusterIP" | "NodePort" | "LoadBalancer" | *"ClusterIP"

    resources?: schemas.#ResourceRequirementsSchema

    servarrConfig?: #servarrConfig & {
        instanceName: string | *"Sonarr"
    }

    exportarr?: #exportarrSidecar
}

// debugValues provides a concrete set of values for CUE vet -c validation.
debugValues: {
    image: {
        repository: "lscr.io/linuxserver/sonarr"
        tag:        "latest"
        digest:     ""
    }
    port:        8989
    puid:        3005
    pgid:        3005
    timezone:    "Europe/Stockholm"
    serviceType: "ClusterIP"
    storage: {
        config: {
            mountPath:    "/config"
            type:         "pvc"
            size:         "5Gi"
            storageClass: "local-path"
        }
        tv: {
            mountPath: "/tv"
            type:      "pvc"
            size:      "100Gi"
        }
        downloads: {
            mountPath: "/downloads"
            type:      "pvc"
            size:      "50Gi"
        }
    }
    servarrConfig: {
        authMethod:   "External"
        authRequired: "DisabledForLocalAddresses"
        branch:       "main"
        logLevel:     "info"
        instanceName: "Sonarr"
    }
}
```

## Step 4: Write components.cue

Create `modules/sonarr/components.cue`. Key implementation points:

1. **Init container** — declared only when `#config.servarrConfig != _|_`
2. **ConfigMap `sonarr-config-seed`** — rendered from `#config.servarrConfig` fields into XML
3. **Optional Exportarr sidecar** — injected when `#config.exportarr != _|_`
4. **Volume rendering** — unified type-switch (pvc / emptyDir / nfs) matching the jellyfin pattern

```cue
// Package sonarr defines the Sonarr workload component.
// Stateful single-instance deployment with config.xml seeding via init container.
package sonarr

import (
    resources_config   "opmodel.dev/opm/v1alpha1/resources/config@v1"
    resources_workload "opmodel.dev/opm/v1alpha1/resources/workload@v1"
    resources_storage  "opmodel.dev/opm/v1alpha1/resources/storage@v1"
    traits_workload    "opmodel.dev/opm/v1alpha1/traits/workload@v1"
    traits_network     "opmodel.dev/opm/v1alpha1/traits/network@v1"
    traits_security    "opmodel.dev/opm/v1alpha1/traits/security@v1"
)

#components: {

    ///////////////////////////////////////////////////////////////
    //// Sonarr — Stateful TV Series Downloader
    ///////////////////////////////////////////////////////////////

    sonarr: {
        resources_workload.#Container
        resources_storage.#Volumes
        resources_config.#ConfigMaps
        traits_workload.#Scaling
        traits_workload.#RestartPolicy
        traits_network.#Expose
        traits_security.#SecurityContext

        metadata: name: "sonarr"
        metadata: labels: "core.opmodel.dev/workload-type": "stateful"

        _volumes: spec.volumes

        // All named storage volumes: config always present, tv and downloads required.
        _allVolumes: {
            config:    #config.storage.config
            tv:        #config.storage.tv
            downloads: #config.storage.downloads
        }

        spec: {
            // Servarr does not support horizontal scaling — fixed at 1 replica
            scaling: count: 1

            restartPolicy: "Always"

            // Init container: copy config.xml seed only when it does not already exist.
            // Declared only when servarrConfig is set — absent otherwise.
            if #config.servarrConfig != _|_ {
                initContainers: [{
                    name: "config-seed"
                    image: {
                        repository: "busybox"
                        tag:        "latest"
                        digest:     ""
                    }
                    command: ["sh", "-c", "[ -f /config/config.xml ] || cp /seed/config.xml /config/config.xml"]
                    volumeMounts: {
                        config: {
                            name:      "config"
                            mountPath: "/config"
                        }
                        "sonarr-config-seed": {
                            name:      "sonarr-config-seed"
                            mountPath: "/seed"
                            readOnly:  true
                        }
                    }
                }]
            }

            container: {
                name:  "sonarr"
                image: #config.image
                ports: http: {
                    name:       "http"
                    targetPort: #config.port
                }
                env: {
                    PUID: {
                        name:  "PUID"
                        value: "\(#config.puid)"
                    }
                    PGID: {
                        name:  "PGID"
                        value: "\(#config.pgid)"
                    }
                    TZ: {
                        name:  "TZ"
                        value: #config.timezone
                    }
                    if #config.umask != _|_ {
                        UMASK: {
                            name:  "UMASK"
                            value: #config.umask
                        }
                    }
                }
                livenessProbe: {
                    httpGet: {
                        path: "/ping"
                        port: #config.port
                    }
                    initialDelaySeconds: 30
                    periodSeconds:       10
                    timeoutSeconds:      5
                    failureThreshold:    3
                }
                readinessProbe: {
                    httpGet: {
                        path: "/ping"
                        port: #config.port
                    }
                    initialDelaySeconds: 10
                    periodSeconds:       10
                    timeoutSeconds:      3
                    failureThreshold:    3
                }
                if #config.resources != _|_ {
                    resources: #config.resources
                }
                volumeMounts: {
                    for vName, v in _allVolumes {
                        (vName): _volumes[vName] & {
                            mountPath: v.mountPath
                        }
                    }
                }
            }

            // Optional Exportarr sidecar — only present when exportarr is configured
            if #config.exportarr != _|_ {
                sidecarContainers: [{
                    name:  "exportarr"
                    image: #config.exportarr.image
                    env: {
                        PORT: {
                            name:  "PORT"
                            value: "\(#config.exportarr.port)"
                        }
                        URL: {
                            name:  "URL"
                            value: "http://localhost:\(#config.port)"
                        }
                        APIKEY: {
                            name:      "APIKEY"
                            valueFrom: secretKeyRef: #config.exportarr.apiKey
                        }
                        ENABLE_ADDITIONAL_METRICS: {
                            name:  "ENABLE_ADDITIONAL_METRICS"
                            value: "\(#config.exportarr.enableAdditionalMetrics)"
                        }
                        ENABLE_UNKNOWN_QUEUE_ITEMS: {
                            name:  "ENABLE_UNKNOWN_QUEUE_ITEMS"
                            value: "\(#config.exportarr.enableUnknownQueueItems)"
                        }
                        LOG_LEVEL: {
                            name:  "LOG_LEVEL"
                            value: #config.exportarr.logLevel
                        }
                    }
                    ports: metrics: {
                        name:       "metrics"
                        targetPort: #config.exportarr.port
                    }
                    if #config.exportarr.resources != _|_ {
                        resources: #config.exportarr.resources
                    }
                }]
            }

            expose: {
                ports: http: container.ports.http & {
                    exposedPort: #config.port
                }
                type: #config.serviceType
            }

            // Config seed ConfigMap — only present when servarrConfig is set
            if #config.servarrConfig != _|_ {
                // Resolve optional fields to empty strings for XML rendering
                _apiKeyValue: string | *""
                if #config.servarrConfig.apiKey != _|_ {
                    _apiKeyValue: #config.servarrConfig.apiKey.$value
                }
                _urlBase: string | *""
                if #config.servarrConfig.urlBase != _|_ {
                    _urlBase: #config.servarrConfig.urlBase
                }

                configMaps: {
                    "sonarr-config-seed": {
                        immutable: false
                        data: "config.xml": """
                            <Config>
                              <BindAddress>*</BindAddress>
                              <Port>\(#config.port)</Port>
                              <SslPort>9898</SslPort>
                              <ApiKey>\(_apiKeyValue)</ApiKey>
                              <AuthenticationMethod>\(#config.servarrConfig.authMethod)</AuthenticationMethod>
                              <AuthenticationRequired>\(#config.servarrConfig.authRequired)</AuthenticationRequired>
                              <Branch>\(#config.servarrConfig.branch)</Branch>
                              <LogLevel>\(#config.servarrConfig.logLevel)</LogLevel>
                              <UrlBase>\(_urlBase)</UrlBase>
                              <InstanceName>\(#config.servarrConfig.instanceName)</InstanceName>
                            </Config>
                            """
                    }
                }
            }

            // Volumes rendered from _allVolumes using unified type-switch
            volumes: {
                for name, v in _allVolumes {
                    (name): {
                        "name": name
                        if v.type == "pvc" {
                            persistentClaim: {
                                size: v.size
                                if v.storageClass != _|_ {
                                    storageClass: v.storageClass
                                }
                            }
                        }
                        if v.type == "emptyDir" {
                            emptyDir: {}
                        }
                        if v.type == "nfs" {
                            nfs: {
                                server: v.server
                                path:   v.path
                            }
                        }
                    }
                }

                // Config seed ConfigMap volume — only when servarrConfig is set
                if #config.servarrConfig != _|_ {
                    "sonarr-config-seed": {
                        name:      "sonarr-config-seed"
                        configMap: spec.configMaps["sonarr-config-seed"]
                    }
                }
            }
        }
    }
}
```

> **Note on secret ref resolution:** The `_apiKeyValue` pattern above is a sketch. The actual CUE expression depends on how `schemas.#Secret` exposes its resolved value in the OPM schema. Check the catalog's `schemas` package or existing modules for the correct field path (`.$value`, `.value`, or similar).

## Step 5: Write README.md

Create `modules/sonarr/README.md` covering:
- What Sonarr does and why it is packaged here
- Architecture diagram (copy from design.md)
- Quick start: how to create the secret, write the release, apply it
- Configuration reference table (all `#config` fields)
- Notes on shared volumes with download clients
- Link to `modules/planning/exportarr/design.md` for sidecar docs

## Step 6: Tidy & Validate

Run from `modules/`:

```sh
# Pull in CUE dependencies declared in cue.mod/module.cue
task tidy

# Format all CUE source files
task fmt

# Validate schemas (non-concrete — no debugValues injection)
task vet

# Validate with concrete values (uses debugValues)
task vet CONCRETE=true

# Combined pre-commit gate
task check
```

Expected: all commands exit 0 with no errors. Fix any type mismatches or missing fields before proceeding.

## Step 7: Create Dev Release

Create `releases/kind_opm_dev/sonarr/release.cue`:

```cue
package sonarr

import (
    mr "opmodel.dev/core/v1alpha1/modulerelease@v1"
    m  "opmodel.dev/modules/sonarr@v1"
)

mr.#ModuleRelease

metadata: {
    name:      "sonarr"
    namespace: "sonarr"
}

#module: m

values: {
    image: {
        repository: "lscr.io/linuxserver/sonarr"
        tag:        "latest"
        digest:     ""
    }
    port:        8989
    puid:        3005
    pgid:        3005
    timezone:    "Europe/Stockholm"
    serviceType: "ClusterIP"
    storage: {
        config: {
            mountPath:    "/config"
            type:         "pvc"
            size:         "5Gi"
            storageClass: "local-path"
        }
        tv: {
            mountPath:    "/tv"
            type:         "pvc"
            size:         "100Gi"
            storageClass: "local-path"
        }
        downloads: {
            mountPath:    "/downloads"
            type:         "pvc"
            size:         "50Gi"
            storageClass: "local-path"
        }
    }
    servarrConfig: {
        authMethod:   "External"
        authRequired: "DisabledForLocalAddresses"
        branch:       "main"
        logLevel:     "info"
        instanceName: "Sonarr"
    }
}
```

Run from `releases/`:
```sh
task fmt && task vet
```

## Step 8: Validate Release

Apply the release to the dev cluster and verify:

```sh
# Create namespace and API key secret first
kubectl create namespace sonarr
kubectl create secret generic sonarr-secrets \
  --from-literal=api-key=devtestkey123 \
  --namespace sonarr

# Apply the release via OPM CLI
opm apply -f releases/kind_opm_dev/sonarr/release.cue

# Confirm pod starts
kubectl get pods -n sonarr -w

# Confirm Sonarr web UI is reachable (port-forward if ClusterIP)
kubectl port-forward -n sonarr svc/sonarr 8989:8989
curl -s http://localhost:8989/ping
# Expected: {"status":"OK"}

# Confirm config.xml was seeded correctly
kubectl exec -n sonarr deploy/sonarr -- cat /config/config.xml
```

Check that:
- `<AuthenticationMethod>External</AuthenticationMethod>` is present
- `<InstanceName>Sonarr</InstanceName>` is present
- On pod restart, `config.xml` is NOT overwritten (init container exits immediately)

## Step 9: Publish Module

From `modules/`:

```sh
# Preview what will be published
task publish:dry

# Check version status
task versions

# Publish the sonarr module
task publish:one MODULE=sonarr
```

Confirm the module appears in the OPM registry before tagging.
