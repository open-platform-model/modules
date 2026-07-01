# mc_router

A standalone [itzg/mc-router](https://github.com/itzg/mc-router) for hostname-based
Minecraft TCP routing, running in Kubernetes service-discovery mode
(`IN_KUBE_CLUSTER`). Backends are discovered from Service annotations — there are
**no static `--mapping` args** and no central server list.

Pair it with `mc_java_server` releases, which stamp the discovery annotations
(`mc-router.itzg.me/externalServerName`, `mc-router.itzg.me/defaultServer`) onto
their Services.

## Watch scope (multi-router safe)

By default the router watches **only its own namespace** via `KUBE_NAMESPACE`, and
its RBAC is a namespaced `Role` + `RoleBinding`. Two routers in different namespaces
therefore observe disjoint Services and never fight over backends — safe to run a
trial alongside production.

| Field | Default | Notes |
|---|---|---|
| `router.watchNamespace` | own `namespace` | Single namespace mc-router discovers in |
| `router.watchAllNamespaces` | `false` | `true` widens to cluster-wide (omits `KUBE_NAMESPACE`, uses a `ClusterRole`) |
| `router.port` | `25565` | Listen port |
| `router.serviceType` | `LoadBalancer` | Use `ClusterIP` for a port-forward trial |
| `router.defaultServer` | — | Optional `{host, port}` fallback (prefer the per-server `defaultServer` annotation) |
| `router.api` | off | REST API (`/routes`) for inspecting discovered backends |
| `router.autoScale` / `router.metrics` | — | Optional |

## Resources produced

```text
Deployment/{releaseName}-router
Service/{releaseName}-router
ServiceAccount/{releaseName}-router
Role + RoleBinding/{releaseName}-router          # or ClusterRole when watchAllNamespaces
```
