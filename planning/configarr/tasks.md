# Configarr Module — Implementation Tasks

Nine sequential steps from an empty directory to a published, validated OPM module.

---

## Step 1 — Scaffold the module directory

```
modules/configarr/
├── cue.mod/
│   └── module.cue
├── module.cue
├── components.cue
└── README.md
```

```bash
mkdir -p modules/configarr/cue.mod
touch modules/configarr/module.cue
touch modules/configarr/components.cue
touch modules/configarr/README.md
```

Configarr is a **Job workload** — it runs to completion on each invocation and exits. There is no persistent storage, no Service, and no init container. The `config.yml` is fully declarative and always rendered fresh from the ConfigMap on every run.

---

## Step 2 — Write `cue.mod/module.cue`

```cue
module: "opmodel.dev/modules/configarr@v1"
language: version: "v0.11.0"
deps: {
    "opmodel.dev/core/v1alpha1@v1": { v: "v1.3.1" }
    "opmodel.dev/opm/v1alpha1@v1":  { v: "v1.5.3" }
}
```

Pin the same versions used by all other modules in this repository. Run `task tidy` after writing this file to populate `cue.mod/gen/` and `cue.mod/pkg/`.

---

## Step 3 — Write `module.cue`

```cue
package configarr

import (
    "opmodel.dev/opm/v1alpha1@v1/schemas"
    m "opmodel.dev/core/v1alpha1@v1/module"
)

// #sonarrInstance describes one Sonarr connection entry in config.yml.
#sonarrInstance: {
    // Kubernetes secret name that holds the API key for this instance.
    apiKeySecret: string
    // Secret key within that secret that contains the API key value.
    apiKeySecretKey: string | *"apiKey"
    // Base URL of the Sonarr instance, e.g. "http://sonarr:8989".
    baseUrl: string
    // Quality profile name to apply, e.g. "HD-1080p".
    qualityProfile?: string
    // Language profile name (Sonarr v3 only).
    languageProfile?: string
    // Metadata profile name.
    metadataProfile?: string
    // Root folder path override.
    rootFolder?: string
}

// #radarrInstance describes one Radarr connection entry in config.yml.
#radarrInstance: {
    apiKeySecret: string
    apiKeySecretKey: string | *"apiKey"
    baseUrl: string
    qualityProfile?: string
    rootFolder?: string
}

// #config is the operator-facing configuration surface for Configarr.
#config: {
    image: schemas.#Image & {
        repository: *"ghcr.io/raydak-labs/configarr" | string
        tag:        *"latest" | string
        pullPolicy: *"IfNotPresent" | string
    }

    // sonarr is a map of named Sonarr instances to configure.
    sonarr?: [string]: #sonarrInstance

    // radarr is a map of named Radarr instances to configure.
    radarr?: [string]: #radarrInstance

    // customFormatPath is an optional path inside the container where
    // custom-format YAML files will be mounted.
    customFormatPath?: string | *"/app/custom-formats"

    // templatePath is an optional path inside the container where
    // quality-profile template YAML files will be mounted.
    templatePath?: string | *"/app/templates"

    // jobConfig controls Job-level retry and timeout behaviour.
    jobConfig: {
        // backoffLimit is the number of retries before the Job is marked failed.
        backoffLimit: *3 | int & >=0
        // activeDeadlineSeconds caps total Job runtime (0 = unlimited).
        activeDeadlineSeconds: *600 | int & >=0
    }

    resources: schemas.#ResourceRequirementsSchema
}

m & {
    metadata: {
        name:        "configarr"
        description: "Runs Configarr as a Kubernetes Job to synchronise quality profiles, custom formats, and naming conventions across Sonarr/Radarr instances."
        version:     "0.0.1"
    }
    #config: #config

    debugValues: {
        image: {
            repository: "ghcr.io/raydak-labs/configarr"
            tag:        "latest"
            pullPolicy: "IfNotPresent"
        }
        sonarr: {
            "main": {
                apiKeySecret:    "sonarr-secret"
                apiKeySecretKey: "apiKey"
                baseUrl:         "http://sonarr:8989"
                qualityProfile:  "HD-1080p"
            }
        }
        radarr: {
            "main": {
                apiKeySecret:    "radarr-secret"
                apiKeySecretKey: "apiKey"
                baseUrl:         "http://radarr:7878"
                qualityProfile:  "HD-1080p"
            }
        }
        jobConfig: {
            backoffLimit:          3
            activeDeadlineSeconds: 600
        }
        resources: {
            requests: { cpu: "50m",  memory: "128Mi" }
            limits:   { cpu: "500m", memory: "256Mi" }
        }
    }
}
```

Key design points:
- `sonarr` and `radarr` are optional maps so a release can omit either.
- API keys are **never** inlined in `#config`. Each instance carries only secret-reference fields (`apiKeySecret`, `apiKeySecretKey`). The actual `apiKey` value written into `config.yml` is projected through a `secretKeyRef` environment variable; see Step 5 for the env-var injection pattern.
- `jobConfig` provides safe defaults (`backoffLimit: 3`, 10-minute deadline).

---

## Step 4 — Understand the `config.yml` rendering strategy

Configarr reads a single `config.yml` at start-up. Unlike SABnzbd/Seerr, there is no pre-existing user file to preserve — Configarr is stateless and the file is regenerated from the ConfigMap on every Job run.

### API-key injection strategy

`secretKeyRef` cannot be resolved at CUE build time, so API keys cannot be embedded directly in the YAML text of `config.yml`. The recommended pattern is:

1. Expose each API key as an environment variable in the container via `env[].valueFrom.secretKeyRef`.
2. In the rendered `config.yml`, reference those env-var names using Configarr's `$(ENV_VAR)` substitution syntax (if supported), **or** use separate per-instance secret volume mounts and reference file paths.

For the initial implementation, use **env-var substitution** placeholders in `config.yml`:

```yaml
sonarr:
  main:
    apiKey: "$(SONARR_MAIN_API_KEY)"
    baseUrl: "http://sonarr:8989"
```

The env var `SONARR_MAIN_API_KEY` is injected by the container spec from the named secret.

The CUE code builds a hidden struct `_configYaml` whose fields mirror the YAML structure, then calls `yaml.Marshal(_configYaml)` to produce the ConfigMap data string.

---

## Step 5 — Write `components.cue`

```cue
package configarr

import (
    "strings"
    "encoding/yaml"

    "opmodel.dev/opm/v1alpha1@v1/blueprints/workload" blueprints_workload
    "opmodel.dev/opm/v1alpha1@v1/traits/workload"     traits_workload
    "opmodel.dev/opm/v1alpha1@v1/resources/config"    resources_config
)

// _envVarName converts "instanceName" → "SONARR_INSTANCENAME_API_KEY" style.
// CUE string builtins are used for the transform.
// Pattern: <ARRTYPE>_<UPPER_NAME>_API_KEY
_sonarrEnvName: {[name=string]: "SONARR_\(strings.ToUpper(name))_API_KEY"}
_radarrEnvName: {[name=string]: "RADARR_\(strings.ToUpper(name))_API_KEY"}

// _configYaml assembles the config.yml data structure before marshalling.
_configYaml: {
    if #config.sonarr != _|_ {
        sonarr: {
            for name, inst in #config.sonarr {
                "\(name)": {
                    apiKey:  "$(\(_sonarrEnvName[name]))"
                    baseUrl: inst.baseUrl
                    if inst.qualityProfile != _|_  { qualityProfile:  inst.qualityProfile }
                    if inst.languageProfile != _|_ { languageProfile: inst.languageProfile }
                    if inst.metadataProfile != _|_ { metadataProfile: inst.metadataProfile }
                    if inst.rootFolder != _|_      { rootFolder:      inst.rootFolder }
                }
            }
        }
    }
    if #config.radarr != _|_ {
        radarr: {
            for name, inst in #config.radarr {
                "\(name)": {
                    apiKey:  "$(\(_radarrEnvName[name]))"
                    baseUrl: inst.baseUrl
                    if inst.qualityProfile != _|_ { qualityProfile: inst.qualityProfile }
                    if inst.rootFolder != _|_     { rootFolder:     inst.rootFolder }
                }
            }
        }
    }
    customFormatPath: #config.customFormatPath
    templatePath:     #config.templatePath
}

// _sonarrEnvVars builds env entries for every Sonarr instance API key.
_sonarrEnvVars: [
    for name, inst in #config.sonarr {
        name: _sonarrEnvName[name]
        valueFrom: secretKeyRef: {
            name: inst.apiKeySecret
            key:  inst.apiKeySecretKey
        }
    }
]

// _radarrEnvVars builds env entries for every Radarr instance API key.
_radarrEnvVars: [
    for name, inst in #config.radarr {
        name: _radarrEnvName[name]
        valueFrom: secretKeyRef: {
            name: inst.apiKeySecret
            key:  inst.apiKeySecretKey
        }
    }
]

components: {
    // ConfigMap holds the fully-rendered config.yml.
    configMap: resources_config.#ConfigMaps & {
        spec: configs: "configarr-config": {
            data: "config.yml": yaml.Marshal(_configYaml)
        }
    }

    // job is the Task (Job) workload that runs Configarr to completion.
    job: blueprints_workload.#TaskWorkload & {
        spec: {
            // Job control parameters.
            backoffLimit:          #config.jobConfig.backoffLimit
            activeDeadlineSeconds: #config.jobConfig.activeDeadlineSeconds

            template: spec: {
                // Mount the ConfigMap into the container.
                volumes: [{
                    name: "configarr-config"
                    configMap: name: "configarr-config"
                }]

                containers: [{
                    name:            "configarr"
                    image:           "\(#config.image.repository):\(#config.image.tag)"
                    imagePullPolicy: #config.image.pullPolicy

                    // Inject API keys from Kubernetes Secrets as env vars.
                    env: _sonarrEnvVars + _radarrEnvVars

                    volumeMounts: [{
                        name:      "configarr-config"
                        mountPath: "/app/config.yml"
                        subPath:   "config.yml"
                        readOnly:  true
                    }]

                    resources: #config.resources
                }]

                restartPolicy: "OnFailure"
            }
        }

        traits: {
            scaling: traits_workload.#Scaling & {
                spec: replicas: 1
            }
        }
    }
}
```

Key implementation notes:
- `blueprints_workload.#TaskWorkload` is used instead of `resources_workload.#Container` because Configarr is a Job, not a long-running workload.
- `_configYaml` is a hidden struct; `yaml.Marshal(_configYaml)` converts it to the ConfigMap string.
- `_sonarrEnvVars` and `_radarrEnvVars` are list comprehensions that produce `env[]` entries with `secretKeyRef`.
- `restartPolicy: "OnFailure"` is required for Job pods (not `Always`).
- No `#storageVolume` entries and no `resources_storage.#Volumes` trait — Configarr has no persistent state.
- No `traits_network.#Expose` — there is no HTTP port to expose.

---

## Step 6 — Write `README.md`

Cover:

1. **What Configarr does** — syncs quality profiles, custom formats, and naming schemas across Sonarr/Radarr by running as a Kubernetes Job.
2. **Job execution model** — runs once per trigger (CronJob, GitOps push, manual `kubectl create job`), exits 0 on success.
3. **Required secrets** — one secret per arr instance containing the API key. Example:
   ```bash
   kubectl create secret generic sonarr-secret --from-literal=apiKey=<key>
   ```
4. **Config surface** — table of `#config` fields: `image`, `sonarr`, `radarr`, `customFormatPath`, `templatePath`, `jobConfig`, `resources`.
5. **Instance map schema** — fields for `#sonarrInstance` and `#radarrInstance`.
6. **API-key injection** — explain that keys are never in ConfigMap; they arrive via `secretKeyRef` env vars and are referenced in `config.yml` as `$(ENV_VAR)`.
7. **Minimal release example** referencing the dev-release file.
8. **Triggering a run** — `kubectl create job configarr-manual --from=cronjob/configarr` or direct Job apply.

---

## Step 7 — Tidy and validate

```bash
# From repository root
task tidy          # resolves deps, regenerates cue.mod/gen and cue.mod/pkg

cd modules/configarr
task fmt           # formats all .cue files in place
task vet           # type-checks the CUE module
task check         # runs the full OPM schema validation suite
```

Common issues to watch for:

| Symptom | Likely cause |
|---|---|
| `undefined field: sonarr` in `_configYaml` | Missing `if #config.sonarr != _|_` guard |
| `cannot range over _|_` | Iterating over an optional map without a nil-guard |
| `conflicting values` in env list | Duplicate instance names between sonarr/radarr maps |
| `restartPolicy` validation error | Using `"Always"` instead of `"OnFailure"` for a Job pod |
| `yaml.Marshal` produces empty string | `_configYaml` struct is `_|_` — check guards and field names |

---

## Step 8 — Scaffold the dev release

Create `releases/kind_opm_dev/configarr/release.cue`:

```cue
package configarr

import (
    m  "opmodel.dev/modules/configarr@v1"
    mr "opmodel.dev/core/v1alpha1@v1/modulerelease"
)

mr.#ModuleRelease & {
    #module: m

    values: m.#config & {
        image: {
            repository: "ghcr.io/raydak-labs/configarr"
            tag:        "1.4.0"
            pullPolicy: "IfNotPresent"
        }

        sonarr: {
            "main": {
                apiKeySecret:    "sonarr-secret"
                apiKeySecretKey: "apiKey"
                baseUrl:         "http://sonarr.media.svc.cluster.local:8989"
                qualityProfile:  "HD-1080p"
            }
        }

        radarr: {
            "main": {
                apiKeySecret:    "radarr-secret"
                apiKeySecretKey: "apiKey"
                baseUrl:         "http://radarr.media.svc.cluster.local:7878"
                qualityProfile:  "HD-1080p"
            }
        }

        jobConfig: {
            backoffLimit:          3
            activeDeadlineSeconds: 600
        }

        resources: {
            requests: { cpu: "50m",  memory: "128Mi" }
            limits:   { cpu: "500m", memory: "256Mi" }
        }
    }
}
```

Directory creation:

```bash
mkdir -p releases/kind_opm_dev/configarr
# then write the file above
```

---

## Step 9 — Validate the release and publish

### Validate the release renders correctly

```bash
# Render the release to inspect generated Kubernetes manifests
task render RELEASE=kind_opm_dev/configarr

# Expected outputs:
# - ConfigMap "configarr-config" with config.yml containing sonarr/radarr blocks
# - Job manifest with:
#     backoffLimit, activeDeadlineSeconds
#     env[] entries for SONARR_MAIN_API_KEY / RADARR_MAIN_API_KEY with secretKeyRef
#     volumeMount of config.yml at /app/config.yml (subPath, readOnly)
#     restartPolicy: OnFailure
# - No PVC, no Service, no StatefulSet
```

Verify the rendered `config.yml` contains `$(SONARR_MAIN_API_KEY)` (not a literal key value) and that the env section references the correct secret names.

### Publish

```bash
# From repository root
task publish:one MODULE=configarr
```

This pushes the module to the OPM registry at `opmodel.dev`. Confirm the version in `module.cue` metadata (`"0.0.1"`) is bumped appropriately before publishing to a production registry.
