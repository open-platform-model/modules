# Radarr OPM Module — Implementation Tasks

> The Radarr module is structurally identical to the Sonarr module. Implement Sonarr first; Radarr is a port of the same pattern with different image, port (7878), and storage field names (movies instead of tv).

## Step 1: Scaffold Module Directory

```sh
mkdir -p modules/radarr/cue.mod
```

Resulting layout:
```
modules/radarr/
  cue.mod/
    module.cue
  module.cue
  components.cue
  README.md
```

## Step 2: Create cue.mod/module.cue

Create `modules/radarr/cue.mod/module.cue`:

```cue
module: "opmodel.dev/modules/radarr@v1"
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

> **Do not hand-edit version pins.** After writing this file, run `task update-deps` from the workspace root to resolve the latest compatible versions.

## Step 3: Write module.cue

Create `modules/radarr/module.cue`. This file is a direct port of `modules/sonarr/module.cue` with these changes:
- Package name: `radarr`
- Module path: `opmodel.dev/modules/radarr@v1`
- Description: `"Radarr - automated movie downloader (Servarr)"`
- `defaultNamespace: "radarr"`
- Image default: `lscr.io/linuxserver/radarr`
- Port default: `7878`
- Storage: `movies` instead of `tv` (mountPath `/movies`)
- `instanceName` default: `"Radarr"`

```cue
// Package radarr defines the Radarr movie downloader module.
// Servarr-based stateful application using the LinuxServer.io image.
// - module.cue:     metadata, shared helpers, #config schema
// - components.cue: workload component definitions
package radarr

import (
    m       "opmodel.dev/core/v1alpha1/module@v1"
    schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)

m.#Module

metadata: {
    modulePath:       "opmodel.dev/modules"
    name:             "radarr"
    version:          "0.1.0"
    description:      "Radarr - automated movie downloader (Servarr)"
    defaultNamespace: "radarr"
}

#storageVolume: {
    mountPath:     string
    type:          "pvc" | "emptyDir" | "nfs"
    size?:         string
    storageClass?: string
    server?:       string
    path?:         string
}

// #servarrConfig — structurally identical to the Sonarr module type.
// Keep both in sync when adding or removing fields.
#servarrConfig: {
    apiKey?:       schemas.#Secret
    authMethod?:   "Forms" | "Basic" | "External" | *"External"
    authRequired?: "Enabled" | "DisabledForLocalAddresses" | *"DisabledForLocalAddresses"
    branch?:       string | *"main"
    logLevel?:     "trace" | "debug" | "info" | "warn" | "error" | *"info"
    urlBase?:      string
    instanceName?: string
}

#exportarrSidecar: {
    image: schemas.#Image & {
        repository: string | *"ghcr.io/onedr0p/exportarr"
        tag:        string | *"v2.3.0"
        digest:     string | *""
    }
    port:                    int | *9707
    apiKey:                  schemas.#Secret
    enableAdditionalMetrics: bool | *false
    enableUnknownQueueItems: bool | *false
    logLevel:                "debug" | "info" | "warn" | "error" | *"info"
    resources?:              schemas.#ResourceRequirementsSchema
}

#config: {
    image: schemas.#Image & {
        repository: string | *"lscr.io/linuxserver/radarr"
        tag:        string | *"latest"
        digest:     string | *""
    }

    port: int & >0 & <=65535 | *7878

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
        movies: #storageVolume & {
            mountPath: *"/movies" | string
        }
        downloads: #storageVolume & {
            mountPath: *"/downloads" | string
        }
    }

    serviceType: "ClusterIP" | "NodePort" | "LoadBalancer" | *"ClusterIP"

    resources?: schemas.#ResourceRequirementsSchema

    servarrConfig?: #servarrConfig & {
        instanceName: string | *"Radarr"
    }

    exportarr?: #exportarrSidecar
}

debugValues: {
    image: {
        repository: "lscr.io/linuxserver/radarr"
        tag:        "latest"
        digest:     ""
    }
    port:        7878
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
        movies: {
            mountPath: "/movies"
            type:      "pvc"
            size:      "500Gi"
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
        instanceName: "Radarr"
    }
}
```

## Step 4: Write components.cue

Create `modules/radarr/components.cue`. Port directly from `modules/sonarr/components.cue` with these substitutions:

| Sonarr                    | Radarr                     |
|---------------------------|----------------------------|
| `package sonarr`          | `package radarr`           |
| `sonarr:` (component key) | `radarr:`                  |
| `metadata: name: "sonarr"`| `metadata: name: "radarr"` |
| `storage.tv`              | `storage.movies`           |
| `mountPath: "/tv"`        | `mountPath: "/movies"`     |
| `targetPort: #config.port` (8989) | `targetPort: #config.port` (7878) |
| `sonarr-config-seed`      | `radarr-config-seed`       |
| `http://localhost:8989`   | `http://localhost:7878`    |
| `name: "sonarr"` (container) | `name: "radarr"`       |

The init container logic, sidecar injection pattern, volume type-switch, and ConfigMap XML template are **byte-for-byte identical** — only the names and port differ.

```cue
// Package radarr defines the Radarr workload component.
// Stateful single-instance deployment with config.xml seeding via init container.
// This file is a direct port of the Sonarr components.cue — storage key is "movies".
package radarr

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
    //// Radarr — Stateful Movie Downloader
    ///////////////////////////////////////////////////////////////

    radarr: {
        resources_workload.#Container
        resources_storage.#Volumes
        resources_config.#ConfigMaps
        traits_workload.#Scaling
        traits_workload.#RestartPolicy
        traits_network.#Expose
        traits_security.#SecurityContext

        metadata: name: "radarr"
        metadata: labels: "core.opmodel.dev/workload-type": "stateful"

        _volumes: spec.volumes

        _allVolumes: {
            config:    #config.storage.config
            movies:    #config.storage.movies
            downloads: #config.storage.downloads
        }

        spec: {
            scaling: count: 1
            restartPolicy: "Always"

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
                        "radarr-config-seed": {
                            name:      "radarr-config-seed"
                            mountPath: "/seed"
                            readOnly:  true
                        }
                    }
                }]
            }

            container: {
                name:  "radarr"
                image: #config.image
                ports: http: {
                    name:       "http"
                    targetPort: #config.port
                }
                env: {
                    PUID: { name: "PUID", value: "\(#config.puid)" }
                    PGID: { name: "PGID", value: "\(#config.pgid)" }
                    TZ:   { name: "TZ",   value: #config.timezone  }
                    if #config.umask != _|_ {
                        UMASK: { name: "UMASK", value: #config.umask }
                    }
                }
                livenessProbe: {
                    httpGet: { path: "/ping", port: #config.port }
                    initialDelaySeconds: 30
                    periodSeconds:       10
                    timeoutSeconds:      5
                    failureThreshold:    3
                }
                readinessProbe: {
                    httpGet: { path: "/ping", port: #config.port }
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
                        (vName): _volumes[vName] & { mountPath: v.mountPath }
                    }
                }
            }

            if #config.exportarr != _|_ {
                sidecarContainers: [{
                    name:  "exportarr"
                    image: #config.exportarr.image
                    env: {
                        PORT:   { name: "PORT",   value: "\(#config.exportarr.port)" }
                        URL:    { name: "URL",    value: "http://localhost:\(#config.port)" }
                        APIKEY: { name: "APIKEY", valueFrom: secretKeyRef: #config.exportarr.apiKey }
                        ENABLE_ADDITIONAL_METRICS:  { name: "ENABLE_ADDITIONAL_METRICS",  value: "\(#config.exportarr.enableAdditionalMetrics)"  }
                        ENABLE_UNKNOWN_QUEUE_ITEMS: { name: "ENABLE_UNKNOWN_QUEUE_ITEMS", value: "\(#config.exportarr.enableUnknownQueueItems)" }
                        LOG_LEVEL: { name: "LOG_LEVEL", value: #config.exportarr.logLevel }
                    }
                    ports: metrics: { name: "metrics", targetPort: #config.exportarr.port }
                    if #config.exportarr.resources != _|_ {
                        resources: #config.exportarr.resources
                    }
                }]
            }

            expose: {
                ports: http: container.ports.http & { exposedPort: #config.port }
                type: #config.serviceType
            }

            if #config.servarrConfig != _|_ {
                _apiKeyValue: string | *""
                if #config.servarrConfig.apiKey != _|_ {
                    _apiKeyValue: #config.servarrConfig.apiKey.$value
                }
                _urlBase: string | *""
                if #config.servarrConfig.urlBase != _|_ {
                    _urlBase: #config.servarrConfig.urlBase
                }

                configMaps: {
                    "radarr-config-seed": {
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

            volumes: {
                for name, v in _allVolumes {
                    (name): {
                        "name": name
                        if v.type == "pvc" {
                            persistentClaim: {
                                size: v.size
                                if v.storageClass != _|_ { storageClass: v.storageClass }
                            }
                        }
                        if v.type == "emptyDir" { emptyDir: {} }
                        if v.type == "nfs" {
                            nfs: { server: v.server, path: v.path }
                        }
                    }
                }

                if #config.servarrConfig != _|_ {
                    "radarr-config-seed": {
                        name:      "radarr-config-seed"
                        configMap: spec.configMaps["radarr-config-seed"]
                    }
                }
            }
        }
    }
}
```

## Step 5: Write README.md

Create `modules/radarr/README.md` covering:
- What Radarr does and why it is packaged here
- Architecture diagram (copy from design.md)
- Quick start: how to create the secret, write the release, apply it
- Configuration reference table (all `#config` fields)
- Notes on shared download volume with other arr apps
- Cross-reference to Sonarr module (same pattern, different content type)
- Link to `modules/planning/exportarr/design.md` for sidecar docs

## Step 6: Tidy & Validate

Run from `modules/`:

```sh
# Pull in CUE dependencies
task tidy

# Format all CUE source files
task fmt

# Validate schema (non-concrete)
task vet

# Validate with concrete debugValues
task vet CONCRETE=true

# Combined pre-commit gate
task check
```

Expected: all commands exit 0 with no errors.

## Step 7: Create Dev Release

Create `releases/kind_opm_dev/radarr/release.cue`:

```cue
package radarr

import (
    mr "opmodel.dev/core/v1alpha1/modulerelease@v1"
    m  "opmodel.dev/modules/radarr@v1"
)

mr.#ModuleRelease

metadata: {
    name:      "radarr"
    namespace: "radarr"
}

#module: m

values: {
    image: {
        repository: "lscr.io/linuxserver/radarr"
        tag:        "latest"
        digest:     ""
    }
    port:        7878
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
        movies: {
            mountPath:    "/movies"
            type:         "pvc"
            size:         "500Gi"
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
        instanceName: "Radarr"
    }
}
```

Run from `releases/`:
```sh
task fmt && task vet
```

## Step 8: Validate Release

```sh
kubectl create namespace radarr
kubectl create secret generic radarr-secrets \
  --from-literal=api-key=devtestkey456 \
  --namespace radarr

opm apply -f releases/kind_opm_dev/radarr/release.cue

kubectl get pods -n radarr -w

kubectl port-forward -n radarr svc/radarr 7878:7878
curl -s http://localhost:7878/ping
# Expected: {"status":"OK"}

kubectl exec -n radarr deploy/radarr -- cat /config/config.xml
```

Check that:
- `<InstanceName>Radarr</InstanceName>` is present
- `<AuthenticationMethod>External</AuthenticationMethod>` is present
- On pod restart, `config.xml` is NOT overwritten by the init container

## Step 9: Publish Module

From `modules/`:

```sh
task publish:dry
task versions
task publish:one MODULE=radarr
```
