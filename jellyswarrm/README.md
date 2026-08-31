# Jellyswarrm Module

OPM module for [Jellyswarrm](https://github.com/LLukas22/Jellyswarrm) — a Rust reverse
proxy that merges multiple Jellyfin servers into **one virtual Jellyfin endpoint**.
Clients connect to it as a normal Jellyfin server; it federates users across the
backends and streams media either through itself (`Proxy`) or by redirecting clients
to the origin server (`Redirect`).

> Upstream is early-stage (first release line `0.x`). The image tag is pinned and
> every behavioral claim below was verified against `0.3.0` — see
> `DEPLOYMENT_NOTES.md` before upgrading.

> This is the OPM **v2-line** authoring of the module (`opmodel.dev/modules/jellyswarrm` at path major v2, core v2 + catalog v2). It renders the same workload as the v1-train module — the rendered `jellyswarrm.toml` is byte-identical.

## Architecture

Single stateful component (`jellyswarrm`):

- **StatefulSet** — one replica (SQLite; must not scale out), container listens on
  port 3000 (fixed by design, see below).
- **ConfigMap `jellyswarrm-config`** — the complete `jellyswarrm.toml`, rendered
  from `#config` with CUE's TOML encoder and subPath-mounted **read-only** at
  `<data>/jellyswarrm.toml`.
- **PVC `data`** — the SQLite database (server registry, user mappings, virtual
  libraries) at `/app/data`.
- **Service** — `#config.port` (default 3000) → container 3000.
- **HTTPRoute** (optional) — Gateway API ingress.
- **Credential env var** — the management-UI admin password enters via the
  `JELLYSWARRM_PASSWORD` env var, never the ConfigMap. A plain string for the
  interim (0013) — the value lands in the rendered manifest in clear.

### Why a TOML file and not environment variables

Verified against `0.3.0`: the app's config loader splits env keys on **every**
underscore, so every multi-word `JELLYSWARRM_*` variable — `PUBLIC_ADDRESS`,
`SERVER_NAME`, `PRECONFIGURED_SERVERS`, `SESSION_KEY`, `SERVER_ID`, `URL_PREFIX`, … —
is **silently ignored**, despite being documented upstream. Only single-word
variables (`USERNAME`, `PASSWORD`, `PORT`, `HOST`, `TIMEOUT`) work, and env values
cannot carry lists at all. The TOML file is the only complete declarative interface,
which suits GitOps: CUE owns the file, the app cannot rewrite it (read-only mount),
and config drift is unrepresentable.

Consequences to know about:

- **UI "settings" and "library-merge" saves fail** (they write the config file).
  Change those values here instead — that is intended: config is CUE-owned.
  Adding/removing servers and user mappings via the UI still works (SQLite).
- **`serverId` must be pinned** (32 hex chars, `openssl rand -hex 16`): the app only
  persists a generated ID when it creates the config file itself, so an unpinned ID
  would regenerate on every pod start and churn the server identity Jellyfin
  clients key on.
- **UI sessions reset on pod restart**: `session_key` is deliberately not rendered
  (it is secret material; its env override is broken upstream), so the app
  regenerates it each start. Cosmetic — log in to `/ui` again.
- Config changes need a pod restart to apply (subPath mounts do not update
  in-place, and the app reads the file only at startup).

### Declarative backend servers

`#config.servers` renders to `[[preconfigured_servers]]` and is **upserted into
SQLite on every pod start, keyed by trailing-slash-normalized URL**:

- Changing `priority` / `mediaStreamingMode` / display name for an existing URL
  propagates on the next restart.
- Changing the **URL** registers a *new* server (URL is the identity key).
- **Removing an entry does not delete the server** — the app has no pruning.
  Remove it in the management UI (`/ui`).
- Servers added via the UI coexist with declared ones.

`mediaStreamingMode` defaults to `"Proxy"` (also the app default in `0.3.0` —
upstream docs claiming `Redirect` are outdated). Use `"Redirect"` only when clients
can reach that backend's URL directly.

## Quick start

```cue
jellyswarrm: {
	module: "opmodel.dev/modules/jellyswarrm@v3"
	values: {
		serverId:      "d290f1ee6c544b0190e6d701748f0851" // openssl rand -hex 16
		publicAddress: "https://swarm.example.com"
		password:      "<generated admin password>"
		servers: {
			"Living Room": {
				url:      "http://jellyfin.media.svc.cluster.local:8096"
				priority: 100
			}
			"Friend": {
				url:      "https://jellyfin.friend.example.com"
				priority: 90
			}
		}
		httpRoute: hostnames: ["swarm.example.com"]
		storage: data: storageClass: "local-path"
	}
}
```

Then: Jellyfin-compatible API at `https://swarm.example.com/`, management UI at
`https://swarm.example.com/ui` (log in with `admin` / `password`).

## Configuration reference

| Field | Default | Notes |
| --- | --- | --- |
| `image` | `ghcr.io/llukas22/jellyswarrm:0.3.0` (digest-pinned) | GHCR tags are unprefixed (`0.3.0`, not `v0.3.0`) |
| `port` | `3000` | **Service** port; the container always listens on 3000 |
| `serverId` | — required | 32 hex chars, stable server identity |
| `publicAddress` | — required | Scheme + host clients use to reach the proxy |
| `serverName` | `Jellyswarrm Proxy` | Display name clients see |
| `username` | `admin` | Management-UI admin user |
| `password` | — required | string, injected via env, never in the ConfigMap |
| `servers` | `{}` | Declarative backends, keyed by display name (see above) |
| `includeServerNameInMedia` | `true` | Append origin server name to media titles |
| `mergeLibraries` | `true` | Merge same-named libraries into virtual libraries |
| `autoCreateUsersOnLogin` | `true` | Create proxy users on successful upstream login |
| `mediaStreamingMode` | `Proxy` | Default mode for UI-added servers |
| `timeout` | `20` | Upstream request timeout (seconds) |
| `serverBackgroundCheckIntervalSecs` | `30` | Upstream health-check interval |
| `urlPrefix` | — | Sub-path prefix; probes adjust automatically |
| `uiRoute` | app default `ui` | Path segment of the management UI |
| `healthPath` | `/System/Info/Public` | Probe path, answered locally by the proxy |
| `storage.data` | 2Gi PVC at `/app/data` | SQLite database; `pvc` / `emptyDir` / `nfs` |
| `serviceType` | `ClusterIP` | |
| `httpRoute` | — | Optional Gateway API ingress |
| `resources` | — | Suggested: requests 50m/128Mi, limits 1/512Mi — it's a thin Rust proxy in `Redirect` mode, but size CPU up if it proxies many concurrent streams |
