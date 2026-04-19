# ch-vmm — Deployment Notes

Known deviations from the upstream `ch-vmm.yaml` release manifest, with workarounds.

## 1. `mountPropagation` missing on the DaemonSet

**Upstream:** the daemon mounts
```
/pods  (from hostPath /var/lib/kubelet/pods) with mountPropagation: Bidirectional
/dev   (from hostPath /dev)                  with mountPropagation: HostToContainer
```

**OPM:** `#VolumeMountSchema` does not model `mountPropagation`. The rendered DaemonSet will be missing both fields.

**Impact:** VM disk workflows that mount CSI volumes *into the daemon* and then re-expose them to Cloud Hypervisor (via `/pods`) will not see the CSI volumes appear after their initial mount. Hot-attach of volumes from other pods will not work either. Basic boot-from-image may still work if the daemon does not need propagation-aware mounts.

**Workarounds:**

1. Post-render patch via a provider annotation / ModuleRelease override to set `mountPropagation` on `daemon` pod spec.
2. Apply a `kustomize` patch in the release bundle.
3. Extend `#VolumeMountSchema` upstream to model `mountPropagation` and remove this deviation.

## 2. Daemon `Service` is not headless

**Upstream:** `ch-vmm-daemon` Service uses `clusterIP: None` (headless) so the DNS name `ch-vmm-daemon.ch-vmm-system.svc` resolves to every daemon pod's IP, and per-pod subdomain DNS (`*.ch-vmm-daemon.ch-vmm-system.svc`) is available.

**OPM:** `#ExposeSchema` only emits `ClusterIP`, `NodePort`, or `LoadBalancer`. The rendered Service will be a normal `ClusterIP`.

**Impact:** The controller reaches a single daemon pod via round-robin load balancing instead of resolving a specific per-node pod. Node-scoped operations (launching a VM on node X) may fail or misroute because the daemon cert DNS includes the wildcard `*.ch-vmm-daemon.<ns>.svc` form that only resolves under a headless Service.

**Workarounds:**

1. Post-render patch to set `spec.clusterIP: None` on the Service.
2. Extend `#ExposeSchema` with a `clusterIP?: "None" | string` field.

## 3. `virtmanager-metrics-reader` ClusterRole omitted

**Upstream:** a `ClusterRole` granting `get` on the non-resource URL `/metrics`.

**OPM:** `#PolicyRuleSchema` does not model `nonResourceURLs`. The role is not emitted.

**Impact:** Prometheus scrape identities that rely on *only* this role for `/metrics` access will get 403. Most deployments grant `/metrics` via a different aggregated role (e.g. `prometheus-k8s`) so this is typically not a blocker.

**Workarounds:**

1. Create a separate raw-manifest ClusterRole out of band.
2. Use the `kubernetes/v1` `#PolicyRuleSchema` (which models `nonResourceURLs`) in a follow-up patch.

## 4. NetworkPolicies omitted

**Upstream:** two `NetworkPolicy` objects restrict ingress to the metrics endpoint and the webhook endpoint to namespaces with `metrics: enabled` or `webhook: enabled` labels.

**OPM:** intentionally not emitted in this first cut. The module is meant to be a permissive baseline; consumers who need network isolation can layer on their own `NetworkPolicy` via a companion module or release patch.

## 5. `ClusterRoleBinding` for metrics-auth

Upstream wires `virtmanager-metrics-auth-rolebinding` directly. In this module the binding is produced automatically by the `#Role` transformer from the `subjects: [{name: _controllerSA}]` declaration on `controller-metrics-auth-role`. Functionally equivalent; the Kubernetes name may differ.

## 6. VirtualMachine editor/viewer aggregating roles include a `subjects` entry

`#RoleSchema` requires at least one subject. Aggregating roles (that rely on the aggregation label to be composed into `admin`/`edit`/`view`) do not need subjects — the subject entry we emit is a harmless duplicate binding for the controller SA, which already has broader access via `virtmanager-manager-role`.

If the OPM schema is relaxed in future, remove the subject list and let aggregation do its job.

## 7. CRD schemas are simplified

The 9 CRDs are emitted with `x-kubernetes-preserve-unknown-fields: true` instead of the full upstream OpenAPI spec. This matches the pattern used by `modules/k8up/` and `modules/cert_manager/` for operator CRDs. Cluster-side validation of spec/status fields is delegated to the controller; `kubectl explain` will show a minimal schema.

If stricter schema enforcement is needed, replace the simplified bodies in `crds_data.cue` with the full OpenAPI structs from the upstream YAML.

## 8. Image digests pinned to v1.4.0

Both `controllerImage.digest` and `daemonImage.digest` carry the upstream v1.4.0 SHA. When bumping, update both digests together — the controller and daemon are released as a pair and version skew may break the gRPC contract.

## 9. Prerequisite ordering

cert-manager must be `Ready` *before* ch-vmm is applied — otherwise the `Certificate` objects will sit pending and the controller Deployment will fail to start (webhook cert volume mount fails). In a ModuleRelease bundle, express this by ordering cert-manager before ch-vmm or using a `dependsOn` edge if the release system supports it.
