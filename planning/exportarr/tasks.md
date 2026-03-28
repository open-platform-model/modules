# Exportarr Sidecar — Implementation Tasks

Exportarr has no standalone OPM module. These tasks describe:
1. Defining the canonical `#exportarrSidecar` CUE definition
2. Integrating it into each arr module that should support it

The integration procedure is the same for every arr module. These tasks use Sonarr as the worked example; repeat the same steps for Radarr (and future modules: Prowlarr, Bazarr).

---

## Step 1: Scaffold Module Directory

No directory is created for Exportarr itself. Verify the arr modules exist:

```bash
ls modules/sonarr/
ls modules/radarr/
```

If either directory is missing, complete the Sonarr and Radarr implementation tasks first before proceeding.

---

## Step 2: Create cue.mod/module.cue

No `cue.mod/module.cue` is created for Exportarr. The `#exportarrSidecar` definition lives inside each arr module's own `module.cue`. There is no shared CUE module to publish.

**Why no shared module?** CUE module boundaries prevent importing definitions from one module into another without publishing an intermediate package and adding it as a versioned dependency. For a small, stable struct like `#exportarrSidecar`, the cost of that indirection exceeds the maintenance overhead of copying the definition. Each arr module carries its own copy.

---

## Step 3: Write the #exportarrSidecar Definition

For each arr module, open its `module.cue` and add the following definition. It must appear before `#config` because `#config` references it.

### Canonical Definition (copy into each arr module.cue)

```cue
// #exportarrSidecar configures the optional Exportarr Prometheus metrics sidecar.
// When set in #config.exportarr, a second container is added to the pod at render time.
// Exportarr scrapes the arr app's HTTP API via localhost and exposes metrics on /metrics.
#exportarrSidecar: {
	// Exportarr container image.
	image: schemas.#Image & {
		repository: string | *"ghcr.io/onedr0p/exportarr"
		tag:        string | *"v2.3.0"
		digest:     string | *""
	}

	// Port on which Exportarr exposes the Prometheus /metrics endpoint inside the pod.
	port: int | *9707

	// Required: API key for authenticating against the arr app's HTTP API.
	// Must reference an existing Kubernetes Secret.
	apiKey: schemas.#Secret & {
		$secretName: string
		$dataKey:    string
	}

	// Expose extended app-specific metrics (series health, episode/movie counts, etc.).
	enableAdditionalMetrics: bool | *false

	// Include items stuck in an unknown queue state in queue depth metrics.
	enableUnknownQueueItems: bool | *false

	// Exportarr log verbosity.
	logLevel: "debug" | "info" | "warn" | "error" | *"info"

	// Optional resource constraints for the sidecar container.
	resources?: schemas.#ResourceRequirementsSchema
}
```

### Add optional field to #config

In the same `module.cue`, add to `#config`:

```cue
#config: {
	// ... existing fields ...

	// Optional Exportarr metrics sidecar.
	// When set, a second container is injected into the pod alongside the main app.
	exportarr?: #exportarrSidecar
}
```

### Add to debugValues

In `debugValues`, add a concrete `exportarr` block so `cue vet -c` exercises the sidecar rendering path:

**For Sonarr:**
```cue
debugValues: {
	// ... existing fields ...
	exportarr: {
		image: {
			repository: "ghcr.io/onedr0p/exportarr"
			tag:        "v2.3.0"
			digest:     ""
		}
		port: 9707
		apiKey: {
			$secretName: "sonarr-secrets"
			$dataKey:    "api-key"
		}
		enableAdditionalMetrics: false
		enableUnknownQueueItems: false
		logLevel: "info"
	}
}
```

**For Radarr:** Same structure but `$secretName: "radarr-secrets"`.

---

## Step 4: Write components.cue Integration

For each arr module, open its `components.cue` and add the sidecar rendering block. The sidecar is added inside the main component's `spec:` block, after the primary `container:` definition.

### Sonarr integration (`modules/sonarr/components.cue`)

Inside `sonarr: { spec: { ... } }`, after the `container:` block:

```cue
// Exportarr sidecar — only rendered when #config.exportarr is set.
// Scrapes the Sonarr API at http://localhost:<port> and exposes Prometheus metrics.
if #config.exportarr != _|_ {
	sidecarContainers: [{
		name:    "exportarr"
		image:   #config.exportarr.image
		// Subcommand selects which arr app to scrape
		command: ["exportarr", "sonarr"]

		ports: metrics: {
			name:       "metrics"
			targetPort: #config.exportarr.port
		}

		env: {
			PORT: {
				name:  "PORT"
				value: "\(#config.exportarr.port)"
			}
			// URL uses localhost — both containers share the pod's network namespace
			URL: {
				name:  "URL"
				value: "http://localhost:\(#config.port)"
			}
			// APIKEY injected from Kubernetes Secret — never hardcoded
			APIKEY: {
				name: "APIKEY"
				valueFrom: secretKeyRef: {
					name: #config.exportarr.apiKey.$secretName
					key:  #config.exportarr.apiKey.$dataKey
				}
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

		if #config.exportarr.resources != _|_ {
			resources: #config.exportarr.resources
		}
	}]
}
```

Also update `expose:` to include the metrics port when the sidecar is enabled:

```cue
expose: {
	ports: {
		http: container.ports.http & {
			exposedPort: #config.port
		}
		// Metrics port exposed on Service when Exportarr is enabled
		if #config.exportarr != _|_ {
			metrics: {
				name:        "metrics"
				targetPort:  #config.exportarr.port
				exposedPort: #config.exportarr.port
			}
		}
	}
	type: #config.serviceType
}
```

### Radarr integration (`modules/radarr/components.cue`)

Identical to Sonarr except:
- `command: ["exportarr", "radarr"]` (not `"sonarr"`)
- Secret name in `debugValues` is `"radarr-secrets"`

All other code is copy-paste identical.

### Future modules (Prowlarr, Bazarr)

When implementing Prowlarr and Bazarr modules:
- Copy `#exportarrSidecar` definition into their `module.cue` verbatim
- Change the `command:` subcommand: `["exportarr", "prowlarr"]` / `["exportarr", "bazarr"]`
- Update `$secretName` in `debugValues` to match the module's secret naming convention

---

## Step 5: Write README.md

For each arr module's `README.md`, add an **Exportarr** section:

```markdown
## Exportarr (Prometheus Metrics)

Enable the Exportarr sidecar by adding `exportarr:` to your release values:

\```cue
values: {
    // ... other values ...
    exportarr: {
        image: {
            repository: "ghcr.io/onedr0p/exportarr"
            tag:        "v2.3.0"
            digest:     ""
        }
        port:   9707
        apiKey: {
            $secretName: "sonarr-secrets"
            $dataKey:    "api-key"
        }
        enableAdditionalMetrics: false
        enableUnknownQueueItems: false
        logLevel: "info"
    }
}
\```

Exportarr exposes Prometheus metrics at `http://<pod-ip>:9707/metrics`.
The API key must be stored in a Kubernetes Secret before deploying with Exportarr enabled.
```

---

## Step 6: Tidy & Validate

Run from `modules/` after editing each arr module:

```bash
# Format
task fmt

# Validate schema (non-concrete — verifies types, constraints, and optionality)
task vet

# Validate with concrete debugValues — exercises the sidecar rendering path
task vet CONCRETE=true

# Combined
task check
```

**Validation checklist for the sidecar integration:**

- [ ] `cue vet` passes without errors on all modified modules
- [ ] `cue vet -c` passes using `debugValues` that include an `exportarr:` block
- [ ] `cue vet -c` also passes using `debugValues` WITHOUT `exportarr:` (sidecar is optional — must not break the module when absent)
- [ ] `task fmt` reports no formatting changes after running (code is already canonical)

To test the "no sidecar" path with concrete validation, temporarily comment out the `exportarr:` block in `debugValues` and re-run `task vet CONCRETE=true`. Both paths must pass.

---

## Step 7: Create Dev Release

Create a dev release that exercises the Exportarr sidecar. Prerequisite: the arr module must already have a base dev release (see Sonarr/Radarr tasks.md Step 7).

Edit `releases/kind_opm_dev/sonarr/release.cue` to add the `exportarr:` block:

```cue
values: {
	// ... existing values ...

	exportarr: {
		image: {
			repository: "ghcr.io/onedr0p/exportarr"
			tag:        "v2.3.0"
			digest:     ""
		}
		port: 9707
		apiKey: {
			$secretName: "sonarr-secrets"
			$dataKey:    "api-key"
		}
		enableAdditionalMetrics: false
		enableUnknownQueueItems: false
		logLevel: "info"
	}
}
```

**Pre-requisite:** The `sonarr-secrets` Kubernetes Secret with key `api-key` must exist in the `sonarr` namespace before deploying. Create it manually in the dev cluster:

```bash
kubectl create secret generic sonarr-secrets \
  --from-literal=api-key=<api-key-value> \
  --namespace sonarr
```

Retrieve the API key from a running Sonarr instance at **Settings → General → API Key**.

---

## Step 8: Validate Release

Run from `releases/`:

```bash
task fmt
task vet
task check
```

Both the base release (without `exportarr:`) and the sidecar release (with `exportarr:`) must validate cleanly. If the module has not been republished after adding `#exportarrSidecar`, run Step 9 first.

---

## Step 9: Publish Module

After adding `#exportarrSidecar` to an arr module, bump its patch version in `module.cue` and republish:

**In `modules/sonarr/module.cue`:**

```cue
metadata: {
	// ...
	version: "0.1.1"  // bump from 0.1.0
}
```

Then from `modules/`:

```bash
task publish:one MODULE=sonarr
task versions
```

Repeat for each arr module that was updated (e.g. `MODULE=radarr`).

After publishing, update the release's module import if the OPM tooling pins the version, then re-validate releases:

```bash
# from releases/
task fmt
task vet
task check
```
