# mc_java_server

A single Minecraft Java server (itzg/minecraft-server): its own StatefulSet +
Service, optional backup/monitor sidecars, bootstrap init container, and optional
per-server ops tooling (code-server, restic-gui, rcon-web-admin — all default off).

One release == one server. It is the per-server half of the split formerly known as
`mc_java_fleet`; the router lives in the `mc_router` module.

## Router awareness (no static mappings)

The server's Kubernetes Service is annotated for mc-router service discovery:

```text
metadata.annotations:
  mc-router.itzg.me/externalServerName: "{name}.{domain}[,{alias}…]"
  mc-router.itzg.me/defaultServer:       "true"   # when defaultServer: true
```

A separate `mc_router` release running with `IN_KUBE_CLUSTER` watches Services in
the namespace and auto-registers this server at runtime. Add, remove, or update a
server by applying just its own release — the router needs no change.

## Key config

| Field | Notes |
|---|---|
| `name` | DNS-label server name → primary hostname `{name}.{domain}`, Service `{releaseName}-server-{name}` |
| `releaseName` | Must equal `ModuleRelease.metadata.name` |
| `domain` | Base domain for the router hostname |
| `aliases` | Extra hostnames, folded into the `externalServerName` annotation |
| `defaultServer` | `true` marks this server as mc-router's default backend |
| `rconPassword` | Shared RCON secret reference |
| `globalWhitelist` | Baseline whitelist merged into this server's `whitelist.players` |
| `codeServer` / `resticGui` / `rconWebAdmin` | Optional per-server ops UIs, default `enabled: false` |

All per-server fields (server type, jvm, server properties, storage, backup,
monitor, bootstrap, extraPorts, …) are identical to the former fleet module's
per-server schema. See `module.cue` for the full surface and `debugValues` for an
example.
