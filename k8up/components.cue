// Components for the K8up backup operator module.
//
// Components (plus conditional monitoring from monitoring.cue):
//   crds                  — all 9 K8up CustomResourceDefinition objects
//   operator              — K8up operator Deployment with metrics Expose
//   (ServiceAccount is auto-created by the Deployment workloadIdentity transformer)
//   manager-cluster-role  — ClusterRole for the operator manager (with SA subject)
//   executor-cluster-role — ClusterRole for backup job executors
//   edit-cluster-role     — aggregate ClusterRole for k8up.io resources (admin+edit)
//   view-cluster-role     — aggregate ClusterRole for k8up.io resources (view)
package k8up

import (
	resources_extension "opmodel.dev/opm/v1alpha1/resources/extension@v1"
	resources_security "opmodel.dev/opm/v1alpha1/resources/security@v1"
	resources_workload "opmodel.dev/opm/v1alpha1/resources/workload@v1"
	traits_network "opmodel.dev/opm/v1alpha1/traits/network@v1"
	traits_security "opmodel.dev/opm/v1alpha1/traits/security@v1"
	traits_workload "opmodel.dev/opm/v1alpha1/traits/workload@v1"
)

// _serviceAccountName resolves the effective service account name.
// When the operator config leaves name blank the conventional name "k8up" is used.
let _serviceAccountName = {
	if #config.serviceAccount.name == "" {"k8up"}
	if #config.serviceAccount.name != "" {#config.serviceAccount.name}
}

#components: {

	/////////////////////////////////////////////////////////////////
	//// CRDs — K8up CustomResourceDefinitions
	////
	//// Installs all 9 K8up CRDs so the cluster accepts Archive,
	//// Backup, Check, PreBackupPod, Prune, Restore, Schedule,
	//// Snapshot, and PodConfig resources.
	//// The simplified schema (x-kubernetes-preserve-unknown-fields)
	//// is sourced from crds_data.cue — no manual transcription needed.
	/////////////////////////////////////////////////////////////////

	crds: {
		resources_extension.#CRDs

		spec: crds: {
			for crdName, raw in #crds {
				(crdName): {
					group: raw.spec.group
					names: {
						kind:   raw.spec.names.kind
						plural: raw.spec.names.plural
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
	//// Watches all K8up CRs cluster-wide (or per namespace if
	//// operatorNamespace is set) and spawns Job/Pod executors.
	//// Exposes Prometheus metrics on the configured port.
	/////////////////////////////////////////////////////////////////

	operator: {
		resources_workload.#Container
		traits_workload.#Scaling
		traits_workload.#RestartPolicy
		traits_workload.#UpdateStrategy
		traits_workload.#GracefulShutdown
		traits_security.#SecurityContext
		traits_security.#WorkloadIdentity
		traits_network.#Expose

		metadata: {
			name: "operator"
			labels: {
				"core.opmodel.dev/workload-type": "stateless"
			}
		}

		spec: {
			scaling: count: #config.replicas

			restartPolicy: "Always"

			updateStrategy: type: "RollingUpdate"

			gracefulShutdown: terminationGracePeriodSeconds: 30

			// ServiceAccount that grants the operator cluster-wide RBAC.
			workloadIdentity: {
				name:           _serviceAccountName
				automountToken: true
			}

			container: {
				name: "operator"
				image: {
					repository: #config.image.repository
					tag:        #config.image.tag
					digest:     #config.image.digest
					pullPolicy: #config.image.pullPolicy
				}

				// K8up binary requires "operator" subcommand to start the controller.
				args: ["operator"]

				env: {
					// Operator's own namespace — used for leader-election lease objects.
					OPERATOR_NAMESPACE: {
						name: "OPERATOR_NAMESPACE"
						fieldRef: fieldPath: "metadata.namespace"
					}

					// Operator's pod name — required for leader-election identity.
					OPERATOR_NAME: {
						name: "OPERATOR_NAME"
						fieldRef: fieldPath: "metadata.name"
					}

					// Leader election keeps a single active replica when replicas > 1.
					BACKUP_ENABLE_LEADER_ELECTION: {
						name:  "BACKUP_ENABLE_LEADER_ELECTION"
						value: "\(#config.enableLeaderElection)"
					}

					// Skip backup resources that lack the k8up annotation.
					BACKUP_SKIP_WITHOUT_ANNOTATION: {
						name:  "BACKUP_SKIP_WITHOUT_ANNOTATION"
						value: "\(#config.skipWithoutAnnotation)"
					}

					// Restrict watch scope; empty string means cluster-wide.
					BACKUP_OPERATOR_NAMESPACE: {
						name:  "BACKUP_OPERATOR_NAMESPACE"
						value: #config.operatorNamespace
					}

					// Metrics HTTP server port.
					BACKUP_METRICS_PORT: {
						name:  "BACKUP_METRICS_PORT"
						value: "\(#config.metrics.port)"
					}

					// Global resource defaults for spawned backup Jobs.
					if #config.globalResources.requests.cpu != "" {
						BACKUP_GLOBAL_CPU_REQUEST: {
							name:  "BACKUP_GLOBAL_CPU_REQUEST"
							value: #config.globalResources.requests.cpu
						}
					}
					if #config.globalResources.requests.memory != "" {
						BACKUP_GLOBAL_MEMORY_REQUEST: {
							name:  "BACKUP_GLOBAL_MEMORY_REQUEST"
							value: #config.globalResources.requests.memory
						}
					}
					if #config.globalResources.limits.cpu != "" {
						BACKUP_GLOBAL_CPU_LIMIT: {
							name:  "BACKUP_GLOBAL_CPU_LIMIT"
							value: #config.globalResources.limits.cpu
						}
					}
					if #config.globalResources.limits.memory != "" {
						BACKUP_GLOBAL_MEMORY_LIMIT: {
							name:  "BACKUP_GLOBAL_MEMORY_LIMIT"
							value: #config.globalResources.limits.memory
						}
					}

					// Timezone for cron schedule parsing.
					if #config.timezone != "" {
						TZ: {
							name:  "TZ"
							value: #config.timezone
						}
					}
				}

				ports: {
					metrics: {
						name:       "metrics"
						targetPort: #config.metrics.port
						protocol:   "TCP"
					}
				}

				// Liveness probe: operator is alive if its metrics HTTP server responds.
				livenessProbe: {
					httpGet: {
						path: "/metrics"
						port: #config.metrics.port
					}
					initialDelaySeconds: 30
					periodSeconds:       10
					failureThreshold:    6
				}

				if #config.resources != _|_ {
					resources: #config.resources
				}
			}

			// Expose the metrics port as a ClusterIP Service so Prometheus
			// (and ServiceMonitor) can scrape it without NodePort access.
			expose: {
				ports: {
					metrics: container.ports.metrics & {
						exposedPort: #config.metrics.port
					}
				}
				type: #config.metrics.serviceType
			}

			// Security context: non-root, read-only filesystem, drop all caps.
			securityContext: {
				runAsNonRoot:             true
				readOnlyRootFilesystem:   true
				allowPrivilegeEscalation: false
				capabilities: drop: ["ALL"]
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Manager ClusterRole — full operator permissions
	////
	//// Grants the operator permission to manage all K8up CRs,
	//// spawn Jobs/Pods, watch namespaces/secrets/PVCs, and emit
	//// events. Bound to the operator's service account via
	//// managerClusterRoleBinding.
	/////////////////////////////////////////////////////////////////

	"manager-cluster-role": {
		resources_security.#Role

		metadata: name: "k8up-manager"

		spec: role: {
			name:  "k8up-manager"
			scope: "cluster"

			rules: [
				// Manage K8up backup CRs and their status subresources.
				{
					apiGroups: ["k8up.io"]
					resources: [
						"archives",
						"archives/status",
						"backups",
						"backups/status",
						"checks",
						"checks/status",
						"prebackuppods",
						"prebackuppods/status",
						"prunes",
						"prunes/status",
						"restores",
						"restores/status",
						"schedules",
						"schedules/status",
						"snapshots",
						"snapshots/status",
						"podconfigs",
						"podconfigs/status",
					]
					verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
				},
				// Create and manage backup executor Jobs and Pods.
				{
					apiGroups: ["batch"]
					resources: ["jobs"]
					verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
				},
				// Watch Pods spawned by backup Jobs to track completion.
				{
					apiGroups: [""]
					resources: ["pods"]
					verbs: ["get", "list", "watch"]
				},
				// Watch PersistentVolumeClaims to discover backup targets.
				{
					apiGroups: [""]
					resources: ["persistentvolumeclaims"]
					verbs: ["get", "list", "watch"]
				},
				// Read Secrets referenced by Repository CRs (restic credentials).
				{
					apiGroups: [""]
					resources: ["secrets"]
					verbs: ["get", "list", "watch"]
				},
				// Watch Namespaces for cluster-wide operator mode.
				{
					apiGroups: [""]
					resources: ["namespaces"]
					verbs: ["get", "list", "watch"]
				},
				// Emit Kubernetes events for backup progress and failures.
				{
					apiGroups: [""]
					resources: ["events"]
					verbs: ["create", "patch"]
				},
				// Manage ServiceAccounts for backup executor Pods.
				{
					apiGroups: [""]
					resources: ["serviceaccounts"]
					verbs: ["create", "delete", "get", "list", "watch"]
				},
				// Manage leader-election lease objects.
				{
					apiGroups: ["coordination.k8s.io"]
					resources: ["leases"]
					verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
				},
				// Manage Roles and RoleBindings for per-namespace executor access.
				{
					apiGroups: ["rbac.authorization.k8s.io"]
					resources: ["roles", "rolebindings"]
					verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
				},
				// Bind the k8up-executor ClusterRole.
				{
					apiGroups: ["rbac.authorization.k8s.io"]
					resources: ["clusterroles"]
					verbs: ["bind"]
				},
				// Manage Deployments for PreBackupPod runners.
				{
					apiGroups: ["apps"]
					resources: ["deployments"]
					verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
				},
			]

			subjects: [{name: _serviceAccountName}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Executor ClusterRole — permissions for spawned backup Jobs
	////
	//// Executor Pods need to mount PVCs, read Secrets, and write
	//// status back to K8up CRs. Bound at runtime by the operator
	//// to the service account it uses for each executor Job.
	/////////////////////////////////////////////////////////////////

	"executor-cluster-role": {
		resources_security.#Role

		metadata: name: "k8up-executor"

		spec: role: {
			name:  "k8up-executor"
			scope: "cluster"

			rules: [
				// Read and update status on the owning K8up CR.
				{
					apiGroups: ["k8up.io"]
					resources: [
						"archives/status",
						"backups/status",
						"checks/status",
						"prunes/status",
						"restores/status",
					]
					verbs: ["get", "patch", "update"]
				},
				// Create and manage Snapshot objects (synced from restic after backup).
				{
					apiGroups: ["k8up.io"]
					resources: ["snapshots"]
					verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
				},
				// List Pods to discover PreBackupPod-annotated pods (k8up.io/backupcommand).
				{
					apiGroups: [""]
					resources: ["pods"]
					verbs: ["get", "list"]
				},
				// Exec into PreBackupPod containers to run backup commands (e.g. SQLite WAL checkpoint).
				{
					apiGroups: [""]
					resources: ["pods/exec"]
					verbs: ["create", "get"]
				},
				// Read PVCs to mount backup sources.
				{
					apiGroups: [""]
					resources: ["persistentvolumeclaims"]
					verbs: ["get", "list"]
				},
				// Read Secrets for restic repository credentials.
				{
					apiGroups: [""]
					resources: ["secrets"]
					verbs: ["get"]
				},
				// Bind this role (required for the operator to create executor RoleBindings).
				{
					apiGroups: ["rbac.authorization.k8s.io"]
					resources: ["clusterrolebindings"]
					verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
				},
			]

			subjects: [{name: _serviceAccountName}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Edit ClusterRole — RBAC aggregation for k8up resources
	////
	//// Aggregates into the built-in admin and edit ClusterRoles,
	//// allowing users with cluster-admin or namespace edit permissions
	//// to create and manage all K8up resources without explicit binding.
	/////////////////////////////////////////////////////////////////

	"edit-cluster-role": {
		resources_security.#Role

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

			rules: [
				// Full read/write access to all k8up.io resources.
				{
					apiGroups: ["k8up.io"]
					resources: ["*"]
					verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
				},
			]

			subjects: [{name: _serviceAccountName}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// View ClusterRole — RBAC aggregation for k8up resources
	////
	//// Aggregates into the built-in view ClusterRole, allowing users
	//// with view permissions to read all K8up resources (backups,
	//// schedules, snapshots, etc.) without explicit binding.
	/////////////////////////////////////////////////////////////////

	"view-cluster-role": {
		resources_security.#Role

		metadata: {
			name: "k8up-view"
			labels: {
				"rbac.authorization.k8s.io/aggregate-to-view": "true"
			}
		}

		spec: role: {
			name:  "k8up-view"
			scope: "cluster"

			rules: [
				// Read-only access to all k8up.io resources.
				{
					apiGroups: ["k8up.io"]
					resources: ["*"]
					verbs: ["get", "list", "watch"]
				},
			]

			subjects: [{name: _serviceAccountName}]
		}
	}

}
