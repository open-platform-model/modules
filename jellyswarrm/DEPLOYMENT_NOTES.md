# Jellyswarrm Deployment Notes

Findings from the pre-module research and container verification
(`ghcr.io/llukas22/jellyswarrm:0.3.0`, podman, 2026-08-11). Everything marked
**verified** was reproduced against the real image, not inferred from docs.

This is the OPM v2-line authoring (first module ported to core v2 + catalog
v2, 2026-08-11): identity reshape (complete modulePath, `identity/` package,
derived fqn), version-segment catalog imports, hoisted conditional spec
guards per the catalog's CUE closedness pitfall. The rendered
`jellyswarrm.toml` was diffed byte-identical against the v1-train module's
output, so the container verification below carries over unchanged.

## Upstream env-var handling is broken for multi-word settings (verified)

The app builds its config with Rust's `config` crate using
`Environment::with_prefix("JELLYSWARRM").separator("_")` and no `try_parsing`.
The `"_"` separator turns every underscore into key nesting, so
`JELLYSWARRM_PUBLIC_ADDRESS` becomes the nested key `public.address`, which
matches nothing and is **silently dropped**. Ran the container with
`PUBLIC_ADDRESS`, `SERVER_NAME`, and a JSON `PRECONFIGURED_SERVERS` set: all
three loaded as defaults, no warning. Only single-word vars work (`USERNAME`,
`PASSWORD`, `PORT`, `HOST`, `TIMEOUT` — `PASSWORD` and `PORT` verified), and env
values are always strings, so lists can never arrive via env regardless. The
upstream config docs table is wrong about this. Hence: the module renders the
full `jellyswarrm.toml` instead (env does override the file where it works —
that is why `JELLYSWARRM_PASSWORD` is safe as the secret path).

`JELLYSWARRM_DATA_DIR` is exempt: read directly via `std::env`, works fine.

## Kubelet service links pollute the app's env prefix (upstream issue #53)

A Service named `jellyswarrm` makes kubelet inject docker-link-style vars into
every pod in the namespace — `JELLYSWARRM_SERVICE_HOST`,
`JELLYSWARRM_PORT=tcp://10.x.x.x:3000`, `JELLYSWARRM_PORT_3000_TCP_*` — squarely
inside the app's config prefix. Before 0.3.0 this invalidated the entire config
(issue #53); 0.3.0 added per-field fallback parsers, so garbage now degrades to
the field default instead. The module defends twice: the app port is **fixed at
3000** (so a clobbered `port` falls back to the value we want anyway) and the
container sets `JELLYSWARRM_PORT=3000` explicitly (explicit container env beats
service links). `#config.port` only moves the Service port.
`enableServiceLinks: false` would be cleaner but is a known catalog gap.

- [ ] Confirm on nas1: startup log's `Loaded configuration` line shows the
      TOML values intact with service links present.

## preconfigured_servers semantics (verified)

Upserted into SQLite at every start, keyed by trailing-slash-normalized URL
(`upsert_preconfigured_server` in `server_storage.rs`). Updates to
name/priority/mode propagate on restart; **removals do not prune**; URL changes
register a new server. Servers registered via the UI live in the same table and
coexist. Verified: two declared servers registered on first boot from the exact
CUE-rendered TOML.

Default `media_streaming_mode` in 0.3.0 is `Proxy` — the upstream docs say
`Redirect`, which matches older releases only.

## Config file ownership (verified)

- The app writes `jellyswarrm.toml` itself only when the file does not exist at
  startup, plus on management-UI "settings" and "library merge" saves
  (`ui/admin/settings.rs`, `ui/admin/libraries.rs`). With the module's read-only
  subPath mount those UI saves fail; config is CUE-owned by design.
- Because the file always exists, the app never persists its generated
  `server_id`/`session_key` — so the module requires `serverId` pinned in
  config, and accepts that UI sessions reset on restart (unpinnable
  `session_key` without putting secret material in a ConfigMap).
- Verified end-to-end: CUE-rendered TOML mounted read-only + env password →
  clean start, pinned identity, both servers registered.

## Probes (verified)

`/System/Info/Public` answers 200 locally with zero backends configured and no
auth — probe health never depends on upstream Jellyfin servers. With
`urlPrefix` set, **every** route moves under the prefix (root path answers 307);
components.cue prepends the prefix to the probe path automatically. Kubelet
would score the 307 as success, so the redirect would mask real failures if the
prefix handling regressed — keep probing the true path.

## Image (verified)

- GHCR tags are unprefixed semver: `0.3.0` exists, `v0.3.0` does not (git tags
  carry the `v`, image tags do not).
- Pinned index digest for `0.3.0`:
  `sha256:1d61193d34035dee9acf6b5d9388721867dff74fc64ec0f2c7a87b7ff075b9f5`
  (multi-arch: amd64 + arm64).
- The Dockerfile has no `USER` directive — the container runs as **root**, so
  no fix-permissions init container is needed. Revisit if upstream adds a
  non-root user.

## Open items for the first cluster deployment

- [ ] Service-link resilience check (above).
- [ ] Confirm playback through the proxy against a real Jellyfin backend
      (Proxy mode) — the request-preprocessing layer is the upstream project's
      moving part.
- [ ] Decide whether `publicAddress` should match the HTTPRoute hostname
      automatically in the environment instance (kept independent in the
      module: the schema cannot know the external scheme).
