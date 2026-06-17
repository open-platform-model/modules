# Catalog Migration — Gap Analysis

> Status: analysis complete (2026-06-16). Reference for porting the remaining
> modules onto the new OPM catalog (`opmodel.dev/catalogs/opm@v0`).

## Context

`jellyfin` and `seerr` have been ported from the **old** catalog
(`opmodel.dev/opm/v1alpha1@v1` + per-domain subpackages such as
`resources/extension`, `resources/security`, `resources/admission`,
`kubernetes/v1/resources/storage`) to the **new** catalog
(`opmodel.dev/catalogs/opm` → imported as `bp` / `res` / `tr`).

"Converting a module" therefore means re-expressing it against the new catalog.
Migration is gated by **primitives the old catalog had that the new one does
not yet provide**.

Across the 24 unconverted modules: **72 CRD definitions** and **~40 distinct
Custom Resource _instance_ kinds**, plus admission webhooks, storage classes,
and an aggregated API service.

### Packaging decision (2026-06-16)

`catalog_opm` stays **vendor-neutral**: it ships the generic Custom Resource
emitter and Kubernetes-native resources only. Vendor-specific typed CR builders
(cert-manager, gateway-api, mongodb/clickhouse/otel, monitoring.coreos.com) are
**separate published catalogs**, mirroring the old per-vendor package layout.

---

## Already covered by the new catalog — do NOT rebuild

Verified against `catalog_opm/src`. Most workload-shaped modules port cleanly:

- Workload blueprints: `#StatelessWorkload` (Deployment), `#StatefulWorkload`
  (StatefulSet), `#DaemonWorkload` (DaemonSet), `#TaskWorkload` (Job),
  `#ScheduledTaskWorkload` (CronJob)
- `#InitContainers`, `#SidecarContainers`, `#HostNetwork` / `#HostPID` / `#HostIPC`
- SecurityContext: `privileged`, `runAsUser`, `capabilities`,
  `supplementalGroups`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation`
- Volumes: `pvc` / `emptyDir` (+ medium) / `nfs` / `hostPath` / `secret` /
  `configMap`; env `fieldRef`; GPU extended resources (`#GpuResourceSchema`);
  image `digest`
- `#Scaling` (HPA), `#UpdateStrategy` (Recreate/RollingUpdate),
  `#DisruptionBudget` (PDB), ServiceAccount `automountToken`
- **ClusterRole + bindings** — `#Role` already supports `scope: "cluster"` with
  `subjects` (binding is implied by subjects)
- `#CRDs` — emits CRD **definitions** (openAPIV3Schema, subresources, printer columns)
- Gateway API **routes** — `#HttpRoute` / `#GrpcRoute` / `#TcpRoute` / `#TlsRoute`

---

## Gaps (verified against catalog source)

### Tier 1 — Blocking, broadly needed

| # | Missing primitive | Why it blocks | Modules |
|---|---|---|---|
| 1 | **Generic Custom Resource _instance_ emitter** — a `#Resource` rendering an arbitrary CR (not a CRD def) | Catalog emits CRD definitions but cannot emit an **instance** (Issuer, Gateway, MongoDBCommunity, IPAddressPool…). Single biggest blocker; underpins all Tier-4 vendor catalogs. | cert_manager_config, gateway, clickstack, ch_vmm, istio_ambient, metallb, linstor |
| 2 | **`ValidatingWebhookConfiguration` + `MutatingWebhookConfiguration`** (+ cert-manager `inject-ca-from` annotation support) | Admission-control operators have no home. Old catalog: `kubernetes/v1/resources/admission`. | cert_manager, istio_ambient, ch_vmm, metallb, snapshot_controller |
| 3 | **`StorageClass`** resource | Storage modules can't declare their class. Old catalog: `kubernetes/v1/resources/storage`. | openebs, openebs_zfs, linstor |

### Tier 2 — Needed by specific infra modules

| # | Missing primitive | Modules | Note |
|---|---|---|---|
| 4 | **`APIService`** (aggregated API registration) | metric_server, cert_manager | metric_server does this manually post-deploy today |
| 5 | **`VolumeSnapshotClass`** + `snapshot.storage.k8s.io` objects | snapshot_controller, openebs_zfs | can ride on #1 once it exists |
| 6 | **`NetworkPolicy`** | istio_ambient (optional) | |
| 7 | **`Namespace`** resource | cdi + most modules | minor; assumed everywhere |

### Tier 3 — Small extensions to existing primitives

| # | Extension | Where | Modules |
|---|---|---|---|
| 8 | **Headless Service** (`clusterIP: None`) | `#ExposeSchema` allows only ClusterIP/NodePort/LoadBalancer | ch_vmm, any StatefulSet |
| 9 | **`mountPropagation`** (Bidirectional / HostToContainer) | absent from `#VolumeMountSchema` | ch_vmm |
| 10 | **`nonResourceURLs` + `resourceNames`** on `#PolicyRuleSchema`; **aggregation / per-object labels** on `#RoleSchema` | RBAC schema too narrow (apiGroups/resources/verbs only) | cert_manager, metric_server, ch_vmm, k8up |
| 11 | **`seLinuxOptions` + `seccompProfile`** | absent from `#SecurityContextSchema` | intel_gpu_device_plugin |

### Tier 4 — Vendor typed-CR catalogs (separate published modules)

Compose on top of the generic emitter (#1). Build the most-reused first.
`clickstack` depends on three at once (mongodb + clickhouse + otel) → last domino.

- `cert_manager` → Certificate / Issuer / ClusterIssuer
- `gateway_api` → Gateway / GatewayClass / ReferenceGrant / BackendTLSPolicy (objects, not routes)
- `monitoring.coreos.com` → ServiceMonitor / PrometheusRule (today hacked as
  ConfigMap-wrapped JSON in sealed_secrets, k8up)
- `mongodb_operator` → MongoDBCommunity
- `clickhouse_operator` → ClickHouseInstallation / Keeper / Template / Config
- `otel_collector` → OpenTelemetryCollector / Instrumentation / OpAMPBridge

---

## Module conversion readiness

| Bucket | Modules | Needs |
|---|---|---|
| **Convertible today** (pilots) | garage, zot_registry_ttl, intel_gpu_device_plugin, intel_gpu_exporter, mc_java_fleet | none — pure workload + volumes + existing traits |
| **CRD-defs + RBAC + ServiceMonitor-hack** (possible now, cleaner with Tier-4 monitoring) | otel_collector, clickhouse_operator, mongodb_operator, k8up, sealed_secrets | none blocking |
| **Need #1 (CR emitter)** | cert_manager_config, gateway, clickstack | Tier 1.1 |
| **Need #2 webhooks (+#1)** | cert_manager, istio_ambient, ch_vmm | Tier 1.1 + 1.2 (+ Tier 3 for ch_vmm) |
| **Need #3 StorageClass** | openebs, openebs_zfs, linstor | Tier 1.3 (+ #1 for linstor CRs) |
| **Design-phase only** (no components.cue) | cdi, snapshot_controller | implement after primitives land |

---

## Recommended build order

1. **Generic Custom Resource emitter** (#1) — unblocks the most modules and
   underpins every Tier-4 vendor catalog.
2. **Admission webhooks** (#2) and **StorageClass** (#3) resources.
3. **Tier-3 schema extensions** (cheap; unblock ch_vmm and RBAC-heavy operators).
4. **Tier-4 vendor catalogs** as separate published modules — cert_manager,
   gateway_api, monitoring first (most reused).
5. **Convert** in readiness order: pilots → CRD-only operators → CR-emitter
   modules → webhook modules → storage modules → `clickstack` last.

---

## Notes / caveats

- Vendor CR _instances_ (Istio config, MetalLB pools, ZFS/Linstor state objects)
  all collapse onto primitive #1 once it exists; only ergonomics differ between
  "raw spec" and a Tier-4 typed builder.
- `linstor` is hybrid today (OPM owns CRDs + StorageClass; operator runtime comes
  from an upstream bootstrap manifest). Decide whether the port keeps that split.
- ServiceMonitor/PrometheusRule currently ship as ConfigMap-wrapped JSON — works,
  so not strictly blocking, but the monitoring Tier-4 catalog removes the hack.
- `#DisruptionBudget` already exists — leader-election / HA modules do **not**
  need a new PDB primitive (several agents mis-flagged this).
