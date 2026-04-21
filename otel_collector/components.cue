// Components for the OpenTelemetry operator module.
//
//   crds                           — 3 CRDs (OpenTelemetryCollector, Instrumentation, OpAMPBridge)
//   operator                       — controller Deployment
//   operator-cluster-role          — ClusterRole granting OTEL CR + workload CRUD
//   leader-election-role           — namespace Role for leader election
package otel_collector

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
	//// Operator — controller Deployment
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
			labels: "core.opmodel.dev/workload-type": "stateless"
		}

		spec: {
			scaling: count: #config.replicas

			restartPolicy: "Always"

			updateStrategy: type: "RollingUpdate"

			gracefulShutdown: terminationGracePeriodSeconds: 10

			workloadIdentity: {
				name:           "opentelemetry-operator"
				automountToken: true
			}

			container: {
				name: "manager"
				image: {
					repository: #config.image.repository
					tag:        #config.image.tag
					digest:     #config.image.digest
					pullPolicy: #config.image.pullPolicy
				}

				args: [
					"--zap-log-level=\(#config.logLevel)",
					"--zap-time-encoding=rfc3339nano",
				]

				env: {
					SERVICE_ACCOUNT_NAME: {
						name: "SERVICE_ACCOUNT_NAME"
						fieldRef: fieldPath: "spec.serviceAccountName"
					}
					NAMESPACE: {
						name: "NAMESPACE"
						fieldRef: fieldPath: "metadata.namespace"
					}
					METRICS_ADDR: {
						name:  "METRICS_ADDR"
						value: ":\(#config.metricsPort)"
					}
					METRICS_SECURE: {name: "METRICS_SECURE", value: "true"}
					ENABLE_LEADER_ELECTION: {name: "ENABLE_LEADER_ELECTION", value: "true"}
					ENABLE_NGINX_AUTO_INSTRUMENTATION: {
						name:  "ENABLE_NGINX_AUTO_INSTRUMENTATION"
						value: "\(#config.enableNginxAutoInstrumentation)"
					}
					ENABLE_WEBHOOKS: {
						name:  "ENABLE_WEBHOOKS"
						value: "\(#config.enableWebhooks)"
					}
				}

				ports: {
					https: {
						name:       "https"
						targetPort: #config.metricsPort
						protocol:   "TCP"
					}
				}

				livenessProbe: {
					httpGet: {
						path: "/healthz"
						port: #config.probePort
					}
					initialDelaySeconds: 15
					periodSeconds:       20
				}

				readinessProbe: {
					httpGet: {
						path: "/readyz"
						port: #config.probePort
					}
					initialDelaySeconds: 5
					periodSeconds:       10
				}

				if #config.resources != _|_ {
					resources: #config.resources
				}
			}

			expose: {
				ports: {
					https: {
						name:        "https"
						targetPort:  #config.metricsPort
						exposedPort: #config.metricsPort
						protocol:    "TCP"
					}
				}
				type: "ClusterIP"
			}

			securityContext: {
				runAsNonRoot:             true
				readOnlyRootFilesystem:   true
				allowPrivilegeEscalation: false
				capabilities: drop: ["ALL"]
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Operator ClusterRole
	////
	//// Manages OTEL CRs (OpenTelemetryCollector, Instrumentation,
	//// OpAMPBridge, TargetAllocator) plus the workloads they spawn.
	/////////////////////////////////////////////////////////////////

	"operator-cluster-role": {
		resources_security.#Role

		metadata: name: "opentelemetry-operator-manager"

		spec: role: {
			name:  "opentelemetry-operator-manager"
			scope: "cluster"

			rules: [
				{
					apiGroups: [""]
					resources: ["configmaps", "pods", "serviceaccounts", "services"]
					verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
				},
				{
					apiGroups: [""]
					resources: ["namespaces", "secrets"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: ["", "events.k8s.io"]
					resources: ["events"]
					verbs: ["create", "patch"]
				},
				{
					apiGroups: ["apps"]
					resources: ["daemonsets", "deployments", "statefulsets"]
					verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
				},
				{
					apiGroups: ["apps"]
					resources: ["deployments/finalizers"]
					verbs: ["get", "patch", "update", "watch"]
				},
				{
					apiGroups: ["apps"]
					resources: ["replicasets"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: ["autoscaling"]
					resources: ["horizontalpodautoscalers"]
					verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
				},
				{
					apiGroups: ["batch"]
					resources: ["jobs"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: ["coordination.k8s.io"]
					resources: ["leases"]
					verbs: ["create", "get", "list", "update"]
				},
				{
					apiGroups: ["discovery.k8s.io"]
					resources: ["endpointslices"]
					verbs: ["get", "list"]
				},
				{
					apiGroups: ["gateway.networking.k8s.io"]
					resources: ["httproutes"]
					verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
				},
				{
					apiGroups: ["monitoring.coreos.com"]
					resources: ["podmonitors", "servicemonitors"]
					verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
				},
				{
					apiGroups: ["networking.k8s.io"]
					resources: ["ingresses", "networkpolicies"]
					verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
				},
				{
					apiGroups: ["opentelemetry.io"]
					resources: [
						"instrumentations",
						"opampbridges",
						"opentelemetrycollectors",
						"targetallocators",
						"targetallocators/finalizers",
					]
					verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
				},
				{
					apiGroups: ["opentelemetry.io"]
					resources: ["opampbridges/finalizers"]
					verbs: ["update"]
				},
				{
					apiGroups: ["opentelemetry.io"]
					resources: [
						"opampbridges/status",
						"opentelemetrycollectors/finalizers",
						"opentelemetrycollectors/status",
						"targetallocators/status",
					]
					verbs: ["get", "patch", "update"]
				},
				{
					apiGroups: ["policy"]
					resources: ["poddisruptionbudgets"]
					verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
				},
				{
					apiGroups: ["rbac.authorization.k8s.io"]
					resources: ["clusterrolebindings", "clusterroles"]
					verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
				},
			]

			subjects: [{name: "opentelemetry-operator"}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Leader Election Role — namespace Role
	/////////////////////////////////////////////////////////////////

	"leader-election-role": {
		resources_security.#Role

		metadata: name: "opentelemetry-operator-leader-election"

		spec: role: {
			name:  "opentelemetry-operator-leader-election"
			scope: "namespace"

			rules: [
				{
					apiGroups: ["coordination.k8s.io"]
					resources: ["leases"]
					verbs: ["get", "create", "update", "list", "watch", "delete"]
				},
				{
					apiGroups: [""]
					resources: ["configmaps"]
					verbs: ["get", "create", "update", "list", "watch", "delete"]
				},
				{
					apiGroups: [""]
					resources: ["events"]
					verbs: ["create", "patch"]
				},
			]

			subjects: [{name: "opentelemetry-operator"}]
		}
	}
}
