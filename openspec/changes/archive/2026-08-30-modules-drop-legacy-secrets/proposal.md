## Why

Remove every use of the legacy secret mechanism from seven v2 modules on `main`, before the fleet re-pins to `opmodel.dev/catalogs/opm@v3`.

`catalog_opm` deletes `res.#Secret` (`$secretName` / `$dataKey`), `#AutoSecrets`, `env.from` and the `opm-secrets` special name in `catalog-remove-legacy-secrets`. The mechanism never worked end to end (env `secretKeyRef` name and rendered Secret name disagree), so nothing running depends on it. This change removes it in the shape enhancement 0013 will later replace: plain values now, `core`'s `#Secret: #SecretLiteral | #SecretRef` when it ships.

## What Changes

One pattern, seven module directories. Per module: `feat!:` (a `#config` field changes type; instance values in the old shape stop unifying). No path major moves.

| Module | `#config` fields that become `string` | Sites that change |
| --- | --- | --- |
| `metallb/` | `speaker.memberlistKey` | hand-authored `secrets: memberlist:` keeps the string; volume mount and rendered `{instance}-speaker-memberlist` unchanged |
| `gotify/` | `defaultUser.password`, `database.connection?` | 2 env entries `from:` -> `value:` |
| `apprise/` | `statelessUrls?` | 1 env entry |
| `jellystat/` | `jwtSecret`, `database.password`, `geolite.accountId`, `geolite.licenseKey` | `opm-secrets` component deleted; 5 env entries (incl. bundled postgres) |
| `fileflows/` | `accessToken?` | guarded `opm-secrets` component deleted; 1 env entry |
| `ntfy/` | `auth.users`, `auth.tokens?` | 2 env entries |
| `jellyswarrm/` | `password` | 1 env entry |

Also:

1. Each module's `README.md` and `debugValues` move to the plain-string shape.
2. Every changed field and env site gets a one-line `// 0013:` marker naming what replaces it, so reintroduction is a grep.
3. `DESIGN_PATTERNS.md`: the `schemas.#Secret` section and its summary-table row become the interim rule (string field, `value:` injection, marker).

Not here: the re-pin to `catalogs/opm@v3` (own change, once `opm-v3.0.0` is on GHCR). This change vets at the current `v2.0.0-alpha.7` pin because it only stops *using* definitions that still exist there.

## Before / After

Same edit in every module; `gotify` shown, others differ only in field names.

**Before**

```cue
// gotify/module.cue
defaultUser: {
	name: string | *"admin"
	password: res.#Secret & {
		$secretName:  string | *"gotify"
		$dataKey:     string | *"admin-password"
		$description: "Gotify bootstrap admin password (applied only at database creation)"
	}
}
database: connection?: res.#Secret & {$secretName: string | *"gotify", $dataKey: string | *"database-connection", ...}

debugValues: defaultUser: password: {$secretName: "gotify", $dataKey: "admin-password", secretName: "gotify", remoteKey: "admin-password"}

// gotify/components.cue
GOTIFY_DEFAULTUSER_PASS: {name: "GOTIFY_DEFAULTUSER_PASS", from: #config.defaultUser.password}

// jellystat/components.cue, fileflows/components.cue
"opm-secrets": {
	res.#Secrets
	metadata: name: "opm-secrets"
	spec: secrets: {for _secretName, _data in (res.#AutoSecrets & {#in: #config}).out {(_secretName): {name: _secretName, data: _data}}}
}
```

**After**

```cue
// gotify/module.cue
defaultUser: {
	name: string | *"admin"
	// 0013: becomes c.#Secret when core ships it; plain string until then.
	password: string
}
// 0013: becomes c.#Secret when core ships it; plain string until then.
database: connection?: string

debugValues: defaultUser: password: "debug-admin-password"

// gotify/components.cue
// 0013: back to `from:` when the catalog regains an env secret path.
GOTIFY_DEFAULTUSER_PASS: {name: "GOTIFY_DEFAULTUSER_PASS", value: #config.defaultUser.password}

// jellystat/components.cue, fileflows/components.cue
// (opm-secrets component removed)

// metallb/components.cue (unchanged shape, string data by construction)
secrets: memberlist: data: secretkey: #config.speaker.memberlistKey
volumes: memberlist: secret: from: spec.secrets.memberlist
```

Rendered output: `jellystat` and `fileflows` stop rendering `{instance}-opm-secrets-*` Secrets; the six env-injected modules render the value in container `env` instead of a `secretKeyRef`; `metallb` is byte-identical.

## Catalog contract

`opmodel.dev/core@v2` and `opmodel.dev/catalogs/opm@v2` at the current pins (`v2.0.0-alpha.7`). No `task deps:update`: the change removes uses of catalog members and adds none. `#SecretsResource` with string `data` and the inline volume `secret` source exist at the current pin and at `@v3`. No missing member; the env-secret path is deliberately absent until 0013.

## Impact

1. Seven module directories, one `feat!:` commit each. Publish is disabled on `main`; nothing reaches GHCR.
2. **Operator migration**: instance values in either legacy shape (`{value: …}` or `{secretName, remoteKey}`) become a plain string. No pre-existing cluster Secret can be referenced until 0013; the value lands in the rendered manifest in clear. Accepted for the v2 staging line; each `README.md` says so.
3. No path major moves; the cross-train rule is not engaged.

## Enhancement

`enhancements/0013` D9. Record at archive: 0013 scoped "migrate `modules/metallb`"; the v2 fleet has seven, removed now and migrated to the new `#Secret` in a follow-up once `core` publishes it.
