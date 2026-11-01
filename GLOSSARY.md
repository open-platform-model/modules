# Modules

The OPM module definitions: one pure-CUE module per directory, published as
`opmodel.dev/modules/<name>`. A module consumes the published core and catalog contracts and
defines no core construct and no catalog member.

## Language

### The module and its parts

**Module**:
One directory of this repo that holds one deployable application as pure CUE, published as
`opmodel.dev/modules/<name>` at its major. In the schema it is a `#Module`: `module.cue` embeds
the core `#Module` and fills its metadata and `#config`.
_Avoid_: package, app, chart, plugin

**Fleet**:
The set of all modules in this repo, which share one file layout, one style and one release
route. Fleet consistency is a rule: a reader of one module can read all of them.
_Avoid_: catalog, collection, registry

**Design-only module**:
A module directory with no `cue.mod/`, such as one that holds only a design document.
_Avoid_: stub, placeholder

**Component**:
One entry of `#components` in `components.cue`: a unit of a module that renders workload objects
from catalog members. Its map key addresses it; its `metadata.name` names it.
_Avoid_: service, container, deployment

**`#config`**:
The schema in `module.cue` that holds every setting an operator can choose, with its constraints
and defaults. Each field is a support obligation, so a field nothing configures stays out.
_Avoid_: values, settings file, options, parameters

**`debugValues`**:
The block in `module.cue` that gives a concrete value to every `#config` field, so a concreteness
check exercises the whole schema.
_Avoid_: test values, sample values, defaults

**Sensitive field**:
A `#config` field that holds a credential, such as an API key or password. Under the interim
rule it is a plain `string` injected with `value:`, and it lands in the rendered manifest in clear.
_Avoid_: secret field, secret

### Catalog members used by a module

**Resource**:
A catalog `#Resource` that a component embeds to declare what it needs, such as a container
or a set of volumes or ConfigMaps.
_Avoid_: Kubernetes resource, object

**Trait**:
A catalog `#Trait` that a component embeds to add one behaviour, such as an exposed port, a
restart policy or a security context.
_Avoid_: mixin, feature, option

**Blueprint**:
A catalog `#Blueprint` that composes resources and traits into a ready workload shape, such as a
stateful, daemon or task workload. A component that uses one does not add the traits it already
composes.
_Avoid_: template, preset, base component

**Passthrough member**:
A member of the raw `k8s-*` family of the catalog. It is a last resort that
a proposal must justify; the better fix is a catalog change.
_Avoid_: escape hatch, raw object, workaround

### Identity and versions

**Identity package**:
The `identity/` package of a module. It holds the two values a release moves, `ModulePath` and
`Version`, and `module.cue` mirrors both. Only `opm module version set` writes it.
_Avoid_: version file, metadata file

**Module path**:
The complete CUE path of a module including its major, such as `opmodel.dev/modules/<name>@v3`.
It is byte-identical in `cue.mod/module.cue` and in the identity package.
_Avoid_: import path, registry path, name

**Path major**:
The `@vN` suffix of the module path. It always agrees with the major of the module version, so a
module break moves both.
_Avoid_: API version, module version

**Module version**:
The bare stable SemVer literal in the identity package. Release-please sets it from the
conventional commits that touch the module directory.
_Avoid_: tag, release number

**Release class**:
The kind of version bump a commit causes for each module directory it touches: `feat`, `fix`
or `feat!`. A removed or renamed `#config` field, a changed default or a rendered object that
changes kind or name is `feat!`.
_Avoid_: bump type, severity

### Lines and branches

**Line**:
One generation of the fleet, carried by one branch: `main` is OPM v2, `v1` is the protected live
maintenance line, and `v0_legacy` is frozen. A line has one CUE toolchain and one catalog.
_Avoid_: version, generation, stream

**Train**:
The series of module versions that one line publishes to a registry path. Two trains never share
a path major for one path; this is the cross-train major separation rule.
_Avoid_: channel, release line

### Operators and authors

**Operator**:
The person who deploys a module and sets its `#config`. The operator reads the module's
README and cannot open the enhancements store.
_Avoid_: user, admin, consumer, customer

**Module author**:
The person who writes or changes a module directory. The author follows the patterns in
`DESIGN_PATTERNS.md`.
_Avoid_: developer, maintainer, contributor

### Change workflow

**Module change**:
An OpenSpec change under the `module-change` schema: proposal, design and tasks, with no specs
artifact and `skip_specs: true`. Its proposal shows the `#config` and component shape before and
after as CUE.
_Avoid_: spec change, feature, ticket

**Section**:
A `## N.` block of a change's `tasks.md`. It ends green under the validation gates, closes
with a commit task, and leaves `main` releasable.
_Avoid_: phase, milestone, step

**Durable decision**:
A decision that a future author or operator needs. It lands in `DESIGN_PATTERNS.md`, a module's
`DEPLOYMENT_NOTES.md`, `AGENTS.md` or a `references/` file before the change is archived.
_Avoid_: lasting note, archived decision
