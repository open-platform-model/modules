---
status: in-progress
phase: 3
updated: 2026-03-23
---

# Implementation Plan: gateway module

## Goal

Create an OPM module (`modules/gateway/`) that deploys a configurable Kubernetes Gateway API `Gateway` resource on cluster `admin@gon1-nas2`, using the pre-installed Istio as the Gateway API controller.

---

## Cluster State (verified 2026-03-22)

| Aspect | Value |
|---|---|
| Kubernetes | v1.33.0 |
| Istio | v1.28.5-distroless (ambient mode — ztunnel + istio-cni) |
| Gateway API CRDs | All 12 present (standard + experimental), installed 2026-03-15 |
| GatewayClasses | `istio`, `istio-remote`, `istio-waypoint` — all `Accepted: True` |
| MetalLB | Running, L2 mode, pool `10.10.0.180–10.10.0.199` |
| cert-manager | Installed (used for TLS certificate provisioning) |
| Existing Gateways | None — cluster is clean and ready |
| Existing HTTPRoutes | None |

---

## Context & Decisions

| Decision | Rationale | Source |
|---|---|---|
| Use Istio as Gateway API controller | Already installed at v1.28.5; GA Gateway API support since v1.22; three GatewayClasses auto-created and accepted | `kubectl --context admin@gon1-nas2 get gatewayclass` |
| Do NOT install Gateway API CRDs in this module | All 12 CRDs already present on the cluster | `kubectl --context admin@gon1-nas2 get crds \| grep gateway` |
| Do NOT include MetalLB | Already running with pool `10.10.0.180–10.10.0.199`; treat as cluster prerequisite | `kubectl --context admin@gon1-nas2 get ipaddresspool -n metallb-system` |
| Default GatewayClass: `istio` | Pre-created by Istio install; controller `istio.io/gateway-controller`; auto-provisions Deployment + LoadBalancer Service per Gateway | https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/ |
| Target namespace: `istio-ingress` | Standard Istio convention for Gateway API workloads; keeps ingress resources isolated from `istio-system` | User decision |
| TLS via cert-manager | cert-manager is already installed in the cluster; HTTPS listeners reference Secrets provisioned by cert-manager Certificate CRs | User decision |
| Static IP pinning: not required | MetalLB will auto-assign from the pool; no need to pin a specific address | User decision |
| Scope: Infrastructure + configurable Gateway | Module deploys a Gateway with configurable listeners and TLS; HTTPRoutes are created by consuming modules | User decision |
| Istio auto-provisions per-Gateway resources | When a `gateway.networking.k8s.io/v1/Gateway` is created, Istio automatically creates a Deployment (Envoy proxy) and a LoadBalancer Service. No manual deployment definition required. | https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/ |
| Support `parametersRef` ConfigMap | Allows customising the auto-provisioned Deployment/Service (replicas, resource limits, service annotations) without forking the module | https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/ |
| Gateway CR as OPM component: DEFERRED | OPM's component model (Container → Blueprint → Transformer) has no first-class concept for deploying CRD instances. Adding this requires catalog work. Module authoring is blocked until that support exists. | See "Deferred work" below |
| Rename module from `gateway_api` to `gateway` | Shorter, cleaner name; avoids confusion with the catalog extension module `catalog/v1alpha2/gateway_api/`; the catalog extension retains its name | User directive |

---

## Deferred Work (prerequisite)

### OPM catalog: Gateway CR resource support

The existing component model only knows how to produce standard Kubernetes workload resources (Deployments, Services, etc.) and CRD definitions. It has no mechanism to emit a `Gateway` custom resource instance as a component output.

Before this module can be fully implemented, one of the following approaches must be chosen and built in `catalog/`:

| Option | Description | Effort |
|---|---|---|
| A — New `#GatewayResource` resource type | Define a first-class `#GatewayResource` in `catalog/v1alpha2/opm/resources/network/` backed by a transformer that emits a `gateway.networking.k8s.io/v1/Gateway` object | Medium |
| B — Raw manifest passthrough | Allow a component to include an arbitrary raw Kubernetes manifest as output (a general "escape hatch" resource type) | Small, but less OPM-native |
| C — Managed CR instance resource type | General-purpose mechanism for deploying any CRD instance via OPM, not limited to Gateway API | Large, but the cleanest long-term answer |

**Status**: Option A is now being built in `catalog/v1alpha2/`. The `#GatewayResource`, `#GatewayClassResource`, and `#BackendTrafficPolicyResource` definitions are tracked in `catalog/v1alpha2/PLAN.md` Phase 3. This module unblocks once those resources and their transformers are published.

---

## Phase 1: Module Scaffolding [PENDING]

- [ ] **1.1 Rename `modules/gateway_api/` to `modules/gateway/` and update `cue.mod/module.cue`** ← CURRENT
  - Module path: `opmodel.dev/modules/gateway@v0`
  - Language: `v0.16.0` (fix from `v0.15.0`)
  - Dependency: `opmodel.dev/core/v1alpha1@v1` (do not set version pin manually — run `task update-deps` after creating the file)
- [ ] 1.2 Update `modules/gateway/module.cue` with metadata and `#config` schema
  - Fix `certificateRefs` → `certificateRef` (singular, to match `#ListenerSchema`)
  - Add `"UDP"` to protocol enum
  - Fix TLS mode: change from required (`mode!`) to defaulted (`mode: *"Terminate" | "Passthrough"`)
- [ ] 1.3 Define `#config` schema — fields to cover:
  - `gatewayClassName` — `string | *"istio"` — which GatewayClass to use
  - `listeners` — map of named listeners; each has `port`, `protocol` (`HTTP` | `HTTPS` | `TLS` | `TCP` | `UDP`), optional `hostname`, optional `tls` (mode + `certificateRef` name/namespace), and `allowedRoutes` namespace policy (`Same` | `All` | `Selector`)
  - `infrastructure?` — optional parametersRef block for Istio-specific Deployment/Service customisation (replicas, resource limits, service annotations)
- [ ] 1.4 Write `debugValues` exercising the full `#config` surface — follow pattern in `modules/metallb/module.cue`
- [ ] 1.5 Run `task update-deps` from workspace root to pin dependency versions

## Phase 2: Catalog Prerequisite [COMPLETE]

The v1alpha2 catalog work is complete as of 2026-03-23. All Gateway API and cert-manager
transformers are in place in `catalog/v1alpha2/opm/`. Phases 3–5 are now unblocked.

- [x] 2.1 Implement `#GatewayResource` in `catalog/v1alpha2/opm/resources/network/gateway.cue`
  - Schema covers: `gatewayClassName`, `listeners` (name, port, protocol, tls, allowedRoutes), `addresses?`, `infrastructure?`
  - Follows triple pattern: `#GatewayResource` (definition) + `#Gateway` (mixin) + `#GatewayDefaults` (defaults)
- [x] 2.2 Implement `#GatewayTransformer` in `catalog/v1alpha2/opm/providers/kubernetes/transformers/gateway_transformer.cue`
  - Converts OPM `#GatewayResource` to `gateway.networking.k8s.io/v1/Gateway` object
  - Import output type: `output: gwapiV1.#Gateway & { ... }` (schema unification enforces structure)
  - Register in `catalog/v1alpha2/opm/providers/kubernetes/provider.cue`
- [x] 2.3 Add `#GatewayResource` to `catalog/v1alpha2/INDEX.md`
- [x] 2.4 Validate catalog changes: `task vet:v1alpha2` in `catalog/` — all pass (2026-03-23)
- [ ] 2.5 Publish updated catalog version

## Phase 3: Component Definitions [PENDING]

Depends on Phase 1 (rename + schema fixes) and Phase 2 (now complete).

- [ ] 3.1 Create `modules/gateway/components.cue`
  - Define a `gateway` component using `resources_network.#Gateway` (from Phase 2)
  - Wire `#config.gatewayClassName` → `spec.gatewayClassName`
  - Wire `#config.listeners` → `spec.listeners`
  - Wire `#config.infrastructure` → `spec.infrastructure.parametersRef` (conditional on field being set)
- [ ] 3.2 Add optional `parametersRef` ConfigMap component
  - When `#config.infrastructure` is set, emit a ConfigMap with Istio deployment/service customisation JSON
  - Reference it from the Gateway's `spec.infrastructure.parametersRef`
  - Pattern: use `resources_config.#ConfigMaps` with `encoding/json.Marshal` — see `modules/zot_registry_ttl/components.cue`
- [ ] 3.3 Validate: `cue vet -c ./modules/gateway/...`
- [ ] 3.4 Add optional `#GatewayClassResource` component
  - When `#config.gatewayClass` is set to a non-default value, emit a `GatewayClass` CR defining the controller and parameters
  - Uses `resources_network.#GatewayClass` (from Phase 2); only emitted when `gatewayClassName` is not one of the pre-installed Istio classes
- [ ] 3.5 Add optional `#BackendTrafficPolicyResource` component
  - When `#config.backendTrafficPolicy` is set, emit a `BackendTrafficPolicy` CR targeting the Gateway's backend Service
  - Uses `resources_network.#BackendTrafficPolicy` (from Phase 2); wires `sessionPersistence` and `retry` fields from config

## Phase 4: Documentation [PENDING]

- [ ] 4.1 Create `modules/gateway/README.md` — follow `modules/metallb/README.md` as style reference
  - Overview: what the module deploys and why
  - Prerequisites section (Istio, Gateway API CRDs, MetalLB, cert-manager)
  - Architecture diagram showing module → Gateway CR → Istio auto-provisions → Deployment + LoadBalancer Service → MetalLB IP
  - Configuration table documenting every `#config` field with type, default, and description
  - Minimal release example (HTTP-only)
  - HTTPS release example (with cert-manager `certificateRef`)
  - Post-deployment section: how consuming modules attach HTTPRoutes to this Gateway
- [ ] 4.2 Run `task update-deps` to ensure deps are current before publishing

## Phase 5: Release Configuration [PENDING]

- [ ] 5.1 Create `releases/gon1_nas2/gateway/` — see `releases/AGENTS.md` for layout
  - Bind to concrete values for `admin@gon1-nas2`
  - `gatewayClassName: "istio"`
  - HTTP listener on port 80, `allowedRoutes: namespaces: from: "Same"`
  - HTTPS listener on port 443, TLS terminate, `certificateRef` pointing to a cert-manager-managed Secret
- [ ] 5.2 Add initial entry to `modules/versions.yml`: `gateway: version: v0.0.1`
- [ ] 5.3 Dry-run publish: `task publish:one MODULE=gateway DRY_RUN=true`
- [ ] 5.4 Publish: `task publish:one MODULE=gateway`

---

## Notes

- 2026-03-22: Cluster runs Istio in **ambient mode** (ztunnel + istio-cni). Gateway namespaces do not need `istio-injection=enabled` — ambient mode handles L4 transparently via ztunnel. Verify that Istio's gateway deployment controller provisions correctly in ambient mode when Phase 3 begins.
- 2026-03-22: Istio's Gateway deployment controller is enabled by default in v1.22+ via `PILOT_ENABLE_GATEWAY_API_DEPLOYMENT_CONTROLLER=true`. No mesh config changes required on this cluster.
- 2026-03-22: Authelia is configured as an auth extension in the Istio mesh config. Gateways provisioned through this module will inherit mesh-level auth policies automatically.
- 2026-03-22: All 8 Gateway API transformers are now being built in `catalog/v1alpha2/`: `#GatewayTransformer`, `#GatewayClassTransformer`, `#HttpRouteTransformer`, `#GrpcRouteTransformer`, `#TcpRouteTransformer`, `#TlsRouteTransformer`, `#ReferenceGrantTransformer`, and `#BackendTrafficPolicyTransformer`. Once published, `#IngressTransformer` will be removed — Gateway API is the native routing mechanism on this cluster.
- 2026-03-23: Module renamed from `gateway_api` to `gateway` per user directive. All file paths, module paths, and release paths updated throughout this plan. The catalog extension module remains `catalog/v1alpha2/gateway_api/` — only the OPM module in `modules/` is renamed.

---

## Links

- [Kubernetes Gateway API spec](https://gateway-api.sigs.k8s.io/)
- [Istio Gateway API task](https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/)
- [Istio ambient mode](https://istio.io/latest/docs/ambient/)
- [cert-manager Gateway API integration](https://cert-manager.io/docs/usage/gateway/)
- [MetalLB + Istio Gateway API (bare-metal)](https://metallb.io/)
