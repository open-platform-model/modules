# Apprise Module

OPM module for [Apprise API](https://github.com/caronc/apprise-api) — a notification
**router**. One HTTP call in, fan-out to 130+ services out: ntfy, Discord, email, Slack,
Telegram, and so on.

Image pinned to `v1.5.1` by digest.

> This is the OPM **v2-line** authoring of the module (`opmodel.dev/modules/apprise` at
> path major v2, core v2 + catalog v2). It renders the same workload as the v1-train
> module — verified by diffing the rendered component spec.

> This wraps `caronc/apprise-api`, the REST service — not the Apprise Python library of
> the same name. The Docker image is confusingly called `caronc/apprise` either way.

## When this earns its place

Apprise has no app of its own; it reaches a phone only through something else. It pays
for itself when:

- **You want fan-out from one endpoint.** A sender posts once and the message lands on
  ntfy *and* Discord *and* email — adding a fourth target is a config change in one
  place instead of a new contact point in every sender.
- **You want credential containment.** Many senders need to notify, but none of them
  should hold the Discord webhook, the SMTP password and the ntfy token.
- **You want tag-based routing.** One key, many URLs, each tagged; the caller asks for
  `tag=critical` and Apprise decides where that goes.

If your only path is one sender to one target, Apprise is an extra hop with no benefit —
point the sender straight at `ntfy`.

## Architecture

Single **stateless** component (`apprise`) — a Deployment, not a StatefulSet, and the
only one of the notification modules that can legitimately run more than one replica:

- **Deployment** — `#config.replicas` (default 1). Every replica mounts the same
  read-only config Secret and holds no local state.
- **Secret volume `config`** — the config Secret projected read-only at `/config`, one
  file per Apprise `{KEY}`. Mounted via `secretRef`, addressed by exact cluster name,
  because the Secret is provisioned out of band (SOPS) and not owned by this module.
- **Service** — `#config.port` (default 8000) → container `listenPort`.
- **HTTPRoute** (optional) — Gateway API ingress.
- **No PVC, no ConfigMap.** Config bodies are credential-bearing so they must be a
  Secret, and nothing else Apprise writes is worth keeping across a restart.

### Configuration is files, and that is the whole trick

`APPRISE_STATEFUL_MODE=simple` means a config `{KEY}` is *literally* the file
`<KEY>.yml` (YAML) or `<KEY>.cfg` (TEXT) in the config directory. So a mounted Secret
**is** the configuration — no API calls to `/add/{KEY}`, no clicking in the web UI, no
runtime state to back up.

`APPRISE_CONFIG_LOCK=yes` then blocks the API from adding, deleting or reading back
configuration, while `/notify/{KEY}` keeps resolving it normally. That is what makes the
read-only mount safe rather than merely restrictive: the config cannot drift from CUE
because nothing is able to change it.

**Verified against `v1.5.1` (2026-08-13):**

- A read-only `/config` with `configLock` enabled returns `GET /status` → **200**, body
  `{"config_lock": true, "status": {"can_write_config": false, "details": ["OK"]}}`. The
  config lock suppresses the `CONFIG_PERMISSION_ISSUE` that an unwritable config
  directory would otherwise report, so the health probe still fails for real problems
  and not for the mount being read-only. This was the one open risk in the design and it
  is settled — no init container needed.
- A seeded file is picked up as a key: `POST /notify/nas1` returned **424** (URLs loaded,
  delivery failed as expected against a dead target) while `POST /notify/doesnotexist`
  returned **204** (no such config). The 204/424 distinction is how you tell "key not
  found" from "key found, delivery failed".

### What CUE owns, and what it does not

CUE owns which config keys exist, how they are projected into the container, and every
server setting. It does **not** own the URL bodies.

An Apprise URL embeds its own credential — `discord://id/token`,
`mailto://user:pass@host`, `ntfy://user:pass@host/topic` — and a config file is a single
blob that cannot carry a `secretKeyRef`. So the bodies live in a SOPS-managed Secret,
one Secret key per Apprise key, and `configSecret.keys` lists which ones to project.
Listing them in CUE is deliberate: a typo fails loudly at mount time rather than
silently serving an empty config.

## Quick start

The Secret must exist **before** the ModuleInstance is applied — this module references
a pre-existing Secret and does not create one.

```bash
cat > nas1.yml <<'EOF'
version: 1
urls:
  - ntfy://alerts:PASSWORD@ntfy.example.com/nas1-alerts:
    - tag: all, critical
  - discord://WEBHOOK_ID/WEBHOOK_TOKEN:
    - tag: all
EOF

kubectl create secret generic apprise-config -n notifications \
  --from-file=nas1=nas1.yml
```

```cue
values: {
    mode: "stateful"
    configSecret: {
        name: "apprise-config"
        keys: ["nas1"]
    }

    // Only the services actually in use. Note that upstream IGNORES the deny
    // list whenever an allow list is set — they are not additive.
    allowServices: "ntfy, discord"

    httpRoute: {
        hostnames: ["apprise.example.com"]
        gatewayRef: {name: "gateway-gateway", namespace: "istio-ingress"}
    }
}
```

Send a notification:

```bash
# Everything in the nas1 config
curl -X POST -d 'body=Disk at 91%' https://apprise.example.com/notify/nas1

# Only the URLs tagged "critical"
curl -X POST -d 'tag=critical' -d 'title=nas1' -d 'body=Disk at 91%' \
  https://apprise.example.com/notify/nas1
```

## Configuration reference

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `image` | `#Image` | `caronc/apprise:v1.5.1` | pinned by digest |
| `port` | int | `8000` | Service port |
| `listenPort` | int | `8000` | `HTTP_PORT` |
| `mode` | enum | `stateful` | `stateful` / `stateless` |
| `configSecret` | `{name, keys}` | — | required when `mode: stateful` |
| `configFormat` | enum | `yaml` | `yaml` → `.yml`, `text` → `.cfg` |
| `configLock` | bool | `true` | keep it on; see above |
| `defaultConfigId` | string | `apprise` | the key the web UI defaults to |
| `statelessUrls` | `#Secret` | optional | default targets in `stateless` mode |
| `admin` | bool | `false` | allows listing stored keys |
| `apiOnly` | bool | `false` | `true` disables the web UI |
| `strictMode` | bool | `true` | nginx rejects unsupported requests |
| `baseUrl` | string | optional | sub-path proxying |
| `denyServices` | string | upstream default | ignored when `allowServices` is set |
| `allowServices` | string | optional | exclusive allow list |
| `recursionMax` | int | `1` | `apprise://` chaining depth |
| `webhookUrl` | string | optional | POSTed the result of every notification |
| `attachments.enabled` | bool | `true` | `false` sets `APPRISE_ATTACH_SIZE=0` |
| `attachments.maxSizeMb` | int ≤500 | `200` | nginx cap upstream |
| `workers.count` | int | `1` | upstream computes `(2×CPUs)+1`, far too many here |
| `workers.timeoutSeconds` | int | `300` | |
| `logLevel` | enum | `INFO` | |
| `timezone` | string | `Europe/Stockholm` | nginx + app log timestamps |
| `puid` / `pgid` | int | `1000` | container starts root, drops to these |
| `replicas` | int | `1` | safe above 1 |
| `serviceType` | enum | `ClusterIP` | |
| `httpRoute` | struct | optional | Gateway API ingress |
| `resources` | `#ResourceRequirementsSchema` | optional | |

## Notes

- **There is no authentication on this API, by upstream design.** Anyone who can reach
  the Service can send notifications through any key they can name. Keep it
  `ClusterIP`-only, or put authentication in front of it at the gateway. Keys are
  effectively the only secret, so treat them as such.
- **Config changes need a pod roll.** Kubernetes updates Secret volumes in place, but
  Apprise reads config per request from disk — a projected-file update *may* be picked
  up without a restart. This is untested here; `kubectl rollout restart` is the
  guaranteed path.
- **Attachments are ephemeral.** Uploads land on the container's writable layer with no
  volume behind them, which is appropriate for transient attachments. Set
  `attachments.enabled: false` if you want them refused outright.
- **Persistent storage is deliberately off** (`APPRISE_STORAGE_MODE=memory`). Apprise's
  persistent store defaults to `<config>/store`, which is inside the read-only Secret
  mount; the store is only a URL cache, so memory mode is the right trade. A PVC-backed
  store would need a different workload shape and has no consumer yet.
- **Allow and deny lists do not compose.** Upstream ignores `APPRISE_DENY_SERVICES`
  entirely when `APPRISE_ALLOW_SERVICES` is set, so this module emits exactly one of
  them rather than both.
