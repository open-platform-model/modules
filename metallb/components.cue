// Components for the MetalLB module.
//
// Seven components:
//   crds             — all MetalLB CustomResourceDefinition objects (9 CRDs)
//   controller       — IP address assignment controller (Deployment)
//   speaker          — LoadBalancer IP announcement daemon (DaemonSet)
//   controller-rbac  — ClusterRole + ClusterRoleBinding for the controller
//   controller-role  — namespace-scoped Role + RoleBinding for the controller
//   speaker-rbac     — ClusterRole + ClusterRoleBinding for the speaker
//   speaker-role     — namespace-scoped Role + RoleBinding for the speaker
//
// RBAC follows the Helm chart's two-tier structure:
//   ClusterRole  — cluster-wide resources (services, nodes, CRDs, webhook configs)
//   Role         — namespace-scoped resources (secrets, pods, metallb CRs, deployments)
package metallb

import (
	resources_config    "opmodel.dev/opm/v1alpha1/resources/config@v1"
	resources_extension "opmodel.dev/opm/v1alpha1/resources/extension@v1"
	resources_security  "opmodel.dev/opm/v1alpha1/resources/security@v1"
	resources_storage   "opmodel.dev/opm/v1alpha1/resources/storage@v1"
	resources_workload  "opmodel.dev/opm/v1alpha1/resources/workload@v1"
	traits_network      "opmodel.dev/opm/v1alpha1/traits/network@v1"
	traits_security     "opmodel.dev/opm/v1alpha1/traits/security@v1"
	traits_workload     "opmodel.dev/opm/v1alpha1/traits/workload@v1"
)

#components: {

	/////////////////////////////////////////////////////////////////
	//// CRDs — MetalLB CustomResourceDefinitions
	////
	//// Deploys all 9 MetalLB CRD definitions so the cluster accepts
	//// IPAddressPool, L2Advertisement, BGPPeer, etc. as first-class resources.
	//// The openAPIV3Schema is sourced directly from the upstream YAML files
	//// in crds/ via crds_data.cue — no manual schema transcription.
	/////////////////////////////////////////////////////////////////

	crds: {
		resources_extension.#CRDs

		// Map each K8s CRD name to its raw imported struct from crds_data.cue.
		// The comprehension converts each entry into #CRDSchema format,
		// preserving the full upstream openAPIV3Schema for cluster-side validation.
		let _rawCrds = {
			"ipaddresspools.metallb.io":      #metallb_io_ipaddresspools
			"l2advertisements.metallb.io":    #metallb_io_l2advertisements
			"bgpadvertisements.metallb.io":   #metallb_io_bgpadvertisements
			"bgppeers.metallb.io":            #metallb_io_bgppeers
			"bfdprofiles.metallb.io":         #metallb_io_bfdprofiles
			"communities.metallb.io":         #metallb_io_communities
			"configurationstates.metallb.io": #metallb_io_configurationstates
			"servicebgpstatuses.metallb.io":  #metallb_io_servicebgpstatuses
			"servicel2statuses.metallb.io":   #metallb_io_servicel2statuses
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
	//// Controller — IP address assignment (Deployment)
	////
	//// Watches Services of type LoadBalancer and assigns IPs from
	//// IPAddressPool CRs. Manages the webhook TLS cert and writes it
	//// into the metallb-webhook-cert Secret on startup.
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

		metadata: {
			name: "controller"
			labels: {
				"core.opmodel.dev/workload-type": "stateless"
			}
		}

		spec: {
			scaling: count: #config.controller.replicas

			restartPolicy: "Always"

			updateStrategy: type: "RollingUpdate"

			gracefulShutdown: terminationGracePeriodSeconds: 0

			// ServiceAccount for the controller (bound to controller-rbac + controller-role).
			workloadIdentity: {
				name:           "metallb-controller"
				automountToken: true
			}

			container: {
				name: "controller"
				image: {
					repository: "quay.io/metallb/controller"
					tag:        #config.image.tag
					digest:     ""
					pullPolicy: #config.image.pullPolicy
				}

				// webhook-mode=disabled: skips cert-rotation and VWC injection.
				// We don't deploy the ValidatingWebhookConfiguration (no OPM transformer),
				// so enabled mode would crash trying to patch a non-existent resource.
				args: [
					"--port=7472",
					"--log-level=\(#config.controller.logLevel)",
					"--webhook-mode=disabled",
					"--tls-min-version=VersionTLS12",
				]

				ports: {
					monitoring: {
						name:       "monitoring"
						targetPort: 7472
						protocol:   "TCP"
					}
					webhook: {
						name:       "webhook"
						targetPort: 9443
						protocol:   "TCP"
					}
				}

				if #config.controller.resources != _|_ {
					resources: #config.controller.resources
				}

				// No liveness/readiness probes — matches Helm chart defaults.
				// The controller opens port 7472 only after informer caches sync,
				// which can take longer than a short initial delay would allow.

				// No volume mounts — webhook mode is disabled so the cert path is unused.
			}



			// Security context — matches Helm chart: non-root nobody, drop all caps.
			securityContext: {
				runAsNonRoot:             true
				runAsUser:                65534
				runAsGroup:               65534
				readOnlyRootFilesystem:   true
				allowPrivilegeEscalation: false
				capabilities: drop: ["ALL"]
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Speaker — LoadBalancer IP announcement (DaemonSet)
	////
	//// Runs on every node and announces LoadBalancer IPs using L2 (ARP/NDP).
	//// Requires NET_RAW for ARP socket creation and runs as root (uid 0)
	//// per the upstream Helm chart defaults.
	////
	//// NOTE: hostNetwork: true is required so the speaker can respond to ARP
	//// on the node's physical interfaces. Without it MetalLB announces IPs
	//// only inside the pod network and external hosts cannot reach the VIP.
	/////////////////////////////////////////////////////////////////

	speaker: {
		resources_workload.#Container
		resources_storage.#Volumes
		resources_config.#Secrets
		traits_workload.#RestartPolicy
		traits_workload.#UpdateStrategy
		traits_workload.#GracefulShutdown
		traits_network.#HostNetwork
		traits_security.#SecurityContext
		traits_security.#WorkloadIdentity

		metadata: {
			name: "speaker"
			labels: {
				"core.opmodel.dev/workload-type": "daemon"
			}
		}

		spec: {
			restartPolicy: "Always"

			updateStrategy: {
				type: "RollingUpdate"
				rollingUpdate: maxUnavailable: 1
			}

			gracefulShutdown: terminationGracePeriodSeconds: 2

			// Share the node's network namespace so ARP replies reach physical interfaces.
			hostNetwork: true

			// ServiceAccount for the speaker (bound to speaker-rbac + speaker-role).
			workloadIdentity: {
				name:           "metallb-speaker"
				automountToken: true
			}

			container: {
				name: "speaker"
				image: {
					repository: "quay.io/metallb/speaker"
					tag:        #config.image.tag
					digest:     ""
					pullPolicy: #config.image.pullPolicy
				}

				args: [
					"--port=7472",
					"--log-level=\(#config.speaker.logLevel)",
					// Bind metrics/health server to all interfaces.
					// Required because without hostNetwork: true the speaker cannot bind
					// to the host IP (METALLB_HOST = status.hostIP) that it defaults to.
					"--host=0.0.0.0",
				]

				env: {
					// Downward API: pod and node identity for memberlist and L2 announcements.
					METALLB_NODE_NAME: {
						name:     "METALLB_NODE_NAME"
						fieldRef: fieldPath: "spec.nodeName"
					}
					// METALLB_HOST (host IP) — used for speaker identification.
					METALLB_HOST: {
						name:     "METALLB_HOST"
						fieldRef: fieldPath: "status.hostIP"
					}
					METALLB_ML_BIND_ADDR: {
						name:     "METALLB_ML_BIND_ADDR"
						fieldRef: fieldPath: "status.podIP"
					}
					METALLB_POD_NAME: {
						name:     "METALLB_POD_NAME"
						fieldRef: fieldPath: "metadata.name"
					}
					// Memberlist peer discovery labels — must match speaker pod labels.
					METALLB_ML_LABELS: {
						name:  "METALLB_ML_LABELS"
						value: "app.kubernetes.io/name=metallb,app.kubernetes.io/component=speaker"
					}
					// Memberlist gossip port.
					METALLB_ML_BIND_PORT: {
						name:  "METALLB_ML_BIND_PORT"
						value: "7946"
					}
					// Path to the memberlist secret key file (mounted below).
					METALLB_ML_SECRET_KEY_PATH: {
						name:  "METALLB_ML_SECRET_KEY_PATH"
						value: "/etc/ml_secret_key"
					}
					METALLB_DEPLOYMENT: {
						name:  "METALLB_DEPLOYMENT"
						value: "speaker"
					}
				}

				ports: {
					monitoring: {
						name:       "monitoring"
						targetPort: 7472
						protocol:   "TCP"
					}
					"memberlist-tcp": {
						name:       "memberlist-tcp"
						targetPort: 7946
						protocol:   "TCP"
					}
					"memberlist-udp": {
						name:       "memberlist-udp"
						targetPort: 7946
						protocol:   "UDP"
					}
				}

				if #config.speaker.resources != _|_ {
					resources: #config.speaker.resources
				}

				// No liveness/readiness probes — matches Helm chart defaults.

				// Memberlist secret key — mounted from the pre-created metallb-memberlist Secret.
				volumeMounts: {
					memberlist: {
						name:      "memberlist"
						mountPath: "/etc/ml_secret_key"
						readOnly:  true
						// emptyDir satisfies the OPM volumeMount schema (matchN constraint);
						// the actual volume source is declared in spec.volumes below.
						emptyDir: {}
					}
				}
			}

			// Memberlist gossip encryption key — managed by OPM.
			// Operator provides the key value via #config.speaker.memberlistKey.
			// OPM creates the K8s Secret; the volume references it by the OPM-computed name.
			volumes: {
				memberlist: {
					name: "memberlist"
					secret: {
						from: {
							name: "memberlist"
							data: {
								secretkey: #config.speaker.memberlistKey
							}
						}
					}
				}
			}

			secrets: {
				memberlist: {
					data: {
						secretkey: #config.speaker.memberlistKey
					}
				}
			}

			// Speaker security context — matches Helm chart:
			//   Runs as root (empty pod-level securityContext in Helm = uid 0).
			//   NET_RAW is required to create raw ARP sockets for L2 announcements.
			//   allowPrivilegeEscalation: false and readOnlyRootFilesystem: true harden the container.
			securityContext: {
				runAsNonRoot:             false
				runAsUser:                0
				readOnlyRootFilesystem:   true
				allowPrivilegeEscalation: false
				capabilities: {
					add:  ["NET_RAW"]
					drop: ["ALL"]
				}
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Controller RBAC — ClusterRole + ClusterRoleBinding
	////
	//// Cluster-wide permissions only. Namespace-scoped permissions
	//// (secrets, ipaddresspools, deployments) are in controller-role.
	//// Matches the Helm chart metallb:controller ClusterRole exactly.
	/////////////////////////////////////////////////////////////////

	"controller-rbac": {
		resources_security.#Role

		spec: role: {
			name:  "metallb-controller"
			scope: "cluster"

			rules: [
				// Watch Services and update LoadBalancer status.
				{
					apiGroups: [""]
					resources: ["services", "namespaces"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: [""]
					resources: ["services/status"]
					verbs: ["update"]
				},
				// List nodes for topology-aware allocation.
				{
					apiGroups: [""]
					resources: ["nodes"]
					verbs: ["list"]
				},
				// Emit events.
				{
					apiGroups: [""]
					resources: ["events"]
					verbs: ["create", "patch"]
				},
				// Manage ValidatingWebhookConfigurations (caBundle injection).
				{
					apiGroups: ["admissionregistration.k8s.io"]
					resources: ["validatingwebhookconfigurations"]
					verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
				},
				// Manage MetalLB CRDs (informer cache sync + ownership).
				{
					apiGroups: ["apiextensions.k8s.io"]
					resources: ["customresourcedefinitions"]
					verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
				},
				// Manage ConfigurationState objects and their status.
				{
					apiGroups: ["metallb.io"]
					resources: ["configurationstates"]
					verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
				},
				{
					apiGroups: ["metallb.io"]
					resources: ["configurationstates/status"]
					verbs: ["get", "patch", "update"]
				},
			]

			subjects: [{name: "metallb-controller"}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Controller Role — namespace-scoped Role + RoleBinding
	////
	//// Namespace-scoped permissions for the controller:
	//// secrets (TLS cert + memberlist), ipaddresspools, bgppeers, etc.
	//// Matches the Helm chart metallb-controller Role exactly.
	/////////////////////////////////////////////////////////////////

	"controller-role": {
		resources_security.#Role

		spec: role: {
			name:  "metallb-controller"
			scope: "namespace"

			rules: [
				// Manage the webhook TLS cert Secret and the memberlist Secret.
				{
					apiGroups: [""]
					resources: ["secrets"]
					verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
				},
				// Read Deployments (for owner references on created resources).
				{
					apiGroups: ["apps"]
					resources: ["deployments"]
					verbs: ["get"]
				},
				// Read IP address pools and update their status.
				{
					apiGroups: ["metallb.io"]
					resources: ["ipaddresspools"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: ["metallb.io"]
					resources: ["ipaddresspools/status"]
					verbs: ["update"]
				},
				// Read and watch advertisement and peer configurations.
				{
					apiGroups: ["metallb.io"]
					resources: ["bgppeers", "bgpadvertisements", "l2advertisements", "communities", "bfdprofiles"]
					verbs: ["get", "list", "watch"]
				},
			]

			subjects: [{name: "metallb-controller"}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Speaker RBAC — ClusterRole + ClusterRoleBinding
	////
	//// Cluster-wide permissions only. Namespace-scoped permissions
	//// (pods, secrets, configmaps, metallb CRs) are in speaker-role.
	//// Matches the Helm chart metallb:speaker ClusterRole exactly.
	/////////////////////////////////////////////////////////////////

	"speaker-rbac": {
		resources_security.#Role

		spec: role: {
			name:  "metallb-speaker"
			scope: "cluster"

			rules: [
				// Watch Services, Endpoints, Nodes, and Namespaces cluster-wide.
				{
					apiGroups: [""]
					resources: ["services", "endpoints", "nodes", "namespaces"]
					verbs: ["get", "list", "watch"]
				},
				// Watch EndpointSlices (preferred over Endpoints in k8s >= 1.21).
				{
					apiGroups: ["discovery.k8s.io"]
					resources: ["endpointslices"]
					verbs: ["get", "list", "watch"]
				},
				// Emit events.
				{
					apiGroups: [""]
					resources: ["events"]
					verbs: ["create", "patch"]
				},
				// Full access to L2/BGP status objects and ConfigurationState.
				{
					apiGroups: ["metallb.io"]
					resources: [
						"servicel2statuses",
						"servicel2statuses/status",
						"configurationstates",
						"configurationstates/status",
					]
					verbs: ["*"]
				},
			]

			subjects: [{name: "metallb-speaker"}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Speaker Role — namespace-scoped Role + RoleBinding
	////
	//// Namespace-scoped permissions: pods (self-identification),
	//// secrets (memberlist key), configmaps, MetalLB CR reads,
	//// and BGP status writes. Matches the Helm chart
	//// metallb-pod-lister Role exactly.
	/////////////////////////////////////////////////////////////////

	"speaker-role": {
		resources_security.#Role

		spec: role: {
			name:  "metallb-speaker"
			scope: "namespace"

			rules: [
				// Self-identification and topology awareness.
				{
					apiGroups: [""]
					resources: ["pods"]
					verbs: ["get", "list"]
				},
				// Read the memberlist Secret and any other referenced Secrets.
				{
					apiGroups: [""]
					resources: ["secrets", "configmaps"]
					verbs: ["get", "list", "watch"]
				},
				// Read MetalLB configuration CRs.
				{
					apiGroups: ["metallb.io"]
					resources: [
						"bfdprofiles",
						"bgppeers",
						"l2advertisements",
						"bgpadvertisements",
						"ipaddresspools",
						"communities",
					]
					verbs: ["get", "list", "watch"]
				},
				// Full access to BGP service status objects.
				{
					apiGroups: ["metallb.io"]
					resources: ["servicebgpstatuses", "servicebgpstatuses/status"]
					verbs: ["*"]
				},
			]

			subjects: [{name: "metallb-speaker"}]
		}
	}
}
