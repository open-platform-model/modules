// Components for the Altinity ClickHouse operator module.
//
//   crds                  — 4 CRDs (CHI, CHIT, CHOP, CHK)
//   operator              — controller Deployment (operator + metrics-exporter sidecar)
//   operator-cluster-role — ClusterRole granting CR reconciliation + workload CRUD
package clickhouse_operator

import (
	resources_extension "opmodel.dev/opm/v1alpha1/resources/extension@v1"
	resources_security "opmodel.dev/opm/v1alpha1/resources/security@v1"
	resources_workload "opmodel.dev/opm/v1alpha1/resources/workload@v1"
	traits_network "opmodel.dev/opm/v1alpha1/traits/network@v1"
	traits_security "opmodel.dev/opm/v1alpha1/traits/security@v1"
	traits_workload "opmodel.dev/opm/v1alpha1/traits/workload@v1"
)

#components: {

	/////////////////////////////////////////////////////////////////
	//// CRDs
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
	//// Operator — controller Deployment with metrics-exporter sidecar
	/////////////////////////////////////////////////////////////////

	operator: {
		resources_workload.#Container
		traits_workload.#Scaling
		traits_workload.#RestartPolicy
		traits_workload.#UpdateStrategy
		traits_workload.#GracefulShutdown
		traits_workload.#SidecarContainers
		traits_security.#SecurityContext
		traits_security.#WorkloadIdentity
		traits_network.#Expose

		metadata: {
			name: "operator"
			labels: "core.opmodel.dev/workload-type": "stateless"
		}

		spec: {
			scaling: count: #config.replicas

			restartPolicy: "Always"

			updateStrategy: type: "RollingUpdate"

			gracefulShutdown: terminationGracePeriodSeconds: 30

			workloadIdentity: {
				name:           "clickhouse-operator"
				automountToken: true
			}

			container: {
				name: "clickhouse-operator"
				image: {
					repository: #config.image.repository
					tag:        #config.image.tag
					digest:     #config.image.digest
					pullPolicy: #config.image.pullPolicy
				}

				env: {
					OPERATOR_POD_NAMESPACE: {
						name: "OPERATOR_POD_NAMESPACE"
						fieldRef: fieldPath: "metadata.namespace"
					}
					OPERATOR_POD_NAME: {
						name: "OPERATOR_POD_NAME"
						fieldRef: fieldPath: "metadata.name"
					}
					OPERATOR_POD_IP: {
						name: "OPERATOR_POD_IP"
						fieldRef: fieldPath: "status.podIP"
					}
					OPERATOR_POD_SERVICE_ACCOUNT: {
						name: "OPERATOR_POD_SERVICE_ACCOUNT"
						fieldRef: fieldPath: "spec.serviceAccountName"
					}
					// When operator runs outside kube-system, Altinity default watches
					// only its own namespace. Force watch-all by setting WATCH_NAMESPACES
					// to a regexp matching every namespace — the informer factory then
					// uses NamespaceAll (>1 include entry with non-label char falls
					// through to NamespaceAll in GetInformerNamespace).
					WATCH_NAMESPACES: {
						name:  "WATCH_NAMESPACES"
						value: #config.watchNamespaces
					}
				}

				if #config.resources != _|_ {
					resources: #config.resources
				}
			}

			sidecarContainers: [{
				name: "metrics-exporter"
				image: {
					repository: #config.metricsImage.repository
					tag:        #config.metricsImage.tag
					digest:     #config.metricsImage.digest
					pullPolicy: #config.metricsImage.pullPolicy
				}
				ports: {
					metrics: {
						name:       "metrics"
						targetPort: #config.metricsPort
						protocol:   "TCP"
					}
				}
				if #config.metricsResources != _|_ {
					resources: #config.metricsResources
				}
			}]

			expose: {
				ports: {
					metrics: {
						name:        "metrics"
						targetPort:  #config.metricsPort
						exposedPort: #config.metricsPort
						protocol:    "TCP"
					}
				}
				type: "ClusterIP"
			}

			securityContext: {
				runAsNonRoot:             false
				readOnlyRootFilesystem:   false
				allowPrivilegeEscalation: false
				capabilities: drop: ["ALL"]
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Operator ClusterRole
	////
	//// Full control over StatefulSets/Pods/Services/ConfigMaps/Secrets/PVCs/PDBs
	//// and reconciliation rights over all 4 Altinity CRDs.
	/////////////////////////////////////////////////////////////////

	"operator-cluster-role": {
		resources_security.#Role

		metadata: name: "clickhouse-operator"

		spec: role: {
			name:  "clickhouse-operator"
			scope: "cluster"

			rules: [
				{
					apiGroups: [""]
					resources: ["configmaps", "services", "persistentvolumeclaims", "secrets"]
					verbs: ["get", "list", "patch", "update", "watch", "create", "delete"]
				},
				{
					apiGroups: [""]
					resources: ["endpoints"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: [""]
					resources: ["events"]
					verbs: ["create"]
				},
				{
					apiGroups: [""]
					resources: ["persistentvolumes"]
					verbs: ["get", "list", "patch", "update", "watch"]
				},
				{
					apiGroups: [""]
					resources: ["pods"]
					verbs: ["get", "list", "patch", "update", "watch", "delete"]
				},
				{
					apiGroups: ["apps"]
					resources: ["statefulsets"]
					verbs: ["get", "list", "patch", "update", "watch", "create", "delete"]
				},
				{
					apiGroups: ["apps"]
					resources: ["replicasets"]
					verbs: ["get", "patch", "update", "delete"]
				},
				// The operator self-labels its own Deployment at startup.
				{
					apiGroups: ["apps"]
					resources: ["deployments"]
					verbs: ["get", "list", "patch", "update", "watch"]
				},
				{
					apiGroups: ["policy"]
					resources: ["poddisruptionbudgets"]
					verbs: ["get", "list", "patch", "update", "watch", "create", "delete"]
				},
				{
					apiGroups: ["discovery.k8s.io"]
					resources: ["endpointslices"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: ["apiextensions.k8s.io"]
					resources: ["customresourcedefinitions"]
					verbs: ["get", "list"]
				},
				{
					apiGroups: ["clickhouse.altinity.com"]
					resources: ["clickhouseinstallations"]
					verbs: ["get", "list", "watch", "patch", "update", "delete"]
				},
				{
					apiGroups: ["clickhouse.altinity.com"]
					resources: [
						"clickhouseinstallationtemplates",
						"clickhouseoperatorconfigurations",
					]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: ["clickhouse.altinity.com"]
					resources: [
						"clickhouseinstallations/finalizers",
						"clickhouseinstallationtemplates/finalizers",
						"clickhouseoperatorconfigurations/finalizers",
					]
					verbs: ["update"]
				},
				{
					apiGroups: ["clickhouse.altinity.com"]
					resources: [
						"clickhouseinstallations/status",
						"clickhouseinstallationtemplates/status",
						"clickhouseoperatorconfigurations/status",
					]
					verbs: ["get", "update", "patch", "create", "delete"]
				},
				{
					apiGroups: ["clickhouse-keeper.altinity.com"]
					resources: ["clickhousekeeperinstallations"]
					verbs: ["get", "list", "watch", "patch", "update", "delete"]
				},
				{
					apiGroups: ["clickhouse-keeper.altinity.com"]
					resources: ["clickhousekeeperinstallations/finalizers"]
					verbs: ["update"]
				},
				{
					apiGroups: ["clickhouse-keeper.altinity.com"]
					resources: ["clickhousekeeperinstallations/status"]
					verbs: ["get", "update", "patch", "create", "delete"]
				},
			]

			subjects: [{name: "clickhouse-operator"}]
		}
	}
}
