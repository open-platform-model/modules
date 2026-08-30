Seven modules, same edit each; one commit per module. Do `metallb` first (smallest, no env change). About 15 minutes per module, 2.5 hours total. `task vet` after each module.

## 1. metallb/ (10 min)

- [x] 1.1 `module.cue`: `speaker.memberlistKey: string` with the `// 0013:` marker; rewrite its doc comment; `debugValues` supplies a fake key string
- [x] 1.2 `components.cue`: update the speaker `secrets:` comment (string data, name `{instance}-speaker-memberlist`)
- [x] 1.3 `README.md`: drop the disjunction-branch section; document the string field

## 2. gotify/ (15 min)

- [x] 2.1 `module.cue`: `defaultUser.password: string`, `database.connection?: string` with markers; rewrite doc comments; `debugValues` as plain strings
- [x] 2.2 `components.cue`: `GOTIFY_DEFAULTUSER_PASS` and `GOTIFY_DATABASE_CONNECTION` use `value:` with the marker
- [x] 2.3 `README.md`: example and config table

## 3. apprise/ (10 min)

- [x] 3.1 `module.cue`: `statelessUrls?: string` with marker; `debugValues` as a string
- [x] 3.2 `components.cue`: `APPRISE_STATELESS_URLS` uses `value:`; `README.md` config table

## 4. jellystat/ (25 min)

- [x] 4.1 `module.cue`: `jwtSecret`, `database.password`, `geolite.accountId`, `geolite.licenseKey` become `string` with markers; `debugValues` as strings
- [x] 4.2 `components.cue`: delete the `opm-secrets` component and its header paragraph
- [x] 4.3 `components.cue`: `JS_GEOLITE_*`, `JWT_SECRET`, both `POSTGRES_PASSWORD` sites use `value:`
- [x] 4.4 `README.md`: architecture list, instance example, config table

## 5. fileflows/ (15 min)

- [x] 5.1 `module.cue`: `accessToken?: string` with marker; `debugValues` as a string
- [x] 5.2 `components.cue`: delete the guarded `opm-secrets` component and its header paragraph; the access-token env entry uses `value:`
- [x] 5.3 `README.md`: example

## 6. ntfy/ (15 min)

- [x] 6.1 `module.cue`: `auth.users: string`, `auth.tokens?: string` with markers; `debugValues` as strings
- [x] 6.2 `components.cue`: both env sites use `value:`; `README.md` example and config table

## 7. jellyswarrm/ (10 min)

- [x] 7.1 `module.cue`: `password: string` with marker; `debugValues` as a string
- [x] 7.2 `components.cue`: `JELLYSWARRM_PASSWORD` uses `value:`; `README.md` example

## 8. Land the durable decisions (15 min)

- [x] 8.1 `DESIGN_PATTERNS.md`: replace § `schemas.#Secret` and the summary-table row with the interim rule (string field, `value:` injection, `// 0013:` marker, no `opm-secrets`); keep the fake-value guidance for `debugValues`
- [x] 8.2 `metallb/DEPLOYMENT_NOTES.md`: memberlist key is a hand-authored Secret mounted as a volume, rendered as `{instance}-speaker-memberlist`

## 9. Verify (15 min)

- [x] 9.1 `git grep -n 'res.#Secret\b\|AutoSecrets\|opm-secrets\|\$secretName\|\$dataKey\|remoteKey\|from: #config' -- '*.cue' '*.md'` returns nothing
- [x] 9.2 `task check`, then `task vet CONCRETE=true`
- [x] 9.3 `opm module publish ./<module> --dry-run` for each of the seven modules
