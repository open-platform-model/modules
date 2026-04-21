// Components for the MongoDB Community operator module.
//
//   crds                      — MongoDBCommunity CustomResourceDefinition
//   operator                  — controller Deployment (ServiceAccount auto-created via workloadIdentity)
//   operator-cluster-role     — ClusterRole: manages StatefulSets, Pods, Services, Secrets, ConfigMaps + MongoDBCommunity CRs
//   service-binding-role      — ClusterRole: read-only access for Service Binding spec consumers
package mongodb_operator

import (
	resources_extension "opmodel.dev/opm/v1alpha1/resources/extension@v1"
	resources_security "opmodel.dev/opm/v1alpha1/resources/security@v1"
	resources_workload "opmodel.dev/opm/v1alpha1/resources/workload@v1"
	traits_security "opmodel.dev/opm/v1alpha1/traits/security@v1"
	traits_workload "opmodel.dev/opm/v1alpha1/traits/workload@v1"
)

#components: {

	/////////////////////////////////////////////////////////////////
	//// CRDs — MongoDB Community CustomResourceDefinition
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
	//// Operator — MongoDB Community controller (Deployment)
	////
	//// Watches MongoDBCommunity CRs and reconciles replica set state
	//// via StatefulSets, Services, and agent containers.
	/////////////////////////////////////////////////////////////////

	operator: {
		resources_workload.#Container
		traits_workload.#Scaling
		traits_workload.#RestartPolicy
		traits_workload.#UpdateStrategy
		traits_workload.#GracefulShutdown
		traits_security.#SecurityContext
		traits_security.#WorkloadIdentity

		metadata: {
			name: "operator"
			labels: "core.opmodel.dev/workload-type": "stateless"
		}

		spec: {
			scaling: count: #config.replicas

			restartPolicy: "Always"

			updateStrategy: type: "RollingUpdate"

			gracefulShutdown: terminationGracePeriodSeconds: 10

			workloadIdentity: {
				name:           "mongodb-kubernetes-operator"
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

				command: ["/usr/local/bin/mongodb-kubernetes-operator"]
				args: ["-watch-resource=mongodbcommunity"]

				env: {
					OPERATOR_ENV: {name: "OPERATOR_ENV", value: "prod"}
					WATCH_NAMESPACE: {
						name:  "WATCH_NAMESPACE"
						value: #config.watchNamespace
					}
					NAMESPACE: {
						name: "NAMESPACE"
						fieldRef: fieldPath: "metadata.namespace"
					}
					POD_NAME: {
						name: "POD_NAME"
						fieldRef: fieldPath: "metadata.name"
					}
					OPERATOR_NAME: {
						name:  "OPERATOR_NAME"
						value: "mongodb-kubernetes-operator"
					}
					AGENT_IMAGE: {
						name:  "AGENT_IMAGE"
						value: "\(#config.agentImage.repository):\(#config.agentImage.tag)"
					}
					MDB_AGENT_IMAGE_REPOSITORY: {
						name:  "MDB_AGENT_IMAGE_REPOSITORY"
						value: #config.agentImage.repository
					}
					MONGODB_IMAGE: {
						name:  "MONGODB_IMAGE"
						value: #config.mongodbImage
					}
					MONGODB_REPO_URL: {
						name:  "MONGODB_REPO_URL"
						value: #config.mongodbRepo
					}
					MDB_COMMUNITY_IMAGE: {
						name:  "MDB_COMMUNITY_IMAGE"
						value: #config.mongodbImage
					}
					MDB_COMMUNITY_REPO_URL: {
						name:  "MDB_COMMUNITY_REPO_URL"
						value: #config.mongodbRepo
					}
					MDB_COMMUNITY_IMAGE_TYPE: {
						name:  "MDB_COMMUNITY_IMAGE_TYPE"
						value: "ubi8"
					}
					MDB_COMMUNITY_AGENT_IMAGE: {
						name:  "MDB_COMMUNITY_AGENT_IMAGE"
						value: "\(#config.agentImage.repository):\(#config.agentImage.tag)"
					}
					VERSION_UPGRADE_HOOK_IMAGE: {
						name:  "VERSION_UPGRADE_HOOK_IMAGE"
						value: "\(#config.versionUpgradeHookImage.repository):\(#config.versionUpgradeHookImage.tag)"
					}
					READINESS_PROBE_IMAGE: {
						name:  "READINESS_PROBE_IMAGE"
						value: "\(#config.readinessProbeImage.repository):\(#config.readinessProbeImage.tag)"
					}
					// MANAGED_SECURITY_CONTEXT=true skips runAsUser/fsGroup wiring on the
					// managed StatefulSet, which lets the mongod + agent containers
					// run as unrelated UIDs and break the shared keyfile volume
					// ("keyfile: bad file"). Only flip to true on OpenShift-style
					// platforms that assign UIDs out of band.
					MANAGED_SECURITY_CONTEXT: {name: "MANAGED_SECURITY_CONTEXT", value: "false"}
					MDB_WEBHOOK_REGISTER_CONFIGURATION: {name: "MDB_WEBHOOK_REGISTER_CONFIGURATION", value: "false"}
					MDB_DEFAULT_ARCHITECTURE: {name: "MDB_DEFAULT_ARCHITECTURE", value: "non-static"}
				}

				if #config.resources != _|_ {
					resources: #config.resources
				}
			}

			securityContext: {
				runAsNonRoot:             true
				readOnlyRootFilesystem:   false
				allowPrivilegeEscalation: false
				capabilities: drop: ["ALL"]
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Operator ClusterRole
	////
	//// Full control over StatefulSets/Pods/Secrets/Services/ConfigMaps
	//// plus MongoDBCommunity CR reconciliation rights.
	/////////////////////////////////////////////////////////////////

	"operator-cluster-role": {
		resources_security.#Role

		metadata: name: "mongodb-kubernetes-operator"

		spec: role: {
			name:  "mongodb-kubernetes-operator"
			scope: "cluster"

			rules: [
				{
					apiGroups: [""]
					resources: ["services", "configmaps", "secrets"]
					verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
				},
				{
					apiGroups: ["apps"]
					resources: ["statefulsets"]
					verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
				},
				{
					apiGroups: [""]
					resources: ["pods"]
					verbs: ["delete", "get", "list", "patch", "update", "watch"]
				},
				{
					apiGroups: ["mongodbcommunity.mongodb.com"]
					resources: [
						"mongodbcommunity",
						"mongodbcommunity/status",
						"mongodbcommunity/spec",
						"mongodbcommunity/finalizers",
					]
					verbs: ["get", "patch", "list", "update", "watch"]
				},
				// Stub informer watches — the unified MongoDB operator sets up
				// informers for all enterprise kinds at startup. list/watch is
				// enough; we never reconcile these (the reconciler is scoped to
				// MongoDBCommunity via the `-watch-resource` arg).
				{
					apiGroups: ["mongodb.com"]
					resources: [
						"mongodb",
						"opsmanagers",
						"mongodbusers",
						"mongodbmulticluster",
						"mongodbsearch",
						"clustermongodbroles",
					]
					verbs: ["get", "list", "watch"]
				},
			]

			subjects: [{name: "mongodb-kubernetes-operator"}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Service-Binding ClusterRole
	////
	//// Read-only access for Service Binding Spec consumers (apps that
	//// consume connection strings exposed by the operator-generated Secret).
	/////////////////////////////////////////////////////////////////

	"service-binding-role": {
		resources_security.#Role

		metadata: {
			name: "mongodb-kubernetes-operator-service-binding"
			labels: "servicebinding.io/controller": "true"
		}

		spec: role: {
			name:  "mongodb-kubernetes-operator-service-binding"
			scope: "cluster"

			rules: [
				{
					apiGroups: ["mongodbcommunity.mongodb.com"]
					resources: ["mongodbcommunity", "mongodbcommunity/status"]
					verbs: ["get", "list", "watch"]
				},
			]

			subjects: [{name: "mongodb-kubernetes-operator"}]
		}
	}
}
