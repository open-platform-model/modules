# clickhouse_operator

OPM module that deploys the Altinity ClickHouse operator and its four CRDs.

## What it installs

- 4 CRDs (simplified schema; authoring-side validation via `catalog/clickhouse_operator`):
  - `ClickHouseInstallation` (`clickhouse.altinity.com/v1`, short name `chi`)
  - `ClickHouseInstallationTemplate` (`clickhouse.altinity.com/v1`, short name `chit`)
  - `ClickHouseOperatorConfiguration` (`clickhouse.altinity.com/v1`, short name `chopconf`)
  - `ClickHouseKeeperInstallation` (`clickhouse-keeper.altinity.com/v1`, short name `chk`)
- `clickhouse-operator` Deployment containing:
  - `clickhouse-operator` controller container (`altinity/clickhouse-operator:0.26.3`)
  - `metrics-exporter` sidecar (`altinity/metrics-exporter:0.26.3`) exposing Prometheus metrics on port 8888
- `clickhouse-operator` ServiceAccount + ClusterRole + ClusterRoleBinding with permissions across Pods, Services, ConfigMaps, Secrets, StatefulSets, PVCs, PDBs, EndpointSlices, and all four CRDs.

## Notes

- **ConfigMaps omitted.** The upstream bundle ships 5 operator-config ConfigMaps (`etc-clickhouse-operator-{files,confd,configd,templatesd,usersd}`) with default XML configuration. This module does not include them — the operator falls back to compiled-in defaults, which is sufficient for standard installations. If a deployment needs to customize users, profiles, or ClickHouse server templates, add the ConfigMaps via ModuleRelease patches.
- **Webhook optional.** The upstream operator optionally registers validating/mutating admission webhooks that require cert-manager. This module does not enable webhooks by default (matches the upstream ClickStack chart's behavior). Enable by adding `MutatingWebhookConfiguration` and a `Certificate` resource via a companion module if needed.

## Quick start

1. Publish this module and create a `releases/<env>/clickhouse_operator/` ModuleRelease.
2. Apply. Verify `clickhouse-operator` Deployment reaches `Ready`.
3. Create `ClickHouseInstallation` or `ClickHouseKeeperInstallation` CRs via a consumer module (e.g. `clickstack`) that depends on `catalog/clickhouse_operator`.

## References

- [Altinity/clickhouse-operator](https://github.com/Altinity/clickhouse-operator)
- [ClickHouseInstallation reference](https://github.com/Altinity/clickhouse-operator/blob/master/docs/custom_resource_explained.md)
- [Catalog: `catalog/clickhouse_operator/v1alpha1`](../../catalog/clickhouse_operator/v1alpha1/)
