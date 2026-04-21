# istio-ambient deployment notes

Issues and fixes encountered during actual deployment go here.

## Known gaps vs upstream Helm charts

These upstream features are intentionally not included in the v0.0.1 module — add them
only when a deployment actually requires them:

- `HorizontalPodAutoscaler` for istiod (auto-scale fields exist in `#config.istiod.autoscale` but no HPA component is rendered yet)
- `PodDisruptionBudget` for istiod (`#config.istiod.pdb` exists but no PDB component yet)
- Gateway-controller ClusterRole/Binding splitting (currently merged into main istiod ClusterRole)
- Sidecar injection template ConfigMap — not currently rendered (sidecar mode in ambient clusters is rare). Add `istio-sidecar-injector` ConfigMap from `research/charts/istiod/files/injection-template.yaml` when needed.
- NetworkPolicy resources (`#config.istiod.networkPolicy.enabled` accepted but no-op)
- Multicluster reader ServiceAccount (`istio-reader-service-account`) — referenced in `istiod-reader-clusterrole.subjects` but not created
- Profile files (`profile-platform-*.yaml`) — not auto-applied; user sets platform-specific overrides via `#config.cni.cniBinDir`/`cniConfDir`
- Validation webhook does not include the full per-CRD `rules` list upstream emits — currently generalized to `*.security.istio.io + *.networking.istio.io + *.telemetry.istio.io + *.extensions.istio.io`

## Entries

<!-- Append dated entries: -->
<!-- ## 2026-MM-DD — <short title> -->
<!-- What broke, root cause, fix applied. -->
