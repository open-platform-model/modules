# Gotify Module

OPM module for [Gotify](https://github.com/gotify/server) — a self-hosted push
notification server. Senders POST a message to the REST API with an application token;
subscribed clients receive it in real time over a WebSocket. Ships with a web UI, an
Android app (Play and F-Droid), and a CLI.

Image pinned to `3.0.0` by digest.

> This is the OPM **v2-line** authoring of the module (`opmodel.dev/modules/gotify` at
> path major v2, core v2 + catalog v2). It renders the same workload as the v1-train
> module — verified by diffing the rendered component spec.

> **No iOS app.** Gotify is Android and web only. If you need iPhone delivery, use the
> `ntfy` module instead — it has native apps for both platforms.

## Architecture

Single stateful component (`gotify`):

- **StatefulSet** — one replica (the default SQLite database sits on a ReadWriteOnce
  volume and must not be opened twice), `updateStrategy: Recreate`.
- **PVC `data`** — SQLite database, uploaded application images, and plugins, all
  under one mountPath (default `/app/data`).
- **Service** — `#config.port` (default 80) → container `listenPort` (default 80).
- **HTTPRoute** (optional) — Gateway API ingress.
- **Secret references** — the bootstrap admin password, and the database DSN when an
  external dialect is used.
- **No ConfigMap.** Gotify reads every option from a `GOTIFY_*` environment variable
  and env takes precedence over any config file, so there is nothing to render. (This
  is the opposite of the `ntfy` module, whose image ships no config file at all and
  therefore needs one mounted.)

## What this module does not manage

Applications — the senders that hold a token — and clients are created through the web
UI or the REST API and live in the database. Gotify has no config-file equivalent of
ntfy's `auth-users`, so there is no way to declare them in CUE.

This module owns the server settings and the bootstrap admin account. Getting a token
for an alerting system is a manual step:

1. Log in to the web UI as the admin user.
2. **Apps → Create Application**, name it (e.g. `grafana`).
3. Copy the generated token and store it wherever the sender's config lives.

The token is stable across restarts because it lives on the data volume — it is a
one-time setup step, not a recurring one, but it is not GitOps-managed.

`defaultUser` is applied **only when the database is first created**. Changing the
password in CUE later has no effect on an existing volume; change it in the UI. The
upstream default password is literally `admin`, so supplying a real password matters for
any instance reachable from outside the cluster.

`defaultUser.password` and `database.connection` are plain strings for the interim: the
value lands in the rendered manifest in clear (no pre-existing cluster Secret can be
referenced until `core` ships the new `#Secret`, enhancement 0013).

## Quick start

```cue
values: {
    defaultUser: {
        name:     "admin"
        password: "<generated password>"
    }

    storage: data: {type: "pvc", size: "2Gi", storageClass: "local-path"}

    httpRoute: {
        hostnames: ["gotify.example.com"]
        gatewayRef: {name: "gateway-gateway", namespace: "istio-ingress"}
    }
}
```

Send a message once you have an application token:

```bash
curl -X POST "https://gotify.example.com/message?token=<app-token>" \
  -F "title=nas1" -F "message=Disk at 91%" -F "priority=8"
```

## Configuration reference

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `image` | `#Image` | `gotify/server:3.0.0` | pinned by digest |
| `port` | int | `80` | Service port |
| `listenPort` | int | `80` | `GOTIFY_SERVER_PORT` |
| `timezone` | string | `Europe/Stockholm` | `TZ` |
| `logLevel` | enum | `info` | `debug`/`info`/`warn`/`error` |
| `defaultUser.name` | string | `admin` | bootstrap only |
| `defaultUser.password` | string | — | **required**, bootstrap only |
| `database.dialect` | enum | `sqlite3` | `sqlite3`/`mysql`/`postgres` |
| `database.connection` | string | optional | required when dialect ≠ `sqlite3` |
| `registration` | bool | `false` | self-service signup |
| `passStrength` | int | `10` | bcrypt cost |
| `streamPingPeriodSeconds` | int | `45` | WebSocket keepalive |
| `secureCookie` | bool | `true` | correct behind HTTPS |
| `extraEnv` | `[string]: string` | optional | escape hatch, see below |
| `storage.data` | `#storageVolume` | `/app/data`, pvc, 2Gi | database + images + plugins |
| `serviceType` | enum | `ClusterIP` | |
| `httpRoute` | struct | optional | Gateway API ingress |
| `resources` | `#ResourceRequirementsSchema` | optional | |

For `sqlite3` the connection path is derived from `storage.data.mountPath`, so the
database always follows the volume. External dialects take a DSN carrying credentials.

### extraEnv

`extraEnv` keys become environment variable names verbatim. It exists for the
`GOTIFY_*` options this schema does not model — chiefly OIDC (`GOTIFY_OIDC_*`, new in
3.0), CORS, and `GOTIFY_SERVER_TRUSTEDPROXIES`. The list-valued options are deliberately
left out of the typed schema because their env encoding is not verified here; if you
need one, set it through `extraEnv` and record what worked in `DEPLOYMENT_NOTES.md`.

## Notes

- **WebSocket streams and ingress idle timeouts interact.** If clients drop
  periodically, either raise the gateway's idle timeout above
  `streamPingPeriodSeconds` or lower the ping period below it.
- **`/health` is the probe endpoint** — public, unauthenticated, and it returns 500
  when the database handle is unhealthy, so it fails the pod for the right reason
  rather than only proving the HTTP listener is up.
