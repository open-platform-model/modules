# Radarr — Movie Collection Manager

Single stateful component: a config PVC, optional library and download mounts, a web
Service, health checks and an optional Gateway API HTTPRoute.

`opmodel.dev/modules/radarr@v1` · pins `catalogs/opm@v1.0.0-alpha.6` + `core@v1.0.0-alpha.3`.

The **`sonarr`** module is this module with a different name, port, image and env prefix.
They are kept structurally identical — see [Sibling module](#sibling-module).

## Why this is not modelled like `jellyfin`

`jellyfin` follows the LinuxServer.io convention: `PUID`/`PGID` environment variables and a
root `fix-permissions` init container that `chown -R`s the config volume before the app
starts. **None of that applies here.** Verified against the image on 2026-07-29:

```console
$ crane config ghcr.io/home-operations/radarr:5.27.0 | jq -c '{user,Entrypoint,Env}'
user: "nobody:nogroup"
entrypoint: ["/usr/bin/catatonit","--","/entrypoint.sh"]
env: ["DOTNET_EnableDiagnostics=0","RADARR__UPDATE__BRANCH=develop"]

$ crane export ghcr.io/home-operations/radarr:5.27.0 - | tar -xO entrypoint.sh
exec /app/bin/Radarr --nobrowser --data=/config "$@"
```

Three consequences:

| | |
|---|---|
| **Identity is Kubernetes'** | The image ships `USER nobody:nogroup` and has no mechanism to switch users. `runAsUser` / `runAsGroup` / `fsGroup` are the only way to set it |
| **No init container** | Nothing needs a root `chown`: `fsGroup` makes the kubelet chgrp the config volume on mount. **No container in this pod runs as root**, which is a namespace-PSS improvement over `jellyfin` and `seerr` |
| **Config comes from the environment** | `RADARR__UPDATE__BRANCH` ships *in the image*, which is what proves the `RADARR__<SECTION>__<KEY>` binding is live on this version. There is no seed-ConfigMap and no `config.xml` templating |

## Configuration

| Field | Default | Notes |
|---|---|---|
| `image` | `ghcr.io/home-operations/radarr:5.27.0` | |
| `port` | `7878` | |
| `timezone` | `Europe/Stockholm` | → `TZ` |
| `runAsUser` / `runAsGroup` | `65534` (the image's own `nobody`) | **Load-bearing on NFS.** Exports normally `root_squash`, so the wrong uid gets a successful mount and then `EACCES` on every read. `df` succeeding while `ls` fails is an identity problem, never a mount problem |
| `healthPath` | `/ping` | Servarr's unauthenticated health endpoint. Must carry the same prefix as any URL base |
| `env` | — | Arbitrary environment, verbatim. **This is how Servarr settings are set** |
| `storage.config` | 10Gi PVC at `/config` | SQLite (`radarr.db`, `logs.db`) in WAL mode — wants a block device, not NFS |
| `storage.media` | — | Library directories keyed by name, one mount each |
| `storage.downloads` | — | The download client's output directory. Must not be read-only |
| `serviceType` / `serviceName` | `ClusterIP` / — | See the warning below before setting `serviceName` |
| `httpRoute` | — | Gateway API route |
| `resources`, `podScheduling`, `podMetadata` | — | `podMetadata` is where k8up's `k8up.io/backupcommand` annotations go |

### Why the Servarr settings are not typed fields

Radarr binds its configuration from `RADARR__<SECTION>__<KEY>`, and it is tempting to model
`authMethod`, `logLevel`, `instanceName` and friends as typed `#config` fields. This module
deliberately does not, because **only `RADARR__UPDATE__BRANCH` is verified** — it ships in
the image. A typed field whose env name turns out to be wrong is worse than no field: it
reads as configuration and silently does nothing.

Set them through `env` instead, and check the result in `/config/config.xml`:

```cue
env: {
    RADARR__AUTH__METHOD:   "External"
    RADARR__LOG__LEVEL:     "debug"
    RADARR__APP__INSTANCENAME: "Radarr 4K"
}
```

Once a name is confirmed against a running instance it can graduate to a typed field in a
minor release.

> ⚠ These override `config.xml` on **every** start, not just the first. That is right for
> declaring a setting and wrong for an instance migrated from elsewhere, whose `config.xml`
> is already authoritative — leave `env` empty in that case.

### ⚠ `serviceName` + `httpRoute` is broken on alpha.6

Setting `serviceName` renders the Service verbatim, and the `service` and `statefulset`
transformers both honour it. **The route transformers do not.** They build their
`backendRef` from the instance-scoped `{instance}-{component}` name, so the route is
emitted pointing at a Service that does not exist.

Nothing catches this: `cue vet` passes, the render succeeds, the objects apply cleanly, and
it fails only at request time as a **503 from the gateway**. All four route transformers
(`http`/`grpc`/`tcp`/`tls`) share it; `statefulset_transformer.cue` carries a comment
showing the identical bug was already found and fixed there once.

Until the catalog is fixed, pick one: an exact Service name, **or** a route. To get both,
leave `serviceName` unset and put a second plain Service carrying the wanted name next to
the ModuleInstance, selecting the same pod labels.

## Storage layout

Mount **one volume per library directory**, not one mount of the library root. An NFS
export does not traverse into child datasets, so mounting the parent yields a view with the
media missing — and on a typical TrueNAS layout the parent is exported read-only anyway.

```cue
storage: {
    config: {mountPath: "/config", type: "pvc", size: "10Gi", storageClass: "fast-ssd"}
    media: {
        movies:   {mountPath: "/media/movies",    type: "nfs", server: "10.0.0.2", path: "/mnt/data/media/movies"}
        movies4k: {mountPath: "/media/movies_4k", type: "nfs", server: "10.0.0.2", path: "/mnt/data/media/movies_4k"}
    }
    downloads: {mountPath: "/downloads", type: "nfs", server: "10.0.0.2", path: "/mnt/data/media/downloads"}
}
```

> **Hardlinks.** If the library and the download directory are separate filesystems — which
> separate NFS exports and separate ZFS datasets both guarantee — imports are **copies**,
> not hardlinks, and `ln` across them returns `Invalid cross-device link`. That is a storage
> layout property, not something this module can change.

## Rendered objects

`StatefulSet` · `Service` · `PersistentVolumeClaim` (standalone, `{instance}-{component}-config`,
not a `volumeClaimTemplate`) · `HTTPRoute` when `httpRoute` is set.

## Sibling module

`sonarr` is generated from this module. The complete delta:

| | `radarr` | `sonarr` |
|---|---|---|
| path | `…/modules/radarr@v1` | `…/modules/sonarr@v1` |
| default image | `ghcr.io/home-operations/radarr:5.27.0` | `ghcr.io/home-operations/sonarr:4.0.15` |
| default port | 7878 | 8989 |
| env prefix | `RADARR__` | `SONARR__` |
| databases | `radarr.db`, `logs.db` | `sonarr.db`, `logs.db` |

Anything else that differs is drift. Check with:

```bash
diff <(sed -e 's/sonarr/APP/g;s/Sonarr/App/g;s/SONARR/APPUP/g;s/8989/PORT/g' sonarr/components.cue) \
     <(sed -e 's/radarr/APP/g;s/Radarr/App/g;s/RADARR/APPUP/g;s/7878/PORT/g' radarr/components.cue)
```

## Known gaps

- No typed Servarr settings (above) — `env` covers them.
- No API-key pre-seeding. Radarr generates one on first boot; read it from
  `/config/config.xml`.
- No Exportarr metrics sidecar.
