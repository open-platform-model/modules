// Components for the MetalLB module.
//
// Eight components:
//   namespace        — metallb-system Namespace (exact name, PSS-privileged labels)
//   crds             — all MetalLB CustomResourceDefinition objects (9 CRDs)
//   controller       — IP address assignment controller (Deployment)
//   speaker          — LoadBalancer IP announcement daemon (DaemonSet)
//   controller-rbac  — ClusterRole + ClusterRoleBinding for the controller
//   controller-role  — namespace-scoped Role + RoleBinding for the controller
//   speaker-rbac     — ClusterRole + ClusterRoleBinding for the speaker
//   speaker-role     — namespace-scoped Role + RoleBinding for the speaker
//
// RBAC follows the upstream Helm chart's two-tier structure (v0.16.1),
// including the resourceNames scoping the chart applies to the memberlist
// Secret and the controller Deployment — referencing the RENDERED object
// names, which assume the ModuleInstance is named `metallb` (see module.cue).
package metallb

import (
	bp "opmodel.dev/catalogs/opm/blueprints/v1beta1"
	res "opmodel.dev/catalogs/opm/resources/v1beta1"
	tr "opmodel.dev/catalogs/opm/traits/v1beta1"
	exp "opmodel.dev/catalogs/opm/resources/v1alpha1"
)

#components: {

	/////////////////////////////////////////////////////////////////
	//// Namespace — metallb-system (exact name + PSS labels)
	////
	//// The speaker runs hostNetwork as root with NET_RAW, which violates
	//// the baseline Pod Security Standard Talos enforces cluster-wide.
	//// All three PSS labels are set to privileged. On clusters where the
	//// namespace is pre-created at bootstrap this emission SSA-adopts the
	//// existing object and keeps the labels managed.
	/////////////////////////////////////////////////////////////////

	namespace: {
		exp.#Namespaces

		spec: namespaces: "metallb-system": {
			labels: {
				"pod-security.kubernetes.io/enforce": "privileged"
				"pod-security.kubernetes.io/audit":   "privileged"
				"pod-security.kubernetes.io/warn":    "privileged"
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// CRDs — MetalLB CustomResourceDefinitions
	////
	//// Deploys all 9 MetalLB CRD definitions so the cluster accepts
	//// IPAddressPool, L2Advertisement, BGPPeer, etc. as first-class
	//// resources. The openAPIV3Schema is sourced directly from the
	//// upstream v0.16.1 YAML files in crds/ via crds_data.cue.
	/////////////////////////////////////////////////////////////////

	crds: {
		res.#CRDs

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
	//// IPAddressPool CRs. Webhook mode stays disabled: no VWC is
	//// deployed, so enabled mode would crash trying to patch a
	//// non-existent resource. v0.16.1 serves HTTPS-only metrics on
	//// :9120 and health probes on :17472.
	/////////////////////////////////////////////////////////////////

	controller: {
		bp.#StatelessWorkload
		res.#ServiceAccount
		tr.#SecurityContext
		tr.#WorkloadIdentity
		tr.#GracefulShutdown

		// Conditional struct-valued spec field, HOISTED to component level
		// rather than guarded inside the spec block — the in-spec form trips
		// the CUE v0.17 closedness regression on the v2 catalog's closed
		// blueprint spec (catalog CLAUDE.md authoring pitfall; see
		// docs/cue-guard-closedness-workaround.md there). Do not inline this.
		if #config.controller.resources != _|_ {
			spec: statelessWorkload: container: resources: #config.controller.resources
		}

		spec: {
			statelessWorkload: {
				scaling: count: #config.controller.replicas
				restartPolicy: "Always"
				updateStrategy: type: "RollingUpdate"

				container: {
					name: "controller"
					image: {
						repository: #config.image.repository
						tag:        #config.image.tag
						digest:     #config.image.digest
						pullPolicy: #config.image.pullPolicy
					}

					args: [
						"--port=9120",
						"--log-level=\(#config.controller.logLevel)",
						"--webhook-mode=disabled",
					]

					env: {
						// Downward API: pod identity (upstream chart parity, v0.16.1).
						METALLB_POD_NAME: {
							name: "METALLB_POD_NAME"
							fieldRef: fieldPath: "metadata.name"
						}
					}

					ports: {
						metricshttps: {
							name:       "metricshttps"
							targetPort: 9120
							protocol:   "TCP"
						}
					}

					// v0.16.1 enables /healthz + /readyz on :17472 by default.
					livenessProbe: {
						httpGet: {
							path: "/healthz"
							port: 17472
						}
						initialDelaySeconds: 10
					}
					readinessProbe: {
						httpGet: {
							path: "/readyz"
							port: 17472
						}
						initialDelaySeconds: 10
					}

					// resources is conditionally set from component level — see
					// the hoisted guard above the spec block.

					// Container hardening — matches the chart's container securityContext.
					securityContext: {
						readOnlyRootFilesystem:   true
						allowPrivilegeEscalation: false
						capabilities: drop: ["ALL"]
					}
				}
			}

			gracefulShutdown: terminationGracePeriodSeconds: 0

			// ServiceAccount for the controller (bound to controller-rbac + controller-role).
			// The trait sets the pod's serviceAccountName; the resource emits the
			// ServiceAccount object itself (exact name, no instance prefix) — both
			// are required, the trait alone references an account nothing creates.
			workloadIdentity: {
				name:           "metallb-controller"
				automountToken: true
			}
			serviceAccount: {
				name:           "metallb-controller"
				automountToken: true
			}

			// Pod-level security context — non-root nobody.
			securityContext: {
				runAsNonRoot: true
				runAsUser:    65534
				runAsGroup:   65534
				fsGroup:      65534
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Speaker — LoadBalancer IP announcement (DaemonSet)
	////
	//// Runs on every node and announces LoadBalancer IPs using L2
	//// (ARP/NDP). Requires NET_RAW for ARP socket creation and runs as
	//// root (uid 0) per the upstream chart defaults.
	////
	//// hostNetwork: true is required so the speaker can respond to ARP
	//// on the node's physical interfaces. No probes: v0.16.1 speaker
	//// probes target host 127.0.0.1, which #ProbeSchema cannot express.
	/////////////////////////////////////////////////////////////////

	speaker: {
		bp.#DaemonWorkload
		res.#Volumes
		res.#Secrets
		res.#ConfigMaps
		res.#ServiceAccount
		tr.#HostNetwork
		tr.#SecurityContext
		tr.#WorkloadIdentity
		tr.#GracefulShutdown

		// Conditional struct-valued spec field, HOISTED to component level —
		// same CUE v0.17 closedness workaround as the controller above.
		if #config.speaker.resources != _|_ {
			spec: daemonWorkload: container: resources: #config.speaker.resources
		}

		spec: {
			daemonWorkload: {
				restartPolicy: "Always"
				updateStrategy: {
					type: "RollingUpdate"
					rollingUpdate: maxUnavailable: 1
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
						"--port=9120",
						"--log-level=\(#config.speaker.logLevel)",
					]

					env: {
						// Downward API: pod and node identity for memberlist and L2 announcements.
						METALLB_NODE_NAME: {
							name: "METALLB_NODE_NAME"
							fieldRef: fieldPath: "spec.nodeName"
						}
						METALLB_HOST: {
							name: "METALLB_HOST"
							fieldRef: fieldPath: "status.hostIP"
						}
						METALLB_ML_BIND_ADDR: {
							name: "METALLB_ML_BIND_ADDR"
							fieldRef: fieldPath: "status.podIP"
						}
						METALLB_POD_NAME: {
							name: "METALLB_POD_NAME"
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
					}

					ports: {
						metricshttps: {
							name:       "metricshttps"
							targetPort: 9120
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

					// resources is conditionally set from component level — see
					// the hoisted guard above the spec block.

					// Memberlist secret key — mounted from the OPM-managed Secret.
					// excludel2.yaml lands in /etc/metallb, where the speaker reads it.
					volumeMounts: {
						memberlist: spec.volumes.memberlist & {
							mountPath: "/etc/ml_secret_key"
						}
						excludel2: spec.volumes.excludel2 & {
							mountPath: "/etc/metallb"
						}
					}

					// Container hardening — NET_RAW is required to create raw ARP
					// sockets for L2 announcements.
					securityContext: {
						readOnlyRootFilesystem:   true
						allowPrivilegeEscalation: false
						capabilities: {
							add: ["NET_RAW"]
							drop: ["ALL"]
						}
					}
				}
			}

			// Share the node's network namespace so ARP replies reach physical interfaces.
			hostNetwork: true

			gracefulShutdown: terminationGracePeriodSeconds: 2

			// ServiceAccount for the speaker (bound to speaker-rbac + speaker-role).
			// Trait = pod's serviceAccountName; resource = the object itself.
			workloadIdentity: {
				name:           "metallb-speaker"
				automountToken: true
			}
			serviceAccount: {
				name:           "metallb-speaker"
				automountToken: true
			}

			// Pod-level security context — root (uid 0), per upstream chart.
			securityContext: {
				runAsNonRoot: false
				runAsUser:    0
			}

			// Memberlist gossip encryption key — managed by OPM. The operator
			// provides the key value via #config.speaker.memberlistKey; the
			// Secret renders as {instance}-speaker-memberlist and the volume
			// ref below resolves to the same name automatically.
			secrets: {
				memberlist: {
					data: secretkey: #config.speaker.memberlistKey
				}
			}

			// Interfaces the speaker must never announce on. Upstream ships this
			// as the `metallb-excludel2` ConfigMap mounted at /etc/metallb; without
			// it the speaker would answer ARP on CNI/bridge/veth interfaces. The
			// rendered name is instance-scoped ({instance}-speaker-excludel2) —
			// nothing outside the module reads it, only the volume below.
			configMaps: {
				excludel2: {
					data: "excludel2.yaml": """
						announcedInterfacesToExclude:
						- ^docker.*
						- ^cbr.*
						- ^dummy.*
						- ^virbr.*
						- ^lxcbr.*
						- ^veth.*
						- ^lo$
						- ^cali.*
						- ^tunl.*
						- ^flannel.*
						- ^kube-ipvs.*
						- ^cni.*
						- ^nodelocaldns.*
						- ^lxc.*

						"""
				}
			}

			volumes: {
				memberlist: {
					name:     "memberlist"
					readOnly: true
					secret: {
						from:        spec.secrets.memberlist
						defaultMode: 420
					}
				}
				excludel2: {
					name:      "excludel2"
					readOnly:  true
					configMap: spec.configMaps.excludel2
				}
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Controller RBAC — ClusterRole + ClusterRoleBinding
	////
	//// Cluster-wide permissions only. Namespace-scoped permissions
	//// (secrets, ipaddresspools, deployments) are in controller-role.
	//// vs the chart: the ValidatingWebhookConfiguration grant is dropped
	//// (dead with --webhook-mode=disabled, and no VWC is deployed) and
	//// the CRD grant keeps only list/watch (the write verbs exist solely
	//// for webhook CA injection).
	/////////////////////////////////////////////////////////////////

	"controller-rbac": {
		res.#Role

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
				// Informer cache sync over MetalLB CRDs.
				{
					apiGroups: ["apiextensions.k8s.io"]
					resources: ["customresourcedefinitions"]
					verbs: ["list", "watch"]
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
				// Native HTTPS metrics authn/authz (v0.16.1).
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

			subjects: [{name: "metallb-controller"}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Controller Role — namespace-scoped Role + RoleBinding
	////
	//// Namespace-scoped permissions for the controller: secrets
	//// (memberlist), ipaddresspools, bgppeers, etc. The resourceNames
	//// scoping mirrors the upstream chart, rewritten to the RENDERED
	//// object names (instance named `metallb` — see module.cue).
	/////////////////////////////////////////////////////////////////

	"controller-role": {
		res.#Role

		spec: role: {
			name:  "metallb-controller"
			scope: "namespace"

			rules: [
				// Manage the memberlist Secret (and rotate it if missing).
				{
					apiGroups: [""]
					resources: ["secrets"]
					verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
				},
				// Upstream scopes the memberlist secret list to its exact name
				// (chart: metallb-memberlist; here the rendered name).
				{
					apiGroups: [""]
					resources: ["secrets"]
					verbs: ["list"]
					resourceNames: ["metallb-speaker-memberlist"]
				},
				// Read the controller Deployment (owner references) — scoped to
				// the rendered Deployment name, as upstream scopes <fullname>-controller.
				{
					apiGroups: ["apps"]
					resources: ["deployments"]
					verbs: ["get"]
					resourceNames: ["metallb-controller"]
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
	/////////////////////////////////////////////////////////////////

	"speaker-rbac": {
		res.#Role

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
				// Full access to L2 status objects and ConfigurationState.
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
				// Native HTTPS metrics authn/authz (v0.16.1).
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

			subjects: [{name: "metallb-speaker"}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Speaker Role — namespace-scoped Role + RoleBinding
	////
	//// Namespace-scoped permissions: pods (self-identification), the
	//// memberlist Secret (scoped to its rendered name), configmaps,
	//// MetalLB CR reads, and BGP status writes. Mirrors the chart's
	//// pod-lister Role; v0.16.1 adds the controller SA as a second
	//// binding subject.
	/////////////////////////////////////////////////////////////////

	"speaker-role": {
		res.#Role

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
				// Read Secrets. Deliberately NOT scoped by resourceNames: the
				// RBAC authorizer only applies resourceNames to verbs that name a
				// single object (get/update/patch/delete). A `list`/`watch` request
				// carries no name, so a scoped rule grants nothing — the speaker's
				// informer would get Forbidden on its initial LIST. Upstream's
				// pod-lister Role is unscoped here for the same reason; the blast
				// radius is one namespace holding only MetalLB's own Secrets.
				{
					apiGroups: [""]
					resources: ["secrets"]
					verbs: ["get", "list", "watch"]
				},
				// Read ConfigMaps (optional memberlist tuning config upstream).
				{
					apiGroups: [""]
					resources: ["configmaps"]
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

			subjects: [
				{name: "metallb-speaker"},
				// v0.16.1: the pod-lister binding also carries the controller SA.
				{name: "metallb-controller"},
			]
		}
	}
}
