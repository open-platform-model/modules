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
| `name` | DNS-label server name → primary hostname `{name}.{domain}`; Service/STS are named `{releaseName}-server`, data PVC `{releaseName}-server-data` |
| `releaseName` | Must equal `ModuleRelease.metadata.name` |
| `domain` | Base domain for the router hostname |
| `aliases` | Extra hostnames, folded into the `externalServerName` annotation |
| `defaultServer` | `true` marks this server as mc-router's default backend |
| `rconPassword` | Shared RCON secret reference |
| `globalWhitelist` | Baseline whitelist merged into this server's `whitelist.players` |
| `codeServer` / `resticGui` / `rconWebAdmin` | Optional per-server ops UIs, default `enabled: false` |
| `env` | Passthrough map of raw itzg env vars, merged in last (see below) |

All per-server fields (server type, jvm, server properties, storage, backup,
monitor, bootstrap, extraPorts, …) are identical to the former fleet module's
per-server schema. See `module.cue` for the full surface and `debugValues` for an
example.

## Generic env passthrough

Escape hatch for any itzg-supported env var not covered by the curated `server:`
fields. Merged into the container env **after** every curated field — a key that
collides with a curated field either matches harmlessly or fails `cue vet` with a
conflicting-values error (it can't silently override a module-managed value).
`RCON_PASSWORD` and `CF_API_KEY` are hard-blocked (both are secret-sourced; see
`module.cue` for why).

```cue
env: {
    SOME_ITZG_ENV_VAR: "value"
}
```

### Example: structured JSON logs for VictoriaLogs / vlagent

itzg's `GENERATE_LOG4J2_CONFIG` + `LOG_CONSOLE_FORMAT` (a Log4j2 PatternLayout
string) can emit single-line JSON directly via the `%enc{...}{JSON}` converter —
no extra jars, no ConfigMap, no volume mount:

```cue
env: {
    GENERATE_LOG4J2_CONFIG: "true"
    LOG_CONSOLE_FORMAT:     #"{&quot;timestamp&quot;:&quot;%d{ISO8601}&quot;,&quot;level&quot;:&quot;%level&quot;,&quot;thread&quot;:&quot;%enc{%t}{JSON}&quot;,&quot;logger&quot;:&quot;%enc{%logger}{JSON}&quot;,&quot;message&quot;:&quot;%enc{%msg}{JSON}&quot;,&quot;exception&quot;:&quot;%enc{%xEx}{JSON}&quot;}"#
}
```

> **Must XML-escape literal `"` as `&quot;`.** itzg's `GENERATE_LOG4J2_CONFIG`
> does a raw, unescaped substitution of this value into
> `<PatternLayout pattern="...">` in the generated `log4j2.xml` — a literal `"`
> breaks that XML attribute (a `SAXParseException` at startup makes Log4j2
> silently fall back to its default plain-text layout). `%enc{...}{JSON}` still
> separately JSON-escapes each field's *runtime content*; the `&quot;` escaping
> is only for the literal JSON-structure quotes in the pattern string.

`%enc{%xEx}{JSON}` also folds multi-line exception stack traces into the single
`exception` field on ONE physical log line, so a Java stack trace arrives as a
single vlagent record. Confirmed working on Forge 1.20.1 and Fabric 1.21.1 —
FML does not override the generated `log4j2.xml`. See the `mc_java_fleet` README
for the full write-up.
