# SABnzbd — Usenet Download Client

Single stateful component: a config PVC, an optional downloads mount, a web Service, health
checks and an optional Gateway API HTTPRoute.

`opmodel.dev/modules/sabnzbd@v1` · pins `catalogs/opm@v1.0.0-alpha.6` + `core@v1.0.0-alpha.3`.

Shares the identity model of the `radarr` / `sonarr` modules — `USER nobody:nogroup`, no
PUID/PGID, no s6-overlay, so identity is `runAsUser`/`runAsGroup`/`fsGroup` and no root init
container is needed. Read that module's README for the reasoning.

## The entrypoint is the interface

Unlike the Servarr images, this one does real work before exec'ing the app. Extracted from
`ghcr.io/home-operations/sabnzbd:4.5.2` on 2026-07-29:

```sh
if [[ ! -f "/config/sabnzbd.ini" ]]; then
    cp /defaults/sabnzbd.ini /config/sabnzbd.ini
    api_key=$(tr -dc 'a-z0-9' < /dev/urandom | fold -w 32 | head -n 1)   # + nzb_key
    sed -i -e "s|^api_key *=.*$|api_key = ${api_key}|g" /config/sabnzbd.ini
fi
[[ -n "${SABNZBD__API_KEY}" ]]                && sed -i … api_key
[[ -n "${SABNZBD__NZB_KEY}" ]]                && sed -i … nzb_key
[[ -n "${SABNZBD__HOST_WHITELIST_ENTRIES}" ]] && sed -i "… host_whitelist = ${HOSTNAME:-sabnzbd}, …"
[[ -n "${SABNZBD__LOCAL_RANGES_ENTRIES}" ]]   && sed -i … local_ranges
exec python /app/SABnzbd.py --browser 0 --server ${SABNZBD__ADDRESS}:${SABNZBD__PORT} …
```

Those four rewrites run on **every** start, not only the first — so they are declarative,
and they also overwrite anything changed in the web UI.

## Configuration

| Field | Default | Notes |
|---|---|---|
| `image` | `ghcr.io/home-operations/sabnzbd:4.5.2` | |
| `port` | `8080` | → `SABNZBD__PORT`, which builds the real `--server` argument |
| `bindAddress` | `[::]` | → `SABNZBD__ADDRESS` |
| `timezone` | `Europe/Stockholm` | → `TZ` |
| `runAsUser` / `runAsGroup` | `65534` | Load-bearing on `root_squash`ed NFS |
| `healthPath` | `/` | See below |
| **`hostWhitelist`** | — | **Effectively mandatory behind an ingress** |
| `localRanges` | — | Who is treated as authenticated |
| `env` | — | Arbitrary environment, verbatim |
| `storage.config` | 10Gi PVC at `/config` | `sabnzbd.ini` + the `admin/` queue and history databases |
| `storage.downloads` | — | Where downloads land. The Servarr apps mount the same directory |
| `serviceType` / `serviceName` | `ClusterIP` / — | Read the warning before setting `serviceName` |
| `httpRoute`, `resources`, `podScheduling`, `podMetadata` | — | |

### `hostWhitelist` — the field that decides whether this works

SABnzbd rejects any request whose `Host:` header is a DNS name it does not recognise:
*"Access denied - Hostname verification failed"*. Behind an ingress the Host header is the
public name, so leaving this unset makes the app unreachable through the very route that was
created for it — **and the failure reads like a routing fault, not a configuration one.**

Every hostname in `httpRoute.hostnames` belongs here too:

```cue
httpRoute: hostnames: ["sab.example.com"]
hostWhitelist: ["sab.example.com"]
```

Raw IP addresses are always accepted, which is why the kubelet's probes work without an
entry. The entrypoint also prepends the container's own `$HOSTNAME`, so a StatefulSet's
stable pod name is whitelisted for free.

**In-cluster callers need entries too, and this catches people out.** Under docker-compose
the bare service name is whitelisted for free, because `$HOSTNAME` *is* that name. In
Kubernetes `$HOSTNAME` is the **pod** name (`sabnzbd-sabnzbd-0`), so a peer calling
`http://sabnzbd:8080/` sends a Host header that is not on the list and gets **403
Forbidden** — DNS resolves, the Service routes, and SABnzbd refuses. Measured on a live
cluster, not theorised.

List every name a peer might use:

```cue
hostWhitelist: [
    "sab.example.com",                    // through the ingress
    "sabnzbd", "sabnzbd.ns",              // in-cluster short forms
    "sabnzbd.ns.svc.cluster.local",       // FQDN
]
```

This matters most when migrating from Compose, where peers have a bare hostname already
stored in their own configuration: everything looks migrated and every API call 403s.

### `localRanges` — peers move from the LAN to pod IPs

`local_ranges` decides which clients bypass login. Radarr and Sonarr call this API from
**pod IPs** once they run in the same cluster, not from the LAN, so a range covering only
the LAN silently changes who is authenticated. Include the pod CIDR:

```cue
localRanges: ["10.244.0.0/16", "10.10.0.0/24"]   // read the real pod CIDR, do not copy this
```

### `healthPath` defaults to `/`, not `/api?mode=version`

The kubelet builds the probe URL with the configured value as the URL **path**, which
percent-escapes `?` — a query string in a probe path does not survive. `/` answers with a
2xx/3xx, which is what the probe checks.

### ⚠ `serviceName` + `httpRoute` is broken on alpha.6

This module is the one that most wants both — an exact Service name so peers can keep
addressing it as a bare hostname, *and* an ingress route — and on this catalog version it
cannot have both.

`serviceName` renders the Service verbatim and the `service` and `statefulset` transformers
honour it. **The route transformers do not**: they build their `backendRef` from the
instance-scoped `{instance}-{component}` name, so the route points at a Service that does
not exist. `cue vet` passes, the render succeeds, the objects apply, and it fails only at
request time as a **503 from the gateway**. All four route transformers share it.

Workaround — leave `serviceName` unset and add a plain Service alongside the ModuleInstance:

```yaml
apiVersion: v1
kind: Service
metadata: {name: sabnzbd, namespace: nzb}
spec:
  ports: [{name: http, port: 8080, targetPort: 8080}]
  selector:
    app.kubernetes.io/name: sabnzbd
    component.opmodel.dev/name: sabnzbd
    core.opmodel.dev/workload-type: stateful
    module-instance.opmodel.dev/name: sabnzbd
```

The route then targets the module's own Service and the bare name still resolves.

## Rendered objects

`StatefulSet` · `Service` · `PersistentVolumeClaim` · `HTTPRoute` when `httpRoute` is set.

## Known gaps

- **No API-key pre-seeding.** The image reads `SABNZBD__API_KEY` / `SABNZBD__NZB_KEY`, but
  those are credentials and putting them in `env` would put them in cleartext in the
  instance values. Use the keys generated on first boot, or the ones already in a migrated
  `sabnzbd.ini`. Modelling them properly needs a `#Secrets` component.
- **Size `storage.config` against the INI's `download_dir`.** If incomplete downloads land
  under `/config` rather than the downloads mount, this volume carries every in-flight
  unpack and needs tens of GB, not the couple of GB the configuration uses.
