# mongodb_operator

OPM module that deploys the MongoDB Community operator and the `MongoDBCommunity` CRD.

## What it installs

- `MongoDBCommunity` CustomResourceDefinition (`mongodbcommunity.mongodb.com/v1`) — simplified schema; authoring-side validation comes from `catalog/mongodb_operator`.
- `mongodb-kubernetes-operator` Deployment (controller only).
- `mongodb-kubernetes-operator` ServiceAccount + ClusterRole + ClusterRoleBinding.
- `mongodb-kubernetes-operator-service-binding` ClusterRole for Service Binding spec consumers.

The controller image is the unified `quay.io/mongodb/mongodb-kubernetes` (current default: `1.8.0`), started with `-watch-resource=mongodbcommunity` so it reconciles only the community CR. Swapping the image/tag in `#config` is the standard upgrade path.

## Companion images

The controller does not manage the agent/database images itself — it configures the StatefulSet pods it spawns to pull them. Defaults in `#config`:

| Field | Default | Purpose |
|---|---|---|
| `agentImage.repository` | `quay.io/mongodb/mongodb-agent` | Automation agent sidecar |
| `agentImage.tag` | `108.0.12.8846-1` | Pinned with the operator release |
| `mongodbImage` | `mongodb-community-server` | Database image name (repo in `mongodbRepo`) |
| `mongodbRepo` | `quay.io/mongodb` | Registry for the database image |

## Quick start

1. Publish this module and compose it in a `releases/<env>/mongodb_operator/` ModuleRelease.
2. Apply. Verify the operator reaches `Ready`.
3. Create a `MongoDBCommunity` CR — either by hand or via a consumer module (e.g. `clickstack`) that depends on `catalog/mongodb_operator`.

## References

- [mongodb/mongodb-kubernetes](https://github.com/mongodb/mongodb-kubernetes) — unified operator
- [mongodb-community-operator/](https://github.com/mongodb/mongodb-kubernetes/tree/master/mongodb-community-operator) — community codepath
- [MongoDBCommunity CRD](../../catalog/mongodb_operator/v1alpha1/)
