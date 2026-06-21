# northbyte_web

OPM module for the public NorthByte website (`northbyte.gg`): a single stateless
nginx container serving a baked-in static Hugo site, exposed via the Gateway API.

The site content and container image are built and published from the separate
`northbyte.gg` repo. This module only describes how that image is deployed.

## Architecture

```
web (StatelessWorkload)
  ├─ container: nginx serving /usr/share/nginx/html  (port 80)
  ├─ Expose    → Service
  └─ HttpRoute → binds public hostname(s) at gateway-gateway/istio-ingress  (optional)
```

System A module (`opm/v1alpha1` + `core/v1alpha1`, cue v0.16 — the deployed-fleet
line). Patterned on `seerr_v016` / `zot_registry_ttl`: stateless container + Expose +
optional HttpRoute, with a readiness/liveness probe on `/`. See `DEPLOYMENT_NOTES.md`
for the toolchain (use cue v0.16, not the v0.17-alpha `go` build).

## Configuration (`#config`)

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `image` | `res.#Image` | `ghcr.io/CHANGEME/northbyte-web:dev` | The nginx+site image |
| `replicas` | `int >=1` | `1` | |
| `port` | `int` | `80` | nginx listen port |
| `serviceType` | enum | `ClusterIP` | |
| `httpRoute?` | `{hostnames, gatewayRef?}` | — | Public ingress; omit for no route |
| `resources?` | `res.#ResourceRequirementsSchema` | — | |

## Quick start

A release supplies `values` matching `#config`. See
`opm-releases/nas2/northbyte/release.cue` for the production release.

## Build / publish

From `modules/`: `task check` then `task publish` (or `task publish:one
MODULE=northbyte_web`). See `DEPLOYMENT_NOTES.md` for the CUE-version caveat.
