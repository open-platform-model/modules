# K8up Deployment Notes

## Global S3 credentials: literals only until 0013

secretKeyRef-based global S3 credentials (`BACKUP_GLOBALACCESSKEYID` /
`BACKUP_GLOBALSECRETACCESSKEY` wired from a pre-existing Secret via `extraEnv.<name>.from`)
are unsupported: `catalogs/opm` v3 removed the legacy secret mechanism (`#EnvVarSchema.from`,
`#SecretK8sRef` / `#SecretLiteral`), and the fleet crossed to catalog v4 on 2026-08-31
(change `fleet-repin-catalog-v4`). The removed path never worked end to end, so nothing
running depends on it.

Until enhancement 0013's core-owned `#Secret` ships, `extraEnv` takes literal name/value
pairs only. Sites that must change back when it lands carry the standard `// 0013:` marker
(`module.cue` `#config.extraEnv` doc comment and `debugValues`).
