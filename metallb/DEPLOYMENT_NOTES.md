# metallb — Deployment Notes

## Memberlist key is a hand-authored Secret mounted as a volume

`speaker.memberlistKey` is a plain string (`#config.speaker.memberlistKey`). OPM creates
and manages the Secret from it via the speaker component's hand-authored `secrets:` entry
(`components.cue`), which the volume mount references — not the `// 0013:` interim
sensitive-field pattern the other six modules in this fleet use, and not the removed
legacy `res.#Secret` mechanism.

The rendered Secret name is `{instance}-speaker-memberlist`. RBAC `resourceNames` scoping
in `controller-role` and the volume ref in the speaker's DaemonSet both depend on this
exact rendered name, which in turn depends on the ModuleInstance being named `metallb`
(see the instance-naming warning in `module.cue` and `README.md`).
