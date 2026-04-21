// Components for the istio-ambient module.
//
// Installs the Istio control plane in ambient mode:
//   crds-istio                       — all 14 Istio CRDs
//   crds-gateway-api                 — 6 Gateway API standard CRDs (opt-in via #config.gatewayAPI.enabled)
//   mesh-config                      — ConfigMap with Istio MeshConfig (HBONE + ambient fixed)
//   injection-template               — ConfigMap with minimal sidecar-injection template
//   istiod                           — Pilot Deployment + Service
//   istiod-clusterrole               — Main istiod ClusterRole + Binding
//   istiod-gateway-clusterrole       — Gateway-controller ClusterRole + Binding (K8s Gateway API)
//   istiod-reader-clusterrole        — Read-only ClusterRole for multicluster secrets
//   istiod-leaderelection-role       — Namespace Role for leader election
//   istiod-webhook-validating        — ValidatingWebhookConfiguration
//   istiod-webhook-mutating          — MutatingWebhookConfiguration (sidecar injector)
//   istio-cni                        — CNI plugin DaemonSet
//   istio-cni-config                 — CNI ConfigMap
//   istio-cni-clusterrole            — Repair + node-untaint ClusterRole + Binding
//   ztunnel                          — ztunnel DaemonSet
//   ztunnel-clusterrole              — ClusterRole + Binding
//
// Ambient-mode hard locks (not user-configurable, set here):
//   - PILOT_ENABLE_AMBIENT=true (istiod env)
//   - ISTIO_META_ENABLE_HBONE=true (meshConfig.defaultConfig.proxyMetadata)
//   - CA_TRUSTED_NODE_ACCOUNTS points at ztunnel SA
//   - global.variant=distroless (image tag suffix)
//   - istio-cni ambient mode always enabled
//
// RBAC rules are transcribed from `helm template` output of the upstream charts
// (v1.28.3) — see research/charts/{base,istiod,cni,ztunnel}/.
package istio_ambient

import (
	"encoding/json"
	"encoding/yaml"

	resources_admission "opmodel.dev/kubernetes/v1/resources/admission@v1"
	resources_config "opmodel.dev/opm/v1alpha1/resources/config@v1"
	resources_extension "opmodel.dev/opm/v1alpha1/resources/extension@v1"
	resources_security "opmodel.dev/opm/v1alpha1/resources/security@v1"
	resources_workload "opmodel.dev/opm/v1alpha1/resources/workload@v1"
	traits_network "opmodel.dev/opm/v1alpha1/traits/network@v1"
	traits_security "opmodel.dev/opm/v1alpha1/traits/security@v1"
	traits_workload "opmodel.dev/opm/v1alpha1/traits/workload@v1"
)

// _distrolessTag derives the distroless image variant tag suffix from #config.version.
_distrolessTag: "\(#config.version)-distroless"

// _meshConfigLocked is the ambient-required portion of meshConfig that users cannot override.
_meshConfigLocked: {
	defaultConfig: proxyMetadata: ISTIO_META_ENABLE_HBONE: "true"
}

// _meshConfigMerged combines the locked portion with user-tunable #config.istiod.meshConfig.
_meshConfigMerged: {
	_meshConfigLocked
	enablePrometheusMerge: #config.istiod.meshConfig.enablePrometheusMerge
	if #config.istiod.meshConfig.enableTracing {
		enableTracing: true
	}
	if #config.istiod.meshConfig.accessLogFile != _|_ {
		accessLogFile: #config.istiod.meshConfig.accessLogFile
	}
}

#components: {

	/////////////////////////////////////////////////////////////////
	//// CRDs — Istio CustomResourceDefinitions
	/////////////////////////////////////////////////////////////////

	"crds-istio": {
		resources_extension.#CRDs

		let _exclude = {
			if #config.base.excludedCRDs != _|_ {
				for n in #config.base.excludedCRDs {(n): true}
			}
		}

		spec: crds: {
			for crdName, raw in #crds if _exclude[crdName] == _|_ {
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
	//// CRDs — Gateway API (opt-in via #config.gatewayAPI.enabled)
	/////////////////////////////////////////////////////////////////

	if #config.gatewayAPI.enabled {
		"crds-gateway-api": {
			resources_extension.#CRDs

			spec: crds: {
				for crdName, raw in #crdsGatewayAPI {
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
	}

	/////////////////////////////////////////////////////////////////
	//// ConfigMaps — mesh config + sidecar injection template
	/////////////////////////////////////////////////////////////////

	"mesh-config": {
		resources_config.#ConfigMaps

		metadata: name: "istio"
		spec: configMaps: {
			istio: {
				immutable: false
				data: {
					mesh: yaml.Marshal(_meshConfigMerged)
					meshNetworks: yaml.Marshal({networks: {}})
				}
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// istiod — Pilot Deployment (ambient control plane)
	/////////////////////////////////////////////////////////////////

	istiod: {
		resources_workload.#Container
		traits_workload.#Scaling
		traits_workload.#RestartPolicy
		traits_workload.#UpdateStrategy
		traits_network.#Expose
		traits_security.#SecurityContext
		traits_security.#WorkloadIdentity

		metadata: {
			name: "istiod"
			labels: {
				"core.opmodel.dev/workload-type": "stateless"
				"istio.io/rev":                   "default"
				"istio":                          "pilot"
				"app":                            "istiod"
			}
		}

		spec: {
			scaling: count: #config.istiod.replicas
			restartPolicy: "Always"
			updateStrategy: type: "RollingUpdate"

			workloadIdentity: {
				name:           "istiod"
				automountToken: true
			}

			container: {
				name: "discovery"
				image: {
					repository: #config.istiod.image.repository
					tag:        _distrolessTag
					digest:     #config.istiod.image.digest
					pullPolicy: #config.imagePullPolicy
				}

				args: [
					"discovery",
					"--monitoringAddr=:15014",
					"--log_output_level=\(#config.istiod.logging.level)",
					"--domain",
					#config.trustDomain,
					"--keepaliveMaxServerConnectionAge",
					"30m",
				]

				ports: {
					"http-debug": {name: "http-debug", targetPort: 8080, protocol: "TCP"}
					"grpc-xds": {name: "grpc-xds", targetPort: 15010, protocol: "TCP"}
					"tls-xds": {name: "tls-xds", targetPort: 15012, protocol: "TCP"}
					"https-webhook": {name: "https-webhook", targetPort: 15017, protocol: "TCP"}
					"http-monitoring": {name: "http-monitoring", targetPort: 15014, protocol: "TCP"}
				}

				env: {
					REVISION: {name: "REVISION", value: "default"}
					PILOT_CERT_PROVIDER: {name: "PILOT_CERT_PROVIDER", value: "istiod"}
					POD_NAME: {
						name: "POD_NAME"
						fieldRef: fieldPath: "metadata.name"
					}
					POD_NAMESPACE: {
						name: "POD_NAMESPACE"
						fieldRef: fieldPath: "metadata.namespace"
					}
					SERVICE_ACCOUNT: {
						name: "SERVICE_ACCOUNT"
						fieldRef: fieldPath: "spec.serviceAccountName"
					}
					KUBECONFIG: {name: "KUBECONFIG", value: "/var/run/secrets/remote/config"}

					// Ambient-mode locks.
					CA_TRUSTED_NODE_ACCOUNTS: {
						name:  "CA_TRUSTED_NODE_ACCOUNTS"
						value: "\(_ztunnelNamespace)/\(#config.ztunnel.resourceName)"
					}
					PILOT_ENABLE_AMBIENT: {name: "PILOT_ENABLE_AMBIENT", value: "true"}

					// User-configurable.
					PILOT_TRACE_SAMPLING: {name: "PILOT_TRACE_SAMPLING", value: "\(#config.istiod.traceSampling)"}
					PILOT_ENABLE_ANALYSIS: {name: "PILOT_ENABLE_ANALYSIS", value: "false"}
					CLUSTER_ID: {name: "CLUSTER_ID", value: #config.clusterName}
				}

				readinessProbe: {
					httpGet: {path: "/ready", port: 8080}
					initialDelaySeconds: 1
					periodSeconds:       3
					timeoutSeconds:      5
				}

				if #config.istiod.resources != _|_ {
					resources: #config.istiod.resources
				}
			}

			securityContext: {
				runAsNonRoot:             true
				runAsUser:                1337
				runAsGroup:               1337
				readOnlyRootFilesystem:   true
				allowPrivilegeEscalation: false
				capabilities: drop: ["ALL"]
			}

			expose: {
				type: "ClusterIP"
				ports: {
					"grpc-xds": {targetPort: 15010, exposedPort: 15010, protocol: "TCP"}
					"https-dns": {targetPort: 15012, exposedPort: 15012, protocol: "TCP"}
					"https-webhook": {targetPort: 15017, exposedPort: 443, protocol: "TCP"}
					"http-monitoring": {targetPort: 15014, exposedPort: 15014, protocol: "TCP"}
				}
			}
		}
	}

	// _ztunnelNamespace is the namespace ztunnel runs in (defaults to the module namespace).
	_ztunnelNamespace: [// priority order: explicit config, fallback to module default
		if #config.istiod.trustedZtunnelNamespace != "" {#config.istiod.trustedZtunnelNamespace},
		"istio-system",
	][0]

	/////////////////////////////////////////////////////////////////
	//// istiod — Main ClusterRole + Binding
	////
	//// Transcribed from istiod/templates/clusterrole.yaml (v1.28.3).
	/////////////////////////////////////////////////////////////////

	"istiod-clusterrole": {
		resources_security.#Role

		spec: role: {
			name:  "istiod-clusterrole-istio-system"
			scope: "cluster"
			rules: [
				// sidecar injection controller
				{apiGroups: ["admissionregistration.k8s.io"], resources: ["mutatingwebhookconfigurations"], verbs: ["get", "list", "watch", "update", "patch"]},
				// validation webhook
				{apiGroups: ["admissionregistration.k8s.io"], resources: ["validatingwebhookconfigurations"], verbs: ["get", "list", "watch", "update"]},
				// istio config APIs (read-only across all groups)
				{apiGroups: ["config.istio.io", "security.istio.io", "networking.istio.io", "authentication.istio.io", "rbac.istio.io", "telemetry.istio.io", "extensions.istio.io"], verbs: ["get", "watch", "list"], resources: ["*"]},
				// workload entries (full lifecycle)
				{apiGroups: ["networking.istio.io"], verbs: ["get", "watch", "list", "update", "patch", "create", "delete"], resources: ["workloadentries"]},
				{apiGroups: ["networking.istio.io"], verbs: ["get", "watch", "list", "update", "patch", "create", "delete"], resources: ["workloadentries/status", "serviceentries/status"]},
				{apiGroups: ["security.istio.io"], verbs: ["get", "watch", "list", "update", "patch", "create", "delete"], resources: ["authorizationpolicies/status"]},
				{apiGroups: [""], verbs: ["get", "watch", "list", "update", "patch", "create", "delete"], resources: ["services/status"]},
				// CRD auto-detection
				{apiGroups: ["apiextensions.k8s.io"], resources: ["customresourcedefinitions"], verbs: ["get", "list", "watch"]},
				// discovery
				{apiGroups: [""], resources: ["pods", "nodes", "services", "namespaces", "endpoints"], verbs: ["get", "list", "watch"]},
				{apiGroups: ["discovery.k8s.io"], resources: ["endpointslices"], verbs: ["get", "list", "watch"]},
				// ingress controller
				{apiGroups: ["networking.k8s.io"], resources: ["ingresses", "ingressclasses"], verbs: ["get", "list", "watch"]},
				{apiGroups: ["networking.k8s.io"], resources: ["ingresses/status"], verbs: ["*"]},
				// CA namespace controller
				{apiGroups: [""], resources: ["configmaps"], verbs: ["create", "get", "list", "watch", "update"]},
				// JWT validation
				{apiGroups: ["authentication.k8s.io"], resources: ["tokenreviews"], verbs: ["create"]},
				// gateway SDS authz
				{apiGroups: ["authorization.k8s.io"], resources: ["subjectaccessreviews"], verbs: ["create"]},
				// Gateway API (read + status updates)
				{apiGroups: ["gateway.networking.k8s.io", "gateway.networking.x-k8s.io"], resources: ["*"], verbs: ["get", "watch", "list"]},
				{apiGroups: ["gateway.networking.x-k8s.io"], resources: ["xbackendtrafficpolicies/status", "xlistenersets/status"], verbs: ["update", "patch"]},
				{apiGroups: ["gateway.networking.k8s.io"], resources: ["backendtlspolicies/status", "gatewayclasses/status", "gateways/status", "grpcroutes/status", "httproutes/status", "referencegrants/status", "tcproutes/status", "tlsroutes/status", "udproutes/status"], verbs: ["update", "patch"]},
				{apiGroups: ["gateway.networking.k8s.io"], resources: ["gatewayclasses"], verbs: ["create", "update", "patch", "delete"]},
				// Inference pools
				{apiGroups: ["inference.networking.k8s.io"], resources: ["inferencepools"], verbs: ["get", "watch", "list"]},
				{apiGroups: ["inference.networking.k8s.io"], resources: ["inferencepools/status"], verbs: ["update", "patch"]},
				// secrets — multicluster
				{apiGroups: [""], resources: ["secrets"], verbs: ["get", "watch", "list"]},
				// MCS service exports/imports
				{apiGroups: ["multicluster.x-k8s.io"], resources: ["serviceexports"], verbs: ["get", "watch", "list", "create", "delete"]},
				{apiGroups: ["multicluster.x-k8s.io"], resources: ["serviceimports"], verbs: ["get", "watch", "list"]},
			]
			subjects: [{name: "istiod"}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// istiod — Gateway-controller ClusterRole (for K8s Gateway API)
	/////////////////////////////////////////////////////////////////

	"istiod-gateway-clusterrole": {
		resources_security.#Role

		spec: role: {
			name:  "istiod-gateway-controller-istio-system"
			scope: "cluster"
			rules: [
				{apiGroups: ["apps"], verbs: ["get", "watch", "list", "update", "patch", "create", "delete"], resources: ["deployments"]},
				{apiGroups: ["autoscaling"], verbs: ["get", "watch", "list", "update", "patch", "create", "delete"], resources: ["horizontalpodautoscalers"]},
				{apiGroups: ["policy"], verbs: ["get", "watch", "list", "update", "patch", "create", "delete"], resources: ["poddisruptionbudgets"]},
				{apiGroups: [""], verbs: ["get", "watch", "list", "update", "patch", "create", "delete"], resources: ["services", "serviceaccounts"]},
			]
			subjects: [{name: "istiod"}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// istiod — Read-only ClusterRole (multicluster secrets reader)
	/////////////////////////////////////////////////////////////////

	"istiod-reader-clusterrole": {
		resources_security.#Role

		spec: role: {
			name:  "istio-reader-clusterrole-istio-system"
			scope: "cluster"
			rules: [
				{apiGroups: ["config.istio.io", "security.istio.io", "networking.istio.io", "authentication.istio.io", "rbac.istio.io", "telemetry.istio.io", "extensions.istio.io"], resources: ["*"], verbs: ["get", "list", "watch"]},
				{apiGroups: [""], resources: ["endpoints", "pods", "services", "nodes", "replicationcontrollers", "namespaces", "secrets"], verbs: ["get", "list", "watch"]},
				{apiGroups: ["discovery.k8s.io"], resources: ["endpointslices"], verbs: ["get", "list", "watch"]},
				{apiGroups: ["networking.istio.io"], verbs: ["get", "watch", "list"], resources: ["workloadentries"]},
				{apiGroups: ["apiextensions.k8s.io"], resources: ["customresourcedefinitions"], verbs: ["get", "list", "watch"]},
				{apiGroups: ["apps"], resources: ["replicasets"], verbs: ["get", "list", "watch"]},
				{apiGroups: ["authentication.k8s.io"], resources: ["tokenreviews"], verbs: ["create"]},
				{apiGroups: ["authorization.k8s.io"], resources: ["subjectaccessreviews"], verbs: ["create"]},
				{apiGroups: ["gateway.networking.k8s.io", "gateway.networking.x-k8s.io"], resources: ["*"], verbs: ["get", "list", "watch"]},
				{apiGroups: ["multicluster.x-k8s.io"], resources: ["serviceexports", "serviceimports"], verbs: ["get", "list", "watch"]},
				{apiGroups: ["networking.k8s.io"], resources: ["ingresses", "ingressclasses"], verbs: ["get", "list", "watch"]},
			]
			subjects: [{name: "istio-reader-service-account"}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// istiod — Namespace Role (leader election + secrets)
	/////////////////////////////////////////////////////////////////

	"istiod-leaderelection-role": {
		resources_security.#Role

		spec: role: {
			name:  "istiod"
			scope: "namespace"
			rules: [
				{apiGroups: [""], resources: ["configmaps"], verbs: ["create", "get", "list", "watch", "update"]},
				{apiGroups: ["coordination.k8s.io"], resources: ["leases"], verbs: ["create", "get", "list", "watch", "update", "patch", "delete"]},
				{apiGroups: [""], resources: ["secrets"], verbs: ["create", "get", "watch", "list", "update", "delete"]},
			]
			subjects: [{name: "istiod"}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// istiod — ValidatingWebhookConfiguration
	/////////////////////////////////////////////////////////////////

	"istiod-webhook-validating": {
		resources_admission.#ValidatingWebhookConfiguration

		metadata: name: "istio-validator-istio-system"

		spec: validatingwebhookconfiguration: {
			webhooks: [{
				name: "rev.validation.istio.io"
				clientConfig: service: {
					name:      "istiod"
					namespace: "istio-system"
					path:      "/validate"
					port:      443
				}
				rules: [{
					operations: ["CREATE", "UPDATE"]
					apiGroups: ["security.istio.io", "networking.istio.io", "telemetry.istio.io", "extensions.istio.io"]
					apiVersions: ["*"]
					resources: ["*"]
				}]
				admissionReviewVersions: ["v1"]
				sideEffects:    "None"
				failurePolicy:  "Ignore"
				timeoutSeconds: 10
			}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// istiod — MutatingWebhookConfiguration (sidecar injector)
	/////////////////////////////////////////////////////////////////

	"istiod-webhook-mutating": {
		resources_admission.#MutatingWebhookConfiguration

		metadata: name: "istio-sidecar-injector"

		spec: mutatingwebhookconfiguration: {
			webhooks: [{
				name: "rev.namespace.sidecar-injector.istio.io"
				clientConfig: service: {
					name:      "istiod"
					namespace: "istio-system"
					path:      "/inject"
					port:      443
				}
				rules: [{
					operations: ["CREATE"]
					apiGroups: [""]
					apiVersions: ["v1"]
					resources: ["pods"]
				}]
				namespaceSelector: matchLabels: "istio-injection": "enabled"
				objectSelector: matchExpressions: [{key: "sidecar.istio.io/inject", operator: "NotIn", values: ["false"]}]
				admissionReviewVersions: ["v1"]
				sideEffects:        "None"
				failurePolicy:      "Ignore"
				reinvocationPolicy: #config.istiod.sidecarInjection.reinvocationPolicy
				timeoutSeconds:     10
			}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// istio-cni — DaemonSet + ConfigMap + RBAC
	////
	//// Runs on every node. Watches pods with istio.io/dataplane-mode=ambient
	//// and sets up iptables redirection for ambient traffic.
	/////////////////////////////////////////////////////////////////

	"istio-cni-config": {
		resources_config.#ConfigMaps

		metadata: name: "istio-cni-config"
		spec: configMaps: "istio-cni-config": {
			immutable: false
			data: {
				// Chained plugin fragment — inserted into the existing CNI chain.
				"cni_network_config": json.Marshal({
					cniVersion:        "0.3.1"
					name:              "istio-cni"
					type:              "istio-cni"
					log_level:         #config.cni.logging.level
					log_uds_address:   "__LOG_UDS_ADDRESS__"
					cni_event_address: "__CNI_EVENT_ADDRESS__"
					kubernetes: {
						cni_bin_dir:        #config.cni.cniBinDir
						exclude_namespaces: #config.cni.excludeNamespaces
					}
					ambient_enabled: #config.cni.ambient.enabled
				})
			}
		}
	}

	"istio-cni": {
		resources_workload.#Container
		traits_workload.#RestartPolicy
		traits_workload.#UpdateStrategy
		traits_security.#SecurityContext
		traits_security.#WorkloadIdentity

		metadata: {
			name: "istio-cni-node"
			labels: {
				"core.opmodel.dev/workload-type": "daemon"
				"k8s-app":                        "istio-cni-node"
			}
		}

		spec: {
			restartPolicy: "Always"
			updateStrategy: type: "RollingUpdate"

			workloadIdentity: {
				name:           "istio-cni"
				automountToken: true
			}

			container: {
				name: "install-cni"
				image: {
					repository: #config.cni.image.repository
					tag:        _distrolessTag
					digest:     #config.cni.image.digest
					pullPolicy: #config.imagePullPolicy
				}

				command: ["install-cni"]

				env: {
					REPAIR_ENABLED: {name: "REPAIR_ENABLED", value: "\(#config.cni.repair.enabled)"}
					REPAIR_NODE_NAME: {
						name: "REPAIR_NODE_NAME"
						fieldRef: fieldPath: "spec.nodeName"
					}
					REPAIR_LABEL_PODS: {name: "REPAIR_LABEL_PODS", value: "\(#config.cni.repair.labelPods)"}
					REPAIR_DELETE_PODS: {name: "REPAIR_DELETE_PODS", value: "\(#config.cni.repair.deletePods)"}
					REPAIR_REPAIR_PODS: {name: "REPAIR_REPAIR_PODS", value: "\(#config.cni.repair.repairPods)"}
					REPAIR_RUN_AS_DAEMON: {name: "REPAIR_RUN_AS_DAEMON", value: "true"}
					POD_NAME: {
						name: "POD_NAME"
						fieldRef: fieldPath: "metadata.name"
					}
					POD_NAMESPACE: {
						name: "POD_NAMESPACE"
						fieldRef: fieldPath: "metadata.namespace"
					}
					NODE_NAME: {
						name: "NODE_NAME"
						fieldRef: fieldPath: "spec.nodeName"
					}
				}

				if #config.cni.resources != _|_ {
					resources: #config.cni.resources
				}
			}

			// CNI pod runs privileged to manage iptables on the host.
			securityContext: {
				runAsNonRoot:             false
				runAsUser:                0
				readOnlyRootFilesystem:   true
				allowPrivilegeEscalation: true
				privileged:               true
				capabilities: {
					drop: ["ALL"]
					add: ["NET_ADMIN", "NET_RAW", "SYS_ADMIN"]
				}
			}
		}
	}

	"istio-cni-clusterrole": {
		resources_security.#Role

		spec: role: {
			name:  "istio-cni"
			scope: "cluster"
			rules: [
				{apiGroups: [""], resources: ["pods", "nodes", "namespaces"], verbs: ["get", "list", "watch"]},
				{apiGroups: [""], resources: ["pods/status"], verbs: ["patch", "update"]},
				{apiGroups: [""], resources: ["pods"], verbs: ["delete"]},
				{apiGroups: [""], resources: ["nodes"], verbs: ["patch"]},
			]
			subjects: [{name: "istio-cni"}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// ztunnel — DaemonSet + RBAC
	////
	//// Node-local ambient-mode data plane. Speaks HBONE to peers and
	//// mTLS to the CA via istiod.
	/////////////////////////////////////////////////////////////////

	ztunnel: {
		resources_workload.#Container
		traits_workload.#RestartPolicy
		traits_workload.#UpdateStrategy
		traits_workload.#GracefulShutdown
		traits_security.#SecurityContext
		traits_security.#WorkloadIdentity

		metadata: {
			name: #config.ztunnel.resourceName
			labels: {
				"core.opmodel.dev/workload-type": "daemon"
				"app":                            "ztunnel"
			}
		}

		spec: {
			restartPolicy: "Always"
			updateStrategy: type:                            "RollingUpdate"
			gracefulShutdown: terminationGracePeriodSeconds: #config.ztunnel.terminationGracePeriodSeconds

			workloadIdentity: {
				name:           #config.ztunnel.resourceName
				automountToken: true
			}

			container: {
				name: "istio-proxy"
				image: {
					repository: #config.ztunnel.image.repository
					tag:        _distrolessTag
					digest:     #config.ztunnel.image.digest
					pullPolicy: #config.imagePullPolicy
				}

				env: {
					CA_ADDRESS: {name: "CA_ADDRESS", value: #config.ztunnel.caAddress}
					XDS_ADDRESS: {name: "XDS_ADDRESS", value: #config.ztunnel.xdsAddress}
					RUST_LOG: {name: "RUST_LOG", value: #config.ztunnel.logging.level}
					RUST_BACKTRACE: {name: "RUST_BACKTRACE", value: "1"}
					ISTIO_META_CLUSTER_ID: {name: "ISTIO_META_CLUSTER_ID", value: #config.clusterName}
					ISTIO_META_DNS_PROXY_ADDR: {name: "ISTIO_META_DNS_PROXY_ADDR", value: "127.0.0.1:15053"}
					POD_NAME: {
						name: "POD_NAME"
						fieldRef: fieldPath: "metadata.name"
					}
					POD_NAMESPACE: {
						name: "POD_NAMESPACE"
						fieldRef: fieldPath: "metadata.namespace"
					}
					NODE_NAME: {
						name: "NODE_NAME"
						fieldRef: fieldPath: "spec.nodeName"
					}
					INSTANCE_IP: {
						name: "INSTANCE_IP"
						fieldRef: fieldPath: "status.podIP"
					}
					SERVICE_ACCOUNT: {
						name: "SERVICE_ACCOUNT"
						fieldRef: fieldPath: "spec.serviceAccountName"
					}
				}

				ports: {
					"ztunnel-stats": {name: "ztunnel-stats", targetPort: 15020, protocol: "TCP"}
				}

				readinessProbe: {
					httpGet: {path: "/healthz/ready", port: 15021}
					initialDelaySeconds: 1
					periodSeconds:       3
					timeoutSeconds:      5
				}

				if #config.ztunnel.resources != _|_ {
					resources: #config.ztunnel.resources
				}
			}

			// ztunnel runs privileged with CAP_NET_ADMIN for iptables + NetNS.
			securityContext: {
				runAsNonRoot:             false
				runAsUser:                0
				readOnlyRootFilesystem:   true
				allowPrivilegeEscalation: true
				privileged:               false
				capabilities: {
					drop: ["ALL"]
					add: ["NET_ADMIN", "NET_RAW", "SYS_ADMIN"]
				}
			}
		}
	}

	"ztunnel-clusterrole": {
		resources_security.#Role

		spec: role: {
			name:  "ztunnel"
			scope: "cluster"
			rules: [
				{apiGroups: [""], resources: ["pods", "nodes", "namespaces"], verbs: ["get", "list", "watch"]},
			]
			subjects: [{name: #config.ztunnel.resourceName}]
		}
	}
}
