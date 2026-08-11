// Components for the K8up module.
//
// Six components:
//   crds                  — all 9 K8up CustomResourceDefinition objects
//   operator              — the operator Deployment + ServiceAccount + metrics Service
//   manager-cluster-role  — ClusterRole the operator itself runs with
//   executor-cluster-role — ClusterRole the operator binds to each executor Job
//   edit-cluster-role     — aggregation-only role (admin + edit)
//   view-cluster-role     — aggregation-only role (view)
//
// Object bodies are transcribed from `helm template k8up k8up/k8up --version
// 4.10.0`. Where this module deviates from that output the deviation is
// commented at the site; the RBAC-binding one is in module.cue's header.
//
// No Namespace component. Unlike metallb/cert-manager this module has no PSS
// requirement to encode (the operator is an ordinary non-root Deployment that
// baseline admits), so the namespace stays a deployment concern.
package k8up

import (
	bp "opmodel.dev/catalogs/opm/blueprints/v1beta1"
	res "opmodel.dev/catalogs/opm/resources/v1beta1"
	tr "opmodel.dev/catalogs/opm/traits/v1beta1"
)

#components: {

	/////////////////////////////////////////////////////////////////
	//// CRDs — K8up CustomResourceDefinitions
	////
	//// Installs all 9 K8up CRDs so the cluster accepts Archive, Backup,
	//// Check, PreBackupPod, Prune, Restore, Schedule, Snapshot and
	//// PodConfig as first-class resources. Full upstream openAPIV3Schema
	//// from crds_data.cue — the API server validates Schedule cron and
	//// retention fields rather than accepting anything.
	/////////////////////////////////////////////////////////////////

	crds: {
		res.#CRDs

		let _rawCrds = {
			"archives.k8up.io":      #k8up_io_archives
			"backups.k8up.io":       #k8up_io_backups
			"checks.k8up.io":        #k8up_io_checks
			"podconfigs.k8up.io":    #k8up_io_podconfigs
			"prebackuppods.k8up.io": #k8up_io_prebackuppods
			"prunes.k8up.io":        #k8up_io_prunes
			"restores.k8up.io":      #k8up_io_restores
			"schedules.k8up.io":     #k8up_io_schedules
			"snapshots.k8up.io":     #k8up_io_snapshots
		}

		spec: crds: {
			for crdName, raw in _rawCrds {
				(crdName): {
					// controller-gen stamps its version here. Carried through so a
					// vendored CRD stays byte-identical to its source manifest.
					if raw.metadata.annotations != _|_ {
						annotations: raw.metadata.annotations
					}
					group: raw.spec.group
					names: {
						kind:   raw.spec.names.kind
						plural: raw.spec.names.plural
						if raw.spec.names.listKind != _|_ {
							listKind: raw.spec.names.listKind
						}
						if raw.spec.names.singular != _|_ {
							singular: raw.spec.names.singular
						}
						if raw.spec.names.shortNames != _|_ {
							shortNames: raw.spec.names.shortNames
						}
						if raw.spec.names.categories != _|_ {
							categories: raw.spec.names.categories
						}
					}
					scope: raw.spec.scope
					versions: [for v in raw.spec.versions {
						name:    v.name
						served:  v.served
						storage: v.storage
						if v.schema != _|_ {
							schema: v.schema
						}
						if v.subresources != _|_ {
							subresources: v.subresources
						}
						if v.additionalPrinterColumns != _|_ {
							additionalPrinterColumns: v.additionalPrinterColumns
						}
					}]
				}
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Operator — K8up backup operator (Deployment)
	////
	//// Reconciles every K8up CR cluster-wide and spawns Job executors
	//// that run restic. Exposes Prometheus metrics on :8080.
	/////////////////////////////////////////////////////////////////

	operator: {
		bp.#StatelessWorkload
		res.#ServiceAccount
		tr.#WorkloadIdentity
		tr.#Expose
		tr.#SecurityContext

		if #config.podScheduling != _|_ {
			tr.#PodScheduling
		}
		if #config.podMetadata != _|_ {
			tr.#PodMetadata
		}

		// Conditional struct-valued spec fields, HOISTED to component level
		// rather than guarded inside the spec block — the in-spec form trips
		// the CUE v0.17 closedness regression on the v2 catalog's closed
		// blueprint spec (catalog CLAUDE.md authoring pitfall; see
		// docs/cue-guard-closedness-workaround.md there). Do not inline these.
		if #config.timezone != "" {
			spec: statelessWorkload: container: env: TZ: {
				name:  "TZ"
				value: #config.timezone
			}
		}

		// Where EffectiveSchedules are stored when operatorNamespace is unset:
		// "my own namespace", which the chart expresses with the downward API
		// rather than an empty string — an empty value here would not resolve
		// to the running namespace. (The scalar `value` branch for a non-empty
		// operatorNamespace stays inline in the spec block below.)
		if #config.operatorNamespace == "" {
			spec: statelessWorkload: container: env: BACKUP_OPERATOR_NAMESPACE: fieldRef: fieldPath: "metadata.namespace"
		}

		// Job defaults. Each is emitted only when set — K8up reads an empty
		// value as a real (invalid) quantity.
		if #config.globalResources.requests.cpu != "" {
			spec: statelessWorkload: container: env: BACKUP_GLOBAL_CPU_REQUEST: {
				name:  "BACKUP_GLOBAL_CPU_REQUEST"
				value: #config.globalResources.requests.cpu
			}
		}
		if #config.globalResources.requests.memory != "" {
			spec: statelessWorkload: container: env: BACKUP_GLOBAL_MEMORY_REQUEST: {
				name:  "BACKUP_GLOBAL_MEMORY_REQUEST"
				value: #config.globalResources.requests.memory
			}
		}
		if #config.globalResources.limits.cpu != "" {
			spec: statelessWorkload: container: env: BACKUP_GLOBAL_CPU_LIMIT: {
				name:  "BACKUP_GLOBAL_CPU_LIMIT"
				value: #config.globalResources.limits.cpu
			}
		}
		if #config.globalResources.limits.memory != "" {
			spec: statelessWorkload: container: env: BACKUP_GLOBAL_MEMORY_LIMIT: {
				name:  "BACKUP_GLOBAL_MEMORY_LIMIT"
				value: #config.globalResources.limits.memory
			}
		}

		if #config.extraEnv != _|_ {
			spec: statelessWorkload: container: env: {
				for envName, e in #config.extraEnv {
					(envName): e
				}
			}
		}

		if #config.resources != _|_ {
			spec: statelessWorkload: container: resources: #config.resources
		}
		if #config.podScheduling != _|_ {
			spec: podScheduling: #config.podScheduling
		}
		if #config.podMetadata != _|_ {
			spec: podMetadata: #config.podMetadata
		}

		spec: {
			statelessWorkload: {
				scaling: count: #config.replicas
				restartPolicy: "Always"
				// On the v1 catalog line this never reached the cluster (the
				// transformer's `_updateStrategy: *null | {…}` marked default
				// swallowed it); the v2 deployment_transformer fixed that with a
				// guarded same-scope override, so the strategy now lands on the
				// rendered Deployment. Identical to the API server default
				// (RollingUpdate 25%/25%) either way.
				updateStrategy: {
					type: "RollingUpdate"
					rollingUpdate: {}
				}

				container: {
					name:  "k8up-operator"
					image: #config.image

					// K8up's entrypoint is multi-command; `operator` selects the
					// controller-manager rather than a one-shot restic command.
					args: ["operator"]

					env: {
						// Image used for the Job executors this operator spawns.
						// Without it K8up falls back to its built-in default and
						// the executors can run a different version than the
						// operator scheduling them.
						BACKUP_IMAGE: {
							name:  "BACKUP_IMAGE"
							value: #config.backupImage.reference
						}

						// TZ is conditionally set from component level — see the
						// hoisted guards above the spec block.

						BACKUP_ENABLE_LEADER_ELECTION: {
							name:  "BACKUP_ENABLE_LEADER_ELECTION"
							value: "\(#config.enableLeaderElection)"
						}
						BACKUP_SKIP_WITHOUT_ANNOTATION: {
							name:  "BACKUP_SKIP_WITHOUT_ANNOTATION"
							value: "\(#config.skipWithoutAnnotation)"
						}
						BACKUP_GLOBAL_SKIP_SNAPSHOT_SYNC: {
							name:  "BACKUP_GLOBAL_SKIP_SNAPSHOT_SYNC"
							value: "\(#config.skipSnapshotSync)"
						}

						// Where EffectiveSchedules are stored. The unset case ("my
						// own namespace" via the downward API) is written from the
						// hoisted guards above the spec block; only the scalar
						// non-empty branch stays inline.
						BACKUP_OPERATOR_NAMESPACE: {
							name: "BACKUP_OPERATOR_NAMESPACE"
							if #config.operatorNamespace != "" {
								value: #config.operatorNamespace
							}
						}

						// BACKUP_GLOBAL_* Job defaults and #config.extraEnv are
						// conditionally merged from component level — see the
						// hoisted guards above the spec block.
					}

					// Fixed at 8080: K8up's metrics server binds it unconditionally
					// and the chart hardcodes the containerPort to match.
					// #config.metrics.port moves the SERVICE port only.
					ports: http: {
						name:       "http"
						targetPort: 8080
						protocol:   "TCP"
					}

					// K8up serves no dedicated health endpoint — upstream probes
					// /metrics, which is up once the manager is running.
					livenessProbe: {
						httpGet: {
							path: "/metrics"
							port: 8080
						}
						initialDelaySeconds: 30
						periodSeconds:       10
					}

					// resources is conditionally set from component level — see
					// the hoisted guards above the spec block.

					// The chart ships `securityContext: {}` and exposes it as a
					// values knob; these two are that knob used, not a deviation.
					// A Go controller that only talks to the API server needs no
					// capabilities and never escalates.
					//
					// readOnlyRootFilesystem is deliberately NOT set: upstream
					// never asserts it, and it is the constraint that shows up as
					// a crashloop the first time the manager writes a temp file.
					//
					// This still does NOT satisfy the `restricted` Pod Security
					// Standard — that also wants seccompProfile: RuntimeDefault,
					// which #SecurityContextSchema cannot express. Under the
					// `baseline` standard Talos enforces cluster-wide, the pod is
					// admitted either way.
					securityContext: {
						allowPrivilegeEscalation: false
						capabilities: drop: ["ALL"]
					}
				}
			}

			// Pod-level only, and deliberately not the full hardening set. The
			// chart ships an empty securityContext; runAsNonRoot is added here
			// because it is what the predecessor module has run in production
			// and it costs nothing (the image already runs unprivileged).
			// readOnlyRootFilesystem is NOT set — upstream never asserts it, and
			// it is the kind of constraint that surfaces as a crashloop the
			// first time the manager writes a temp file.
			securityContext: runAsNonRoot: true

			// The operator's identity, and the subject of every ClusterRole below.
			// Both halves are required: the trait sets the pod's
			// serviceAccountName, the resource emits the ServiceAccount object.
			// automountToken must be explicit — the transformer dereferences it
			// unconditionally, so leaving the optional field unset fails the render.
			workloadIdentity: {
				name:           #config.serviceAccountName
				automountToken: true
			}
			serviceAccount: {
				name:           #config.serviceAccountName
				automountToken: true
			}

			// Metrics Service. Rendered as {instance}-{component}, so an instance
			// named `k8up` yields `k8up-operator` — the chart calls it
			// `k8up-metrics`. Scrape configs target the rendered name.
			expose: {
				ports: http: statelessWorkload.container.ports.http & {
					exposedPort: #config.metrics.port
				}
				type: #config.metrics.serviceType
			}

			// The optional podScheduling / podMetadata specs are written from
			// the hoisted guards above the spec block.
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Manager ClusterRole — what the operator itself may do
	////
	//// Transcribed rule-for-rule from the chart's operator-clusterrole.yaml.
	//// Notably NARROWER than the v0 module's hand-written version, which
	//// granted secrets, namespaces and rbac `roles` that upstream does not,
	//// and omitted the /finalizers subresources and effectiveschedules that
	//// it does.
	/////////////////////////////////////////////////////////////////

	"manager-cluster-role": {
		res.#Role

		metadata: name: "k8up-manager"

		spec: role: {
			name:  "k8up-manager"
			scope: "cluster"

			rules: [
				// Backup progress and failure events.
				{
					apiGroups: [""]
					resources: ["events"]
					verbs: ["create", "patch"]
				},
				// Discover backup targets. persistentvolumes is load-bearing:
				// without it the PV informer cannot list at cluster scope and
				// every backup stalls (observed on gon1-nas2 after an operator
				// restart — "persistentvolumes is forbidden").
				{
					apiGroups: [""]
					resources: ["persistentvolumeclaims", "persistentvolumes", "pods"]
					verbs: ["get", "list", "watch"]
				},
				// Executor Jobs run under ServiceAccounts the operator creates.
				{
					apiGroups: [""]
					resources: ["serviceaccounts"]
					verbs: ["create", "delete", "get", "list", "watch"]
				},
				// PreBackupPod runners are Deployments.
				{
					apiGroups: ["apps"]
					resources: ["deployments"]
					verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
				},
				// The executors themselves.
				{
					apiGroups: ["batch"]
					resources: ["jobs"]
					verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
				},
				// Leader election.
				{
					apiGroups: ["coordination.k8s.io"]
					resources: ["leases"]
					verbs: ["create", "get", "list", "update"]
				},
				// The CRs this operator owns. `effectiveschedules` has no CRD in
				// this release — a vestigial v1-era grant, kept for parity.
				{
					apiGroups: ["k8up.io"]
					resources: [
						"archives",
						"backups",
						"checks",
						"effectiveschedules",
						"prebackuppods",
						"prunes",
						"restores",
						"schedules",
						"snapshots",
					]
					verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
				},
				// Status and finalizer subresources for the same set.
				{
					apiGroups: ["k8up.io"]
					resources: [
						"archives/finalizers",
						"archives/status",
						"backups/finalizers",
						"backups/status",
						"checks/finalizers",
						"checks/status",
						"prebackuppods/finalizers",
						"prebackuppods/status",
						"prunes/finalizers",
						"prunes/status",
						"restores/finalizers",
						"restores/status",
						"schedules/finalizers",
						"schedules/status",
						"snapshots/finalizers",
						"snapshots/status",
					]
					verbs: ["get", "patch", "update"]
				},
				{
					apiGroups: ["k8up.io"]
					resources: ["effectiveschedules/finalizers"]
					verbs: ["update"]
				},
				// PodConfigs are read-only to the operator.
				{
					apiGroups: ["k8up.io"]
					resources: ["podconfigs"]
					verbs: ["get", "list", "watch"]
				},
				// Escalation guard: the operator may hand out k8up-executor and
				// nothing else. resourceNames scoping is what keeps `bind` from
				// being a cluster-admin escalation path.
				{
					apiGroups: ["rbac.authorization.k8s.io"]
					resources: ["clusterroles"]
					resourceNames: ["k8up-executor"]
					verbs: ["bind"]
				},
				// Bind that role into each namespace it runs an executor in.
				{
					apiGroups: ["rbac.authorization.k8s.io"]
					resources: ["rolebindings"]
					verbs: ["create", "delete", "get", "list", "update", "watch"]
				},
			]

			subjects: [{name: #config.serviceAccountName}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Executor ClusterRole — what a spawned backup Job may do
	////
	//// The operator RoleBinds this into the namespace of each executor
	//// it creates. Upstream leaves it otherwise unbound; here it also
	//// binds to the operator SA because #RoleSchema.subjects is required
	//// (see module.cue header) — which hands the operator pods/exec
	//// cluster-wide that upstream does not give it.
	/////////////////////////////////////////////////////////////////

	"executor-cluster-role": {
		res.#Role

		metadata: name: "k8up-executor"

		spec: role: {
			name:  "k8up-executor"
			scope: "cluster"

			rules: [
				// Find the pod holding the k8up.io/backupcommand annotation.
				{
					apiGroups: [""]
					resources: ["pods"]
					verbs: ["get", "list"]
				},
				// Run that command in it — e.g. a SQLite WAL checkpoint before
				// the volume is read.
				{
					apiGroups: [""]
					resources: ["pods/exec"]
					verbs: ["create", "get"]
				},
				// Sync restic snapshots back into the cluster as Snapshot CRs.
				{
					apiGroups: ["k8up.io"]
					resources: ["snapshots"]
					verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
				},
			]

			subjects: [{name: #config.serviceAccountName}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Edit / View ClusterRoles — RBAC aggregation for humans
	////
	//// Aggregation-only upstream: the labels splice these rules into the
	//// built-in admin/edit/view ClusterRoles so anyone holding those can
	//// work with k8up.io resources. The binding to the operator SA is this
	//// module's forced deviation, not upstream intent.
	/////////////////////////////////////////////////////////////////

	"edit-cluster-role": {
		res.#Role

		metadata: {
			name: "k8up-edit"
			labels: {
				"rbac.authorization.k8s.io/aggregate-to-admin": "true"
				"rbac.authorization.k8s.io/aggregate-to-edit":  "true"
			}
		}

		spec: role: {
			name:  "k8up-edit"
			scope: "cluster"

			rules: [{
				apiGroups: ["k8up.io"]
				resources: ["*"]
				verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
			}]

			subjects: [{name: #config.serviceAccountName}]
		}
	}

	"view-cluster-role": {
		res.#Role

		metadata: {
			name: "k8up-view"
			labels: "rbac.authorization.k8s.io/aggregate-to-view": "true"
		}

		spec: role: {
			name:  "k8up-view"
			scope: "cluster"

			rules: [{
				apiGroups: ["k8up.io"]
				resources: ["*"]
				verbs: ["get", "list", "watch"]
			}]

			subjects: [{name: #config.serviceAccountName}]
		}
	}
}
