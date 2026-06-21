# northbyte_web — deployment notes

## Catalog line: System A (opm/v1alpha1, cue v0.16)

This module is on **System A** — `opmodel.dev/opm/v1alpha1` + `core/v1alpha1`, language
`v0.16.0` — the line the entire deployed fleet uses (gateway, mc_java_fleet, seafile,
seerr_v016, zot_registry_ttl, wolf, …). It is patterned on `seerr_v016` and
`zot_registry_ttl`: flat trait composition (`resources_workload.#Container` +
`traits_workload.#Scaling`/`#RestartPolicy`/`#UpdateStrategy` + `traits_network.#Expose`
+ conditional `traits_network.#HttpRoute`), `workload-type: stateless` → Deployment.

It is NOT on the experimental System-B line (`catalogs/opm@v0` + `core@v0`,
`v0.17.0-alpha`) used by `web_app`/`seerr`/`jellyfin`. Those have `*_v016` System-A
twins that are the actually-deployable versions. An earlier draft of this module was
built on System B and did not deploy — do not reintroduce those imports.

## Toolchain

Vet/publish with **cue v0.16** (`/home/linuxbrew/.linuxbrew/bin/cue` on this machine).
The `~/go/bin/cue` is `v0.17.x-alpha` and will reject `core/v1alpha1`/`opm/v1alpha1`
imports or mis-evaluate closedness. `opm` itself embeds CUE SDK v0.15 and renders the
release fine against a v0.16 module.

```
cd modules/northbyte_web
CUE_REGISTRY='opmodel.dev=localhost:5000+insecure,registry.cue.works' \
CUE_CACHE_DIR=../../.cue-cache /home/linuxbrew/.linuxbrew/bin/cue vet ./...
# publish (version must match the release's cue.mod pin):
/home/linuxbrew/.linuxbrew/bin/cue mod publish v0.1.0
```

## Probes

nginx returns `200` at `/`, so `/` is used for both readiness and liveness. If the site
ever moves behind auth or a non-200 root, point the probes at a dedicated health path.

## Image pull

The site image (`ghcr.io/emil-jacero/northbyte-web`) must be pullable by the cluster.
The module has no `imagePullSecrets` field, so either make the ghcr package **public**
(done for go-live; image is secret-free) or attach a pull secret to the namespace's
default ServiceAccount out-of-band.
