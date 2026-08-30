# ntfy Module

OPM module for [ntfy](https://github.com/binwiederhier/ntfy) — a self-hosted pub/sub
push notification server. A topic is just a URL: `curl -d "Disk at 91%"
https://ntfy.example.com/nas1-alerts` and every subscribed phone or browser buzzes.
Native apps exist for Android and iOS, and it can act as a
[UnifiedPush](https://unifiedpush.org/) distributor.

Image pinned to `v2.27.0` by digest.

> This is the OPM **v2-line** authoring of the module (`opmodel.dev/modules/ntfy` at path
> major v2, core v2 + catalog v2). It renders the same workload as the v1-train module —
> verified by diffing the rendered component spec, including a byte-identical `server.yml`.

## Architecture

Single stateful component (`ntfy`):

- **StatefulSet** — one replica (two SQLite databases on a ReadWriteOnce volume; must
  not scale out), `updateStrategy: Recreate` so the old pod releases the files and the
  volume before the new one starts.
- **ConfigMap `ntfy-config`** — the complete `server.yml`, rendered from `#config`
  with CUE's YAML encoder and subPath-mounted **read-only** at `/etc/ntfy/server.yml`.
  The image ships no config file of its own, so this mount is the entire
  configuration surface.
- **PVC `data`** — `cache.db` (message history), `user.db` (auth database) and
  `attachments/`, all under one mountPath (default `/var/lib/ntfy`).
- **Service** — `#config.port` (default 80) → container `listenPort` (default 80).
- **HTTPRoute** (optional) — Gateway API ingress.
- **Credential env vars** — provisioned users and tokens enter via `NTFY_AUTH_USERS` /
  `NTFY_AUTH_TOKENS`, never the ConfigMap. Plain strings for the interim (0013) — the
  values land in the rendered manifest in clear.

The container runs `args: ["serve"]`. This is **required**: the image's entrypoint is
the bare `ntfy` binary with no CMD, so without a subcommand it prints usage and exits 1.

### Provisioned auth — why this module can own the whole auth surface

ntfy seeds its auth database from three config options on **every start**:

| Option | Format | Delivered as |
| --- | --- | --- |
| `auth-users` | `<user>:<bcrypt-hash>:<role>`, comma-separated | `NTFY_AUTH_USERS` env |
| `auth-tokens` | `<user>:tk_<32 chars>[:<label>]`, comma-separated | `NTFY_AUTH_TOKENS` env |
| `auth-access` | `<user>:<topic-pattern>:<permission>` | rendered into `server.yml` |

Users created this way are **managed**: drop one from config and it is deleted on the
next restart. That means the auth model is declarative in the same way the rest of the
module is — no `ntfy user add` against a live pod, no drift between the cluster and git.

The split between ConfigMap and env is deliberate. Topic ACLs are not sensitive and
belong in a reviewable diff, so they render into `server.yml`. Bcrypt hashes and tokens
are credential material — bcrypt is slow to crack but not unbreakable, and a ConfigMap
is readable by anything with `get configmaps` in the namespace — so they travel as
container env vars instead. ntfy's env vars override the config file, so the two halves
compose without conflicting.

`auth.users` is **required** and `auth.defaultAccess` defaults to `deny-all`: a fresh
instance is private until an ACL entry opens something up, and an instance with no users
and deny-all would accept nothing at all.

### iOS needs an upstream, Android does not

Apple only wakes apps through APNs, and APNs certificates belong to whoever ships the
app — so a purely private server cannot deliver instantly to iPhones. Setting
`upstreamBaseUrl: "https://ntfy.sh"` makes this server forward **only the message ID**
upstream; ntfy.sh pokes the device through APNs and the app then fetches the body from
your server. Message content stays on your infrastructure; the fact that a message
happened does not. Leave it unset and iOS delivery degrades to whatever interval the OS
feels like polling at — hours, per upstream.

Android has no such constraint: the F-Droid build holds a foreground-service connection
straight to your server, at the cost of a persistent notification and some battery.

## Quick start

```bash
# Generate a bcrypt hash for each user
ntfy user hash            # prompts for the password, prints $2a$10$...
```

```cue
values: {
    baseUrl: "https://ntfy.example.com"

    auth: {
        defaultAccess: "deny-all"
        users: "emil:$2a$10$REPLACE:admin,alerts:$2a$10$REPLACE:user"
        access: [
            {user: "emil", topic: "*", permission: "rw"},
            {user: "alerts", topic: "nas1-*", permission: "wo"},
        ]
    }

    // Required for instant delivery to iPhones; omit on Android-only setups.
    upstreamBaseUrl: "https://ntfy.sh"

    storage: data: {type: "pvc", size: "5Gi", storageClass: "local-path"}

    httpRoute: {
        hostnames: ["ntfy.example.com"]
        gatewayRef: {name: "gateway-gateway", namespace: "istio-ingress"}
    }
}
```

Publish a message:

```bash
curl -u alerts:<password> -d "Disk at 91%" https://ntfy.example.com/nas1-alerts
```

## Configuration reference

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `image` | `#Image` | `binwiederhier/ntfy:v2.27.0` | pinned by digest |
| `port` | int | `80` | Service port |
| `listenPort` | int | `80` | container listen port (`listen-http`) |
| `baseUrl` | string | — | **required**, scheme included |
| `behindProxy` | bool | `true` | trust `X-Forwarded-For` |
| `timezone` | string | `Europe/Stockholm` | `TZ` |
| `auth.defaultAccess` | enum | `deny-all` | fallback when no ACL matches |
| `auth.users` | string | — | **required**, comma-separated `user:hash:role` |
| `auth.tokens` | string | optional | comma-separated `user:token:label` |
| `auth.access` | `[...#accessEntry]` | `[]` | `{user, topic, permission}`, permission `rw`/`ro`/`wo`/`deny` |
| `unifiedPush` | bool | `false` | appends `*:up*:wo` to the ACL |
| `cache.duration` | string | `12h` | message history window |
| `attachments` | struct | unset | omit to disable attachments entirely |
| `upstreamBaseUrl` | string | unset | set to `https://ntfy.sh` for iOS |
| `webRoot` | enum | unset | `app` / `home` / `disable` |
| `enableSignup` | bool | `false` | self-service account creation |
| `enableLogin` | bool | `true` | web UI login form |
| `storage.data` | `#storageVolume` | `/var/lib/ntfy`, pvc, 5Gi | cache + auth db + attachments |
| `serviceType` | enum | `ClusterIP` | |
| `httpRoute` | struct | optional | Gateway API ingress |
| `resources` | `#ResourceRequirementsSchema` | optional | |

## Notes

- **Config changes need a pod roll.** subPath mounts never update in place and ntfy
  reads `server.yml` only at startup, so `kubectl rollout restart` after a change.
- **Removing a user from `auth-users` deletes it** on the next restart, along with
  nothing else — its messages live in the topic cache, not the user record.
- **The module sets no securityContext.** The image runs as root, which is why
  `listenPort` can default to 80. Dropping to a non-root UID also requires an fsGroup
  that matches the PVC, so it is left to the instance.
- **Attachments are off unless the `attachments` block is set** — an unset
  `attachment-cache-dir` is what disables the feature upstream.
