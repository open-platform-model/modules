# clickstack

OPM module that deploys [ClickHouse ClickStack](https://github.com/ClickHouse/ClickStack-helm-charts) — an observability stack consisting of the HyperDX UI/API, a ClickHouse cluster for telemetry storage, a MongoDB replica set for UI metadata, and an OpenTelemetry Collector for OTLP ingestion.

## Prerequisites

This module composes custom resources managed by operators that must already be installed:

| Prerequisite module | What it provides |
|---|---|
| `modules/mongodb_operator` | Reconciles `MongoDBCommunity` CRs |
| `modules/clickhouse_operator` | Reconciles `ClickHouseInstallation` + `ClickHouseKeeperInstallation` CRs |
| `modules/otel_collector` | Reconciles `OpenTelemetryCollector` CRs |
| `modules/cert_manager` | Webhook TLS required by `modules/otel_collector` |

Install all four operators (with their CRDs) and wait for them to be healthy before applying this module.

## What it installs

- `hyperdx` Deployment — HyperDX UI at port `3000`, API at `8000`, OpAMP at `4320`
- `clickstack-config` ConfigMap — shared non-sensitive environment variables
- `clickstack-defaults` ConfigMap — default connections + sources JSON seed
- `clickstack-secret` Secret — auto-created by OPM from the four `#config` secret references (`MONGODB_PASSWORD`, `CLICKHOUSE_PASSWORD`, `CLICKHOUSE_APP_PASSWORD`, `HYPERDX_API_KEY`)
- `mongodb` MongoDBCommunity CR — 3-member replica set by default
- `clickhouse` ClickHouseInstallation CR — single-shard, single-replica by default
- `keeper` ClickHouseKeeperInstallation CR — 3-replica quorum by default
- `otel` OpenTelemetryCollector CR — Deployment-mode collector with OTLP receivers and ClickHouse exporter

## Configuration

See `module.cue` for the full `#config` schema. Most common overrides:

- `frontendUrl` — public URL used for absolute links in the HyperDX UI
- `mongodb.members`, `clickhouse.replicas`, `keeper.replicas` — topology sizing
- `mongodb.storageSize`, `clickhouse.storageSize`, `keeper.storageSize` — volume sizes
- Secrets — provide via a `ModuleRelease` patch or let OPM generate debug defaults

## Quick start

1. Install prerequisite modules and verify each operator is `Ready`.
2. Create `releases/<env>/clickstack/` with a `ModuleRelease` referencing this module.
3. Provide the four secrets via a Kubernetes `Secret` named `clickstack-secret` (or let the ModuleRelease supply them).
4. Apply. Wait for operators to reconcile CRs — ClickHouse and MongoDB StatefulSets come up first, then HyperDX once MongoDB is reachable.
5. Port-forward the HyperDX service or add an `HTTPRoute` via a release-level patch to expose the UI.

## Known limitations

- **PVCs persist on uninstall.** MongoDB and ClickHouse operators deliberately do not delete PVCs. To reclaim storage, delete PVCs manually.
- **No Ingress/HTTPRoute by default.** This module does not bake in a specific ingress strategy — compose an `HTTPRoute` or `Ingress` via a ModuleRelease patch.
- **Single namespace.** All components deploy into the same namespace (default `clickstack`). Cross-namespace topologies are not supported by this module.
- **ClickHouse operator ConfigMaps omitted.** The upstream bundle ships operator-scoped XML config; this module uses operator defaults. For custom ClickHouse user/profile policies, add the ConfigMaps via a ModuleRelease patch.
- **ClickHouse storage templates omitted.** The catalog's timoni-vendored CUE schema for `ClickHouseInstallation.spec.templates.volumeClaimTemplates[*].spec` is closed empty (an upstream CRD schema gap). The operator falls back to ephemeral storage. For persistent ClickHouse data, supply `spec.templates.volumeClaimTemplates` via a ModuleRelease patch — this bypasses the catalog's type check at the ModuleRelease layer.

## References

- [ClickStack upstream Helm chart](https://github.com/ClickHouse/ClickStack-helm-charts)
- [HyperDX documentation](https://www.hyperdx.io/docs)
- [Catalog: `catalog/mongodb_operator`, `catalog/clickhouse_operator`, `catalog/otel_collector`](../../catalog/)
