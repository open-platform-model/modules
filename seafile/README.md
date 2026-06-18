# seafile

Self-hosted [Seafile](https://www.seafile.com/) **Community Edition** — file sync
and share — modelled as an OPM module.

| | |
| --- | --- |
| Module path | `opmodel.dev/modules/seafile@v0` |
| Workload | 1× StatefulSet (seafile) + 1× StatefulSet (mariadb) + 1× Deployment (memcached) |
| Catalog | `opmodel.dev/opm/v1alpha1@v1`, `opmodel.dev/core/v1alpha1@v1` |

## Components

```
seafile   StatefulSet  Seahub web UI + fileserver on :80, /shared PVC
mariadb   StatefulSet  Relational store (ccnet_db / seafile_db / seahub_db), /var/lib/mysql PVC
memcached Deployment   In-memory cache for Seahub
```

The Seafile server connects to MariaDB at `<release>-mariadb:3306` and shares the
MariaDB root password with it through a single auto-created Kubernetes Secret
(`seafile-secret`). A `wait-for-mariadb` init container blocks Seafile startup
until the database accepts TCP connections.

## Cross-component DNS

OPM names Services `<release>-<component>`, which the module cannot know at author
time. Set `releaseName` in `#config` to the release's `metadata.name` so the
Seafile server builds the correct `DB_HOST`.

## Configuration

| Field | Default | Notes |
| --- | --- | --- |
| `releaseName` | `"seafile"` | MUST equal the release `metadata.name`. |
| `image` | `seafileltd/seafile-mc:11.0-latest` | Community Edition. |
| `mariadbImage` | `mariadb:10.11` | |
| `memcachedImage` | `memcached:1.6.18` | |
| `port` | `80` | Seahub/fileserver port. |
| `timezone` | `"Europe/Stockholm"` | `TIME_ZONE`. |
| `seafileServerHostname` | `"seafile.example.com"` | `SEAFILE_SERVER_HOSTNAME`. |
| `adminEmail` | `"admin@example.com"` | Initial admin login. |
| `adminPassword` | secret | → `seafile-secret/admin-password`. |
| `dbRootPassword` | secret | → `seafile-secret/db-root-password`. |
| `storage.data` | 100Gi pvc → `/shared` | Libraries, file blocks, generated config. |
| `storage.database` | 10Gi pvc → `/var/lib/mysql` | MariaDB data dir. |
| `serviceType` | `ClusterIP` | |
| `httpRoute` | _unset_ | Gateway API HTTPRoute (hostnames + gatewayRef). |
| `resources` / `mariadbResources` | _unset_ | Optional requests/limits. |

## Quick start (release)

```cue
import (
	mr "opmodel.dev/core/v1alpha1/modulerelease@v1"
	m "opmodel.dev/modules/seafile@v0"
)

mr.#ModuleRelease
metadata: {name: "seafile", namespace: "seafile"}
#module: m
values: {
	releaseName:           "seafile"
	seafileServerHostname: "file.example.com"
	adminEmail:            "you@example.com"
	adminPassword: {value: "<generated>"}
	dbRootPassword: {value: "<generated>"}
	storage: {
		data: {type: "pvc", size: "100Gi", storageClass: "linstor-storage"}
		database: {type: "pvc", size: "10Gi", storageClass: "linstor-storage"}
	}
	httpRoute: {
		hostnames: ["file.example.com"]
		gatewayRef: {name: "gateway-gateway", namespace: "istio-ingress"}
	}
}
```

See `DEPLOYMENT_NOTES.md` for behind-a-reverse-proxy and memcached caveats.
