# garage

Garage is a lightweight, self-hosted S3-compatible object storage server (~9.5 MB image). This module deploys a single-node Garage instance suitable for development and testing workloads.

> **Warning:** This module is intended for **development and testing only**. The default storage type is `emptyDir`, which means all data is lost when the pod restarts. Set `storage.type = "pvc"` for any workload requiring persistence.

## Architecture

- Single `server` component: one container, one ConfigMap (`garage.toml`), two volumes (`meta` and `data`)
- Configuration is rendered into a `garage.toml` ConfigMap at deploy time from `#config` values
- S3 API exposed on port 3900, admin API on port 3903, RPC on port 3901 (cluster-internal)

## Configuration

| Field | Default | Description |
|---|---|---|
| `image.registry` | `docker.io` | Container registry |
| `image.repository` | `dxflrs/garage` | Image repository |
| `image.tag` | `v0.9.4` | Image tag |
| `namespace` | `garage` | Kubernetes namespace |
| `s3Port` | `3900` | S3 API listen port |
| `adminPort` | `3903` | Admin API listen port |
| `rpcPort` | `3901` | Cluster RPC listen port |
| `region` | `garage` | S3 region name |
| `adminToken` | _(required)_ | Bearer token for the admin API |
| `rpcSecret` | _(required)_ | 64-character hex RPC secret |
| `resources.requests.cpu` | `100m` | CPU request |
| `resources.requests.memory` | `256Mi` | Memory request |
| `resources.limits.cpu` | `500m` | CPU limit |
| `resources.limits.memory` | `512Mi` | Memory limit |
| `storage.type` | `emptyDir` | Volume type: `emptyDir` or `pvc` |
| `storage.size` | `1Gi` | PVC size (only used when `type = "pvc"`) |
| `storage.storageClass` | `""` | StorageClass name (only used when `type = "pvc"`) |
| `serviceType` | `ClusterIP` | Kubernetes Service type |

## Post-Deploy Steps

After the pod is running, use the Garage admin API to provision buckets and access keys.

### Create a bucket

```bash
garage -c /etc/garage.toml bucket create my-bucket
```

Or via the admin HTTP API (requires `adminToken`):

```bash
curl -H "Authorization: Bearer <adminToken>" \
  http://<service>:3903/v1/bucket?id=my-bucket \
  -X PUT
```

### Create an access key

```bash
garage -c /etc/garage.toml key new --name my-key
```

Then grant the key access to the bucket:

```bash
garage -c /etc/garage.toml bucket allow \
  --read --write --owner \
  --bucket my-bucket \
  --key <key-id>
```

## Persistence

By default, both `meta` and `data` volumes use `emptyDir` — **all data is lost on pod restart**.

To enable persistence, set in your release values:

```cue
storage: {
    type:         "pvc"
    size:         "10Gi"
    storageClass: "standard"
}
```

Both the metadata and data directories share the same `storage` configuration, each backed by its own PVC.
