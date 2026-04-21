# otel_collector

OPM module that deploys the OpenTelemetry operator and its three CRDs.

## Webhook mode

This module defaults to `enableWebhooks: false`, which runs the operator in its "unsupported mode": the admission webhook server is never started, so **cert-manager is not required**. Since OPM-declared CRs are already validated at CUE compile time, skipping runtime webhook validation is safe for OPM-managed workflows.

To re-enable webhooks (e.g. for non-OPM tooling creating CRs), set `enableWebhooks: true` in config. Then you must also provision a cert-manager `Certificate` populating the Secret mounted at `/tmp/k8s-webhook-server/serving-certs` — this module does not wire that up today. See upstream operator manifests for reference.

## What it installs

- 3 CRDs (simplified schema; authoring-side validation via `catalog/otel_collector`):
  - `OpenTelemetryCollector` (`opentelemetry.io/v1beta1` storage, `v1alpha1` served for compat)
  - `Instrumentation` (`opentelemetry.io/v1alpha1`)
  - `OpAMPBridge` (`opentelemetry.io/v1alpha1`)
- `opentelemetry-operator` Deployment (controller-manager) running `ghcr.io/open-telemetry/opentelemetry-operator/opentelemetry-operator:0.126.0`.
- `opentelemetry-operator` ServiceAccount + ClusterRole + ClusterRoleBinding with permissions across core, apps, autoscaling, networking, policy, monitoring.coreos.com, gateway.networking.k8s.io, and opentelemetry.io.
- `opentelemetry-operator-leader-election` namespace Role + RoleBinding.

## What it does NOT install

- The admission webhook `Service`, `ValidatingWebhookConfiguration`, `MutatingWebhookConfiguration`, and cert-manager `Certificate` are not created by this module. With `enableWebhooks: false` they are not needed. With `enableWebhooks: true` you must provision them out-of-band.
- The `TargetAllocator` CRD is omitted (used for scraping Prometheus targets). Add it separately if needed.
- `ClusterObservability` CRD is omitted (alpha feature not widely used).

## Quick start

1. Publish this module, create `releases/<env>/otel_collector/` ModuleRelease.
2. Apply. Verify the operator reaches `Ready`.
4. Create `OpenTelemetryCollector` CRs via a consumer module (e.g. `clickstack`) that depends on `catalog/otel_collector`.

## References

- [open-telemetry/opentelemetry-operator](https://github.com/open-telemetry/opentelemetry-operator)
- [Operator documentation](https://opentelemetry.io/docs/platforms/kubernetes/operator/)
- [Catalog: `catalog/otel_collector/v1alpha1`](../../catalog/otel_collector/v1alpha1/)
