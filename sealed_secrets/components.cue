// Components for the sealed-secrets module.
//
// Components:
//   crds                  — SealedSecret CRD (bitnami.com/v1alpha1)
//   controller            — sealed-secrets controller Deployment with http + metrics Services
//   secrets-unsealer-rbac — ClusterRole: read SealedSecrets, full CRUD on Secrets (cluster-wide)
//   key-admin-rbac        — namespace Role: create/list Secrets in controller ns (key storage)
//   leader-election-rbac  — namespace Role for leases (only when highAvailability.enabled)
//
// Mirrors the upstream controller.yaml from
// https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.36.6/controller.yaml,
// minus the optional `system:authenticated` service-proxier Role (OPM RBAC
// subjects cannot bind to Kubernetes Groups — see README).
package sealed_secrets

import (
	"list"
	"strings"
	"encoding/json"

	resources_extension "opmodel.dev/opm/v1alpha1/resources/extension@v1"
	resources_security "opmodel.dev/opm/v1alpha1/resources/security@v1"
	resources_storage "opmodel.dev/opm/v1alpha1/resources/storage@v1"
	resources_workload "opmodel.dev/opm/v1alpha1/resources/workload@v1"
	resources_config "opmodel.dev/opm/v1alpha1/resources/config@v1"
	traits_network "opmodel.dev/opm/v1alpha1/traits/network@v1"
	traits_security "opmodel.dev/opm/v1alpha1/traits/security@v1"
	traits_workload "opmodel.dev/opm/v1alpha1/traits/workload@v1"
)

// _serviceAccountName — fixed name. Matches the ClusterRoleBinding/RoleBinding
// subjects hard-wired into upstream manifests; renaming requires re-binding
// RoleBindings owned by the cluster operator, so pin it here.
let _serviceAccountName = "sealed-secrets-controller"

// _controllerArgs assembles the controller CLI flags from #config.
// Unconditional flags come first; conditionals append via list.Concat so empty
// branches vanish without producing nil entries.
let _controllerArgs = list.Concat([
	[
		"--key-prefix=\(#config.controller.keyPrefix)",
		"--key-renew-period=\(#config.controller.keyRenewPeriod)",
		"--key-ttl=\(#config.controller.keyTTL)",
		"--log-level=\(#config.controller.logLevel)",
		"--log-format=\(#config.controller.logFormat)",
		"--max-unseal-retries=\(#config.controller.maxUnsealRetries)",
		"--kubeclient-qps=\(#config.controller.kubeclientQPS)",
		"--kubeclient-burst=\(#config.controller.kubeclientBurst)",
		"--listen-addr=:\(#config.service.httpPort)",
		"--listen-metrics-addr=:\(#config.service.metricsPort)",
	],
	if #config.controller.updateStatus {["--update-status"]},
	if #config.controller.watchForSecrets {["--watch-for-secrets"]},
	if #config.controller.keyCutoffTime != _|_ {
		["--key-cutoff-time=\(#config.controller.keyCutoffTime)"]
	},
	if #config.controller.additionalNamespaces != _|_ if len(#config.controller.additionalNamespaces) > 0 {
		["--additional-namespaces=\(strings.Join(#config.controller.additionalNamespaces, ","))"]
	},
	if #config.highAvailability.enabled {[
		"--leader-elect=true",
		"--leader-elect-lease-name=\(#config.highAvailability.leaseName)",
	]},
])

#components: {

	/////////////////////////////////////////////////////////////////
	//// CRD — SealedSecret (bitnami.com/v1alpha1)
	////
	//// The SealedSecret CRD must exist before the controller starts;
	//// otherwise the controller crash-loops looking for it. OPM applies
	//// CRDs before workloads in the standard reconcile order.
	/////////////////////////////////////////////////////////////////

	crds: {
		resources_extension.#CRDs

		let _rawCrds = {
			"sealedsecrets.bitnami.com": #crd_sealedsecrets_bitnami_com
		}

		spec: crds: {
			for crdName, raw in _rawCrds {
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
	//// Controller — sealed-secrets controller Deployment
	////
	//// Decrypts SealedSecret CRs into Secret objects. Holds the private
	//// signing key in-memory, backed by K8s Secrets
	//// (sealedsecrets.bitnami.com/sealed-secrets-key=active) in its own
	//// namespace. Rolls keys on --key-renew-period.
	////
	//// Exposes two Services via the Expose trait:
	////   http    (8080)  — kubeseal CLI target (fetch-cert, validate)
	////   metrics (8081)  — Prometheus /metrics endpoint
	////
	//// Upstream pins replicas=1 and does not ship leader election by
	//// default. Setting highAvailability.enabled=true only wires the
	//// flags + RBAC; verify your upstream build actually supports it.
	/////////////////////////////////////////////////////////////////

	controller: {
		resources_workload.#Container
		resources_storage.#Volumes
		traits_workload.#Scaling
		traits_workload.#RestartPolicy
		traits_workload.#UpdateStrategy
		traits_workload.#GracefulShutdown
		traits_security.#SecurityContext
		traits_security.#WorkloadIdentity
		traits_network.#Expose

		metadata: {
			name: "controller"
			labels: {
				"core.opmodel.dev/workload-type": "stateless"
			}
		}

		_volumes: spec.volumes

		spec: {
			scaling: count: #config.controller.replicas

			restartPolicy: "Always"

			// Recreate — the controller pins its signing key in-memory.
			// Rolling a second replica alongside an old one during an update
			// risks unseal operations racing against a key rotation carried
			// out by the newer instance.
			updateStrategy: type: "Recreate"

			gracefulShutdown: terminationGracePeriodSeconds: 30

			// ServiceAccount bound to secrets-unsealer (cluster) and
			// sealed-secrets-key-admin (namespace) Roles.
			workloadIdentity: {
				name:           _serviceAccountName
				automountToken: true
			}

			container: {
				name: "sealed-secrets-controller"
				image: {
					repository: #config.image.repository
					tag:        #config.image.tag
					digest:     #config.image.digest
					pullPolicy: #config.image.pullPolicy
				}

				// Upstream entrypoint: `controller` subcommand followed by flags.
				command: ["controller"]
				args: _controllerArgs

				ports: {
					http: {
						name:       "http"
						targetPort: #config.service.httpPort
						protocol:   "TCP"
					}
					metrics: {
						name:       "metrics"
						targetPort: #config.service.metricsPort
						protocol:   "TCP"
					}
				}

				// Upstream probes both hit /healthz on the http port.
				livenessProbe: {
					httpGet: {
						path: "/healthz"
						port: #config.service.httpPort
					}
					initialDelaySeconds: 10
					periodSeconds:       10
					timeoutSeconds:      5
					failureThreshold:    3
				}
				readinessProbe: {
					httpGet: {
						path: "/healthz"
						port: #config.service.httpPort
					}
					initialDelaySeconds: 5
					periodSeconds:       10
					timeoutSeconds:      3
					failureThreshold:    3
				}

				if #config.controller.resources != _|_ {
					resources: #config.controller.resources
				}

				// /tmp must be writable because the root filesystem is
				// read-only; the controller writes short-lived files here
				// during key generation and unsealing. The OPM Volumes trait
				// derives the pod-level volume from this entry, so the source
				// (name + emptyDir) lives on the volumeMount via `_volumes`.
				volumeMounts: {
					tmp: _volumes.tmp & {
						mountPath: "/tmp"
					}
				}
			}

			// Single emptyDir backing the /tmp mount — referenced by
			// volumeMounts.tmp above through the `_volumes` alias.
			volumes: {
				tmp: {
					name: "tmp"
					emptyDir: {}
				}
			}

			// ClusterIP Service carrying both ports.
			expose: {
				type: "ClusterIP"
				ports: {
					http: container.ports.http & {
						exposedPort: #config.service.httpPort
					}
					metrics: container.ports.metrics & {
						exposedPort: #config.service.metricsPort
					}
				}
			}

			// Matches upstream hardening: non-root uid 1001, fsGroup 65534,
			// read-only rootfs, drop all capabilities.
			// Note: the OPM SecurityContext trait does not currently model
			// seccompProfile; the provider applies RuntimeDefault at pod level
			// so the upstream profile is preserved.
			securityContext: {
				runAsNonRoot:             true
				runAsUser:                1001
				fsGroup:                  65534
				readOnlyRootFilesystem:   true
				allowPrivilegeEscalation: false
				capabilities: drop: ["ALL"]
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// secrets-unsealer — ClusterRole (controller's primary RBAC)
	////
	//// Allows the controller to read SealedSecret CRs across all
	//// namespaces and create/update/delete the corresponding Secret
	//// objects, emit events, and watch namespaces.
	/////////////////////////////////////////////////////////////////

	"secrets-unsealer-rbac": {
		resources_security.#Role

		spec: role: {
			name:  "secrets-unsealer"
			scope: "cluster"

			rules: [
				{
					apiGroups: ["bitnami.com"]
					resources: ["sealedsecrets"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: ["bitnami.com"]
					resources: ["sealedsecrets/status"]
					verbs: ["update"]
				},
				{
					apiGroups: [""]
					resources: ["secrets"]
					verbs: ["get", "list", "create", "update", "delete", "watch"]
				},
				{
					apiGroups: [""]
					resources: ["events"]
					verbs: ["create", "patch"]
				},
				{
					apiGroups: [""]
					resources: ["namespaces"]
					verbs: ["get"]
				},
			]

			subjects: [{name: _serviceAccountName}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// sealed-secrets-key-admin — namespace Role (key storage)
	////
	//// Namespace-scoped permission to create and list Secret objects
	//// in the controller's own namespace. The controller persists its
	//// signing keys here as Secrets labelled
	//// sealedsecrets.bitnami.com/sealed-secrets-key=active.
	/////////////////////////////////////////////////////////////////

	"key-admin-rbac": {
		resources_security.#Role

		spec: role: {
			name:  "sealed-secrets-key-admin"
			scope: "namespace"

			rules: [
				{
					apiGroups: [""]
					resources: ["secrets"]
					verbs: ["create", "list"]
				},
			]

			subjects: [{name: _serviceAccountName}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// leader-election — namespace Role (HA only)
	////
	//// Only emitted when highAvailability.enabled. Grants the
	//// controller permission to manage coordination.k8s.io/leases
	//// objects in its own namespace for leader election.
	/////////////////////////////////////////////////////////////////

	if #config.highAvailability.enabled {
		"leader-election-rbac": {
			resources_security.#Role

			spec: role: {
				name:  "sealed-secrets-leader-election"
				scope: "namespace"

				rules: [
					{
						apiGroups: ["coordination.k8s.io"]
						resources: ["leases"]
						verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
					},
					{
						apiGroups: [""]
						resources: ["events"]
						verbs: ["create", "patch"]
					},
				]

				subjects: [{name: _serviceAccountName}]
			}
		}
	}

	// ServiceMonitor manifest carried as a ConfigMap — applied by deployment
	// tooling when Prometheus Operator is present. Only emitted when
	// monitoring.enabled is true so clusters without the CRD don't see a
	// spurious ConfigMap.
	if #config.monitoring.enabled {
		"service-monitor": {
			resources_config.#ConfigMaps
			spec: configMaps: {
				"sealed-secrets-service-monitor": {
					immutable: false
					data: {
						"servicemonitor.json": "\(json.Marshal(_serviceMonitorManifest))"
					}
				}
			}
		}
	}
}
