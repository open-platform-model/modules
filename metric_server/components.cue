// Components for the metrics-server module.
//
// Components:
//   server              — metrics-server Deployment (single container, HTTPS on 10250)
//   rbac                — ClusterRole + ClusterRoleBinding (system:metrics-server)
//   rbac-auth-delegator — ClusterRole + ClusterRoleBinding (API auth delegation)
//   rbac-auth-reader    — Role + RoleBinding (extension-apiserver-authentication ConfigMap)
//
// Post-deploy manual steps (OPM catalog does not yet support these resource types):
//
//   1. APIService (v1beta1.metrics.k8s.io) — registers the metrics API with the
//      Kubernetes API aggregation layer. Without this, `kubectl top` and HPA will
//      not work. Apply from the upstream manifest:
//        kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.8.1/components.yaml
//      Only the APIService resource from that manifest is needed.
//
//   2. system:aggregated-metrics-reader ClusterRole — aggregated into admin/edit/view
//      via RBAC label selectors. Allows cluster users to run `kubectl top`.
//
// Items 1–2 are included in the upstream components.yaml referenced above.
package metric_server

import (
	"list"

	resources_security "opmodel.dev/opm/v1alpha1/resources/security@v1"
	resources_storage  "opmodel.dev/opm/v1alpha1/resources/storage@v1"
	resources_workload "opmodel.dev/opm/v1alpha1/resources/workload@v1"
	traits_security    "opmodel.dev/opm/v1alpha1/traits/security@v1"
	traits_workload    "opmodel.dev/opm/v1alpha1/traits/workload@v1"
)

// _baseArgs holds the always-present metrics-server arguments.
_baseArgs: [
	"--cert-dir=/tmp",
	"--secure-port=10250",
	"--kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname",
	"--kubelet-use-node-status-port",
	"--metric-resolution=\(#config.metricResolution)",
]

// _tlsArgs is appended to _baseArgs when kubeletInsecureTLS is enabled.
_tlsArgs: *[] | ["--kubelet-insecure-tls"]
if #config.kubeletInsecureTLS {
	_tlsArgs: ["--kubelet-insecure-tls"]
}

#components: {

	/////////////////////////////////////////////////////////////////
	//// Server — metrics-server Deployment
	////
	//// Scrapes kubelet summary API on each node and exposes the
	//// aggregated metrics via the Kubernetes metrics.k8s.io API.
	////
	//// Runs as non-root UID 1000 with a read-only root filesystem.
	//// /tmp is an emptyDir for auto-generated self-signed TLS certs.
	////
	//// Replica count is driven by #config.replicas.
	//// HA mode (ha: true) should pair with replicas: 2+ and schedules
	//// pods with anti-affinity to spread across nodes.
	/////////////////////////////////////////////////////////////////

	server: {
		resources_workload.#Container
		resources_storage.#Volumes
		traits_workload.#Scaling
		traits_workload.#RestartPolicy
		traits_workload.#UpdateStrategy
		traits_workload.#GracefulShutdown
		traits_security.#SecurityContext
		traits_security.#WorkloadIdentity

		metadata: {
			name: "server"
			labels: {
				"core.opmodel.dev/workload-type": "stateless"
			}
		}

		spec: {
			scaling: count: #config.replicas

			restartPolicy: "Always"

			updateStrategy: type: "RollingUpdate"

			gracefulShutdown: terminationGracePeriodSeconds: 30

			// ServiceAccount bound to the rbac component below.
			workloadIdentity: {
				name:           "metrics-server"
				automountToken: true
			}

			container: {
				name: "metrics-server"
				image: {
					repository: #config.image.repository
					tag:        #config.image.tag
					digest:     ""
					pullPolicy: #config.image.pullPolicy
				}

				// Base args concatenated with the optional --kubelet-insecure-tls flag.
				args: list.Concat([_baseArgs, _tlsArgs])

				// Expose HTTPS metrics API port. The OPM runtime renders this
				// into a Kubernetes Service with port 443 → targetPort 10250.
				ports: {
					https: {
						name:       "https"
						targetPort: 10250
						protocol:   "TCP"
					}
				}

				if #config.resources != _|_ {
					resources: #config.resources
				}

				// /tmp must be writable — metrics-server writes auto-generated TLS certs there.
				volumeMounts: {
					"tmp-dir": {
						name:      "tmp-dir"
						mountPath: "/tmp"
						emptyDir:  {}
					}
				}

				// Matches upstream security hardening:
				// non-root UID 1000, read-only rootfs, all capabilities dropped.
				securityContext: {
					allowPrivilegeEscalation: false
					readOnlyRootFilesystem:   true
					runAsNonRoot:             true
					runAsUser:                1000
					capabilities: drop: ["ALL"]
				}
			}

			// Writable /tmp for self-signed TLS cert generation.
			volumes: {
				"tmp-dir": {
					name:     "tmp-dir"
					emptyDir: {}
				}
			}

			securityContext: {
				runAsNonRoot:             true
				runAsUser:                1000
				allowPrivilegeEscalation: false
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// RBAC — system:metrics-server ClusterRole + ClusterRoleBinding
	////
	//// Core permissions for the metrics-server ServiceAccount:
	//// read pods/nodes for discovery, read nodes/metrics and
	//// nodes/stats for scraping resource usage data.
	/////////////////////////////////////////////////////////////////

	rbac: {
		resources_security.#Role

		spec: role: {
			name:  "system:metrics-server"
			scope: "cluster"

			rules: [
				{
					apiGroups: [""]
					resources: ["nodes/metrics"]
					verbs: ["get"]
				},
				{
					apiGroups: [""]
					resources: ["pods", "nodes"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: [""]
					resources: ["nodes/stats"]
					verbs: ["get"]
				},
			]

			subjects: [{name: "metrics-server"}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// RBAC Auth Delegator — metrics-server:system:auth-delegator
	////
	//// Grants the metrics-server ServiceAccount permission to
	//// delegate authentication and authorization to the Kubernetes
	//// API server (required for extension API server registration).
	//// Duplicates the rules of the built-in system:auth-delegator
	//// ClusterRole to satisfy OPM schema constraints.
	/////////////////////////////////////////////////////////////////

	"rbac-auth-delegator": {
		resources_security.#Role

		spec: role: {
			name:  "metrics-server:system:auth-delegator"
			scope: "cluster"

			rules: [
				{
					apiGroups: ["authentication.k8s.io"]
					resources: ["tokenreviews"]
					verbs: ["create"]
				},
				{
					apiGroups: ["authorization.k8s.io"]
					resources: ["subjectaccessreviews"]
					verbs: ["create"]
				},
			]

			subjects: [{name: "metrics-server"}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// RBAC Auth Reader — metrics-server-auth-reader
	////
	//// Grants the metrics-server ServiceAccount read access to the
	//// extension-apiserver-authentication ConfigMap in kube-system.
	//// Required to load the request-header CA for API aggregation.
	//// Namespace-scoped (kube-system) per upstream manifest.
	/////////////////////////////////////////////////////////////////

	"rbac-auth-reader": {
		resources_security.#Role

		spec: role: {
			name:  "metrics-server-auth-reader"
			scope: "namespace"

			rules: [
				{
					apiGroups: [""]
					resources: ["configmaps"]
					verbs: ["get", "list", "watch"]
				},
			]

			subjects: [{name: "metrics-server"}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// RBAC Auth Delegator — metrics-server:system:auth-delegator
	////
	//// Grants the metrics-server ServiceAccount permission to
	//// delegate authentication and authorization to the Kubernetes
	//// API server (required for extension API server registration).
	//// Duplicates the rules of the built-in system:auth-delegator
	//// ClusterRole to satisfy OPM schema constraints.
	/////////////////////////////////////////////////////////////////

	"rbac-auth-delegator": {
		resources_security.#Role

		spec: role: {
			name:  "metrics-server:system:auth-delegator"
			scope: "cluster"

			rules: [
				{
					apiGroups: ["authentication.k8s.io"]
					resources: ["tokenreviews"]
					verbs: ["create"]
				},
				{
					apiGroups: ["authorization.k8s.io"]
					resources: ["subjectaccessreviews"]
					verbs: ["create"]
				},
			]

			subjects: [{name: "metrics-server"}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// RBAC Auth Reader — metrics-server-auth-reader
	////
	//// Grants the metrics-server ServiceAccount read access to the
	//// extension-apiserver-authentication ConfigMap in kube-system.
	//// Required to load the request-header CA for API aggregation.
	//// Namespace-scoped (kube-system) per upstream manifest.
	/////////////////////////////////////////////////////////////////

	"rbac-auth-reader": {
		resources_security.#Role

		spec: role: {
			name:  "metrics-server-auth-reader"
			scope: "namespace"

			rules: [
				{
					apiGroups: [""]
					resources: ["configmaps"]
					verbs: ["get", "list", "watch"]
				},
			]

			subjects: [{name: "metrics-server"}]
		}
	}
}
