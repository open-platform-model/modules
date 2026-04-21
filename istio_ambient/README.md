# istio-ambient

OPM module that deploys the Istio service mesh control plane in **ambient mode** — no sidecars, per-node ztunnel data plane, and L7 waypoint proxies on demand.

## Scope

Deploys:
- All 14 Istio CRDs (`networking.istio.io`, `security.istio.io`, `telemetry.istio.io`, `extensions.istio.io`)
- `istiod` (Pilot) Deployment, Service, ConfigMap, RBAC
- `istio-cni` DaemonSet, ConfigMap, RBAC
- `ztunnel` DaemonSet, RBAC
- `ValidatingWebhookConfiguration` (mesh config validation)
- `MutatingWebhookConfiguration` (sidecar injector — still installed so sidecar-mode workloads can coexist)

Optionally deploys:
- Gateway API v1 standard CRDs (`gateway.networking.k8s.io` — BackendTLSPolicy, Gateway, GatewayClass, GRPCRoute, HTTPRoute, ReferenceGrant), toggled by `#config.gatewayAPI.enabled` (default `false`).

Does **not** deploy:
- `Namespace` (release author's responsibility)
- Ingress `Gateway` resources (use `modules/gateway/` for the Gateway API instance)
- Canary revisions (`revision` field exists but is reserved for a future version)

## Ambient-mode hard locks

The module enforces the following settings that cannot be overridden via `#config` — they define *ambient* mode and changing them would break the install:

| Setting | Value | Source |
|---|---|---|
| `pilot.env.PILOT_ENABLE_AMBIENT` | `"true"` | istiod Deployment env |
| `meshConfig.defaultConfig.proxyMetadata.ISTIO_META_ENABLE_HBONE` | `"true"` | mesh ConfigMap |
| `pilot.env.CA_TRUSTED_NODE_ACCOUNTS` | `<ns>/<ztunnel-name>` | istiod Deployment env |
| `global.variant` | `distroless` | image tag suffix |
| `cni.ambient.enabled` | `true` | CNI DaemonSet |

These come from `research/charts/base/files/profile-ambient.yaml` and the ambient umbrella chart.

## Quick start

```cue
import (
    istio "opmodel.dev/modules/istio_ambient@v0"
)

moduleRelease: istio & {
    #config: {
        version: "1.28.3"
        clusterName: "my-cluster"
        meshID:      "my-mesh"
        trustDomain: "cluster.local"

        // Install Gateway API CRDs alongside Istio's.
        gatewayAPI: enabled: true

        istiod: {
            replicas: 1
            resources: {
                requests: {cpu: "100m", memory: "256Mi"}
                limits:   {cpu: "500m", memory: "512Mi"}
            }
        }
    }
}
```

Then compose with `modules/gateway/` to get a GatewayClass `istio`-backed ingress.

## Configuration reference

See [module.cue](module.cue) — the `#config` schema is fully commented. Key sections:

- **Top-level:** `version`, `hub`, `clusterName`, `network`, `meshID`, `trustDomain`, `gatewayAPI.enabled`, `imagePullSecrets`.
- **`base`**: CRD filtering, validation webhook URL, istio config CRD toggle.
- **`istiod`**: image, replicas, autoscale, PDB, resources, node scheduling, logging, traceSampling, untaint controller, ztunnel wiring, sidecar injection policy, meshConfig, proxy defaults, waypoint resources.
- **`cni`**: image, logging, CNI paths, chained/provider, excluded namespaces, ambient toggles, repair controller, resources, scheduling.
- **`ztunnel`**: image, resourceName, logging, resources, scheduling, terminationGracePeriod, CA/XDS overrides.

## Regenerating CRD data

CRD data is committed at `crds_data.cue` (Istio) and `crds_gateway_api_data.cue` (Gateway API), imported from the catalog and upstream:

```bash
# Istio CRDs — use the catalog's committed copy
cue import -p istio_ambient -f \
    -l '"#crds"' -l 'metadata.name' \
    ../../catalog/istio/v1alpha1/crds/istio-all-crds.yaml \
    -o crds_data.cue
sed -i 's/^"#crds": /#crds: /' crds_data.cue

# Gateway API standard CRDs — sourced from research/crds.yaml
cue import -p istio_ambient -f \
    -l '"#crdsGatewayAPI"' -l 'metadata.name' \
    research/crds.yaml \
    -o crds_gateway_api_data.cue
sed -i 's/^"#crdsGatewayAPI": /#crdsGatewayAPI: /' crds_gateway_api_data.cue

cd ../../modules && task vet
```

## Verification

```bash
cd modules
task fmt
task vet
task vet CONCRETE=true
task publish:one MODULE=istio_ambient

# Cluster validation
kubectl -n istio-system get pods
istioctl proxy-status
istioctl analyze

# Enroll a namespace in ambient
kubectl label namespace default istio.io/dataplane-mode=ambient
kubectl -n default run demo --image=nginx
```

## Authoring Istio CRs in app modules

Use the catalog module `opmodel.dev/istio/v1alpha1` to author `AuthorizationPolicy`, `Telemetry`, `VirtualService`, etc. — that module provides OPM `#Resource`/`#Component` wrappers + a passthrough Kubernetes provider.

## Links

- [Istio Ambient docs](https://istio.io/latest/docs/ambient/)
- [Istio releases](https://github.com/istio/istio/releases)
- [Upstream Helm charts](https://github.com/istio/istio/tree/1.28.3/manifests/charts)
