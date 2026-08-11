package istio_ambient

import (
	bp "opmodel.dev/catalogs/opm/blueprints/v1beta1"
	res "opmodel.dev/catalogs/opm/resources/v1beta1"
	tr "opmodel.dev/catalogs/opm/traits/v1beta1"
)

// Shared by both node agents: run everywhere, survive every taint, and be
// evicted last. A node agent that skips tainted nodes leaves exactly the nodes
// that need it unprotected.
_nodeAgentScheduling: {
	nodeSelector: "kubernetes.io/os": "linux"
	tolerations: [
		{effect: "NoSchedule", operator: "Exists"},
		{key: "CriticalAddonsOnly", operator: "Exists"},
		{effect: "NoExecute", operator: "Exists"},
	]
	priorityClassName: "system-node-critical"
}

#components: {
	/////////////////////////////////////////////////////////////////
	//// istio-cni — the node agent that captures pods into the mesh
	////
	//// ⚠ The DaemonSet name MUST be exactly `istio-cni-node`. The CNI plugin
	//// identifies its own agent pod by that name prefix (isCNIPod in
	//// cni/pkg/plugin/plugin.go). That check is the failsafe that lets a
	//// REPLACEMENT agent pod start when the plugin cannot reach the API
	//// server — during an upgrade, with expired credentials, or at node boot.
	//// Under any other name the plugin blocks its own replacement and the node
	//// deadlocks with no CNI agent.
	/////////////////////////////////////////////////////////////////
	"istio-cni": {
		bp.#DaemonWorkload

		if #config.networkPolicy.enabled {
			tr.#NetworkPolicy
		}
		res.#Volumes
		res.#ServiceAccount
		tr.#WorkloadIdentity
		tr.#ResourceName
		tr.#PodMetadata
		tr.#PodScheduling
		tr.#GracefulShutdown

		// Conditional struct-valued spec fields, HOISTED to component level
		// rather than guarded inside the spec block — the in-spec form trips
		// the CUE v0.17 closedness regression on the v2 catalog's closed
		// blueprint spec (catalog CLAUDE.md authoring pitfall; see
		// docs/cue-guard-closedness-workaround.md there). Do not inline these.
		if #config.cni.resources != _|_ {
			spec: daemonWorkload: container: resources: #config.cni.resources
		}
		if #config.networkPolicy.enabled {
			spec: networkPolicy: _cniNetworkPolicy
		}

		spec: {
			resourceName: "istio-cni-node"

			daemonWorkload: {
				restartPolicy: "Always"
				updateStrategy: {
					type: "RollingUpdate"
					rollingUpdate: maxUnavailable: 1
				}

				container: {
					name: "install-cni"
					image: {
						repository: "\(#config.image.hub)/install-cni"
						tag:        "\(#config.image.tag)-\(#config.image.variant)"
						digest:     ""
						pullPolicy: #config.image.pullPolicy
					}

					command: ["install-cni"]
					args: ["--log_output_level=\(#config.cni.logLevel)"]

					// The agent's whole configuration arrives as environment
					// variables from the exact-name ConfigMap.
					envFrom: [{configMapRef: name: "istio-cni-config"}]

					ports: metrics: {name: "metrics", targetPort: 15014}

					env: {
						REPAIR_NODE_NAME: {name: "REPAIR_NODE_NAME", fieldRef: fieldPath: "spec.nodeName"}
						REPAIR_RUN_AS_DAEMON: {name: "REPAIR_RUN_AS_DAEMON", value: "true"}
						REPAIR_SIDECAR_ANNOTATION: {name: "REPAIR_SIDECAR_ANNOTATION", value: "sidecar.istio.io/status"}
						ALLOW_SWITCH_TO_HOST_NS: {name: "ALLOW_SWITCH_TO_HOST_NS", value: "true"}
						NODE_NAME: {name: "NODE_NAME", fieldRef: {apiVersion: "v1", fieldPath: "spec.nodeName"}}
						GOMEMLIMIT: {name: "GOMEMLIMIT", resourceFieldRef: {resource: "limits.memory", divisor: "1"}}
						GOMAXPROCS: {name: "GOMAXPROCS", resourceFieldRef: {resource: "limits.cpu", divisor: "1"}}
						POD_NAME: {name: "POD_NAME", fieldRef: fieldPath: "metadata.name"}
						POD_NAMESPACE: {name: "POD_NAMESPACE", fieldRef: fieldPath: "metadata.namespace"}
					}

					readinessProbe: httpGet: {path: "/readyz", port: 8000}

					// resources is conditionally set from component level — see
					// the hoisted guards above the spec block.

					// Not `privileged: true`: the agent needs specific
					// capabilities, not everything. DAC_OVERRIDE is required
					// because it drops ALL and then has to write into hostPath
					// directories owned by other users.
					securityContext: {
						privileged:   false
						runAsUser:    0
						runAsGroup:   0
						runAsNonRoot: false
						capabilities: {
							drop: ["ALL"]
							add: ["NET_ADMIN", "NET_RAW", "SYS_PTRACE", "SYS_ADMIN", "DAC_OVERRIDE"]
						}
					}

					volumeMounts: {
						"cni-bin-dir": spec.volumes."cni-bin-dir" & {
							mountPath: "/host/opt/cni/bin"
						}
						"cni-host-procfs": spec.volumes."cni-host-procfs" & {
							mountPath: "/host/proc"
							readOnly:  true
						}
						"cni-net-dir": spec.volumes."cni-net-dir" & {
							mountPath: "/host/etc/cni/net.d"
						}
						"cni-socket-dir": spec.volumes."cni-socket-dir" & {
							mountPath: "/var/run/istio-cni"
						}
						// ⚠ The one mount that needs propagation. The container
						// runtime bind-mounts pod network namespaces into this
						// directory AFTER the agent starts; without
						// HostToContainer the agent keeps its start-up snapshot
						// of the mount tree and never sees pods created later.
						// Ambient capture then fails silently, and it presents
						// as a network fault rather than a config error.
						"cni-netns-dir": spec.volumes."cni-netns-dir" & {
							mountPath:        "/host/var/run/netns"
							mountPropagation: "HostToContainer"
						}
						"cni-ztunnel-sock-dir": spec.volumes."cni-ztunnel-sock-dir" & {
							mountPath: "/var/run/ztunnel"
						}
					}
				}
			}

			volumes: {
				"cni-bin-dir": {
					name:     "cni-bin-dir"
					readOnly: false
					hostPath: path: #config.cni.binDir
				}
				"cni-host-procfs": {
					name:     "cni-host-procfs"
					readOnly: true
					hostPath: {
						path: "/proc"
						type: "Directory"
					}
				}
				"cni-net-dir": {
					name:     "cni-net-dir"
					readOnly: false
					hostPath: path: #config.cni.confDir
				}
				"cni-socket-dir": {
					name:     "cni-socket-dir"
					readOnly: false
					hostPath: path: "/var/run/istio-cni"
				}
				// DirectoryOrCreate rather than Directory: the CNI may not bind
				// mount this until the first non-hostNetwork pod is scheduled,
				// and agent start-up must not block on that.
				"cni-netns-dir": {
					name:     "cni-netns-dir"
					readOnly: false
					hostPath: {
						path: "/var/run/netns"
						type: "DirectoryOrCreate"
					}
				}
				"cni-ztunnel-sock-dir": {
					name:     "cni-ztunnel-sock-dir"
					readOnly: false
					hostPath: {
						path: "/var/run/ztunnel"
						type: "DirectoryOrCreate"
					}
				}
			}

			workloadIdentity: {
				name:           "istio-cni"
				automountToken: true
			}
			serviceAccount: {
				name:           "istio-cni"
				automountToken: true
			}

			podMetadata: {
				labels: {
					// istiod's node-untainter finds these pods by this label,
					// not by name.
					"k8s-app":                 "istio-cni-node"
					"istio.io/dataplane-mode": "none"
					"sidecar.istio.io/inject": "false"
				}
				annotations: {
					"prometheus.io/scrape": "true"
					"prometheus.io/port":   "15014"
					"prometheus.io/path":   "/metrics"
					// AppArmor blocks some of the privileged operations the
					// agent needs. Still the annotation form at 1.30.3 — the
					// chart has not moved to securityContext.appArmorProfile.
					"container.apparmor.security.beta.kubernetes.io/install-cni": "unconfined"
				}
			}

			podScheduling: _nodeAgentScheduling

			gracefulShutdown: terminationGracePeriodSeconds: 30

			// networkPolicy is conditionally set from component level — see the
			// hoisted guards above the spec block.
		}
	}

	/////////////////////////////////////////////////////////////////
	//// ztunnel — the per-node L4 proxy
	/////////////////////////////////////////////////////////////////
	ztunnel: {
		bp.#DaemonWorkload

		if #config.networkPolicy.enabled {
			tr.#NetworkPolicy
		}
		res.#Volumes
		res.#ServiceAccount
		tr.#WorkloadIdentity
		tr.#ResourceName
		tr.#PodMetadata
		tr.#PodScheduling
		tr.#GracefulShutdown

		// Conditional struct-valued spec fields, HOISTED to component level —
		// same CUE v0.17 closedness workaround as istio-cni above.
		if #config.ztunnel.resources != _|_ {
			spec: daemonWorkload: container: resources: #config.ztunnel.resources
		}
		if #config.networkPolicy.enabled {
			spec: networkPolicy: _ztunnelNetworkPolicy
		}

		spec: {
			resourceName: "ztunnel"

			daemonWorkload: {
				restartPolicy: "Always"
				updateStrategy: {
					type: "RollingUpdate"
					rollingUpdate: {
						maxSurge:       1
						maxUnavailable: 0
					}
				}

				container: {
					name: "istio-proxy"
					image: {
						repository: "\(#config.image.hub)/ztunnel"
						tag:        "\(#config.image.tag)-\(#config.image.variant)"
						digest:     ""
						pullPolicy: #config.image.pullPolicy
					}

					args: ["proxy", "ztunnel"]

					ports: "ztunnel-stats": {name: "ztunnel-stats", targetPort: 15020}

					env: {
						// Both resolve the istiod Service by its exact DNS
						// name, which is why that Service must be unprefixed.
						CA_ADDRESS: {
							name:  "CA_ADDRESS"
							value: "istiod.\(#config.namespace.name).svc:15012"
						}
						XDS_ADDRESS: {
							name:  "XDS_ADDRESS"
							value: "istiod.\(#config.namespace.name).svc:15012"
						}
						RUST_LOG: {name: "RUST_LOG", value: #config.ztunnel.logLevel}
						RUST_BACKTRACE: {name: "RUST_BACKTRACE", value: "1"}
						ISTIO_META_CLUSTER_ID: {name: "ISTIO_META_CLUSTER_ID", value: #config.mesh.clusterName}
						INPOD_ENABLED: {name: "INPOD_ENABLED", value: "true"}
						TERMINATION_GRACE_PERIOD_SECONDS: {name: "TERMINATION_GRACE_PERIOD_SECONDS", value: "30"}
						POD_NAME: {name: "POD_NAME", fieldRef: fieldPath: "metadata.name"}
						POD_NAMESPACE: {name: "POD_NAMESPACE", fieldRef: fieldPath: "metadata.namespace"}
						NODE_NAME: {name: "NODE_NAME", fieldRef: fieldPath: "spec.nodeName"}
						INSTANCE_IP: {name: "INSTANCE_IP", fieldRef: fieldPath: "status.podIP"}
						SERVICE_ACCOUNT: {name: "SERVICE_ACCOUNT", fieldRef: fieldPath: "spec.serviceAccountName"}
						ISTIO_META_ENABLE_HBONE: {name: "ISTIO_META_ENABLE_HBONE", value: "true"}
						ZTUNNEL_CPU_LIMIT: {name: "ZTUNNEL_CPU_LIMIT", resourceFieldRef: {resource: "limits.cpu", divisor: "1"}}
					}

					// Port 15021 is deliberately not a declared containerPort —
					// upstream does not declare it either, and a probe on an
					// undeclared port is legal.
					readinessProbe: httpGet: {path: "/healthz/ready", port: 15021}

					// resources is conditionally set from component level — see
					// the hoisted guards above the spec block.

					// runAsUser 0 with NET_ADMIN/SYS_ADMIN/NET_RAW rather than
					// privileged. allowPrivilegeEscalation must be true: adding
					// SYS_ADMIN forces it regardless, and Kubernetes has a
					// validation gap that lets the contradiction through
					// silently, so it is stated explicitly.
					securityContext: {
						privileged:               false
						allowPrivilegeEscalation: true
						readOnlyRootFilesystem:   true
						runAsUser:                0
						runAsGroup:               1337
						runAsNonRoot:             false
						capabilities: {
							drop: ["ALL"]
							add: ["NET_ADMIN", "SYS_ADMIN", "NET_RAW"]
						}
					}

					volumeMounts: {
						"istiod-ca-cert": spec.volumes."istiod-ca-cert" & {
							mountPath: "/var/run/secrets/istio"
						}
						"istio-token": spec.volumes."istio-token" & {
							mountPath: "/var/run/secrets/tokens"
						}
						"cni-ztunnel-sock-dir": spec.volumes."cni-ztunnel-sock-dir" & {
							mountPath: "/var/run/ztunnel"
						}
						tmp: spec.volumes.tmp & {
							mountPath: "/tmp"
						}
					}
				}
			}

			volumes: {
				"istio-token": {
					name:     "istio-token"
					readOnly: false
					projected: sources: [{
						serviceAccountToken: {
							audience:          "istio-ca"
							expirationSeconds: 43200
							path:              "istio-token"
						}
					}]
				}
				// Written by istiod at runtime, mounted by exact name and NOT
				// optional — matching upstream. ztunnel blocks until istiod has
				// published the mesh root, which is the correct ordering.
				"istiod-ca-cert": {
					name:     "istiod-ca-cert"
					readOnly: false
					configMapRef: name: "istio-ca-root-cert"
				}
				"cni-ztunnel-sock-dir": {
					name:     "cni-ztunnel-sock-dir"
					readOnly: false
					hostPath: {
						path: "/var/run/ztunnel"
						type: "DirectoryOrCreate"
					}
				}
				// pprof needs somewhere writable and the root filesystem is
				// read-only.
				tmp: {
					name:     "tmp"
					readOnly: false
					emptyDir: {}
				}
			}

			workloadIdentity: {
				name:           "ztunnel"
				automountToken: true
			}
			serviceAccount: {
				name:           "ztunnel"
				automountToken: true
			}

			podMetadata: {
				labels: {
					app:                       "ztunnel"
					"istio.io/dataplane-mode": "none"
					"sidecar.istio.io/inject": "false"
				}
				annotations: {
					"prometheus.io/scrape": "true"
					"prometheus.io/port":   "15020"
				}
			}

			podScheduling: _nodeAgentScheduling

			gracefulShutdown: terminationGracePeriodSeconds: 30

			// networkPolicy is conditionally set from component level — see the
			// hoisted guards above the spec block.
		}
	}
}

/////////////////////////////////////////////////////////////////
//// Guards
/////////////////////////////////////////////////////////////////

// The name the CNI plugin's failsafe matches on. Getting this wrong deadlocks
// a node, so it is asserted rather than trusted.
_cniResourceName: "\(#components["istio-cni"].spec.resourceName)" & "istio-cni-node"

// ...and the label istiod's node-untainter selects on, which is a separate
// contract from the name.
_cniAppLabel: [
	if #components["istio-cni"].spec.podMetadata.labels["k8s-app"] != _|_ {
		#components["istio-cni"].spec.podMetadata.labels["k8s-app"]
	},
] & ["istio-cni-node"]

// Propagation on the netns mount, and on nothing else. Absent-field territory
// on the first, leak-detection on the second.
_cniNetnsPropagation: [
	if #components["istio-cni"].spec.daemonWorkload.container.volumeMounts."cni-netns-dir".mountPropagation != _|_ {
		#components["istio-cni"].spec.daemonWorkload.container.volumeMounts."cni-netns-dir".mountPropagation
	},
] & ["HostToContainer"]

_cniBinDirNoPropagation: [
	if #components["istio-cni"].spec.daemonWorkload.container.volumeMounts."cni-bin-dir".mountPropagation != _|_ {"leaked"},
] & []

// ztunnel must reach istiod at the exact Service DNS name.
_ztunnelXDS: [
	if #components.ztunnel.spec.daemonWorkload.container.env.XDS_ADDRESS != _|_ {
		#components.ztunnel.spec.daemonWorkload.container.env.XDS_ADDRESS.value
	},
] & ["istiod.\(#config.namespace.name).svc:15012"]

// Both agents must be exempt from the dataplane they implement.
_cniDataplaneNone: [
	if #components["istio-cni"].spec.podMetadata.labels["istio.io/dataplane-mode"] != _|_ {
		#components["istio-cni"].spec.podMetadata.labels["istio.io/dataplane-mode"]
	},
] & ["none"]

_ztunnelDataplaneNone: [
	if #components.ztunnel.spec.podMetadata.labels["istio.io/dataplane-mode"] != _|_ {
		#components.ztunnel.spec.podMetadata.labels["istio.io/dataplane-mode"]
	},
] & ["none"]

/////////////////////////////////////////////////////////////////
//// NetworkPolicy bodies
////
//// Hoisted out of the gated components DELIBERATELY. A guard that reads
//// #config sees the SCHEMA DEFAULT (false), not the instance's value, so any
//// assertion placed behind `if #config.networkPolicy.enabled` is vacuous —
//// verified: with the guards inside the gate, deleting ztunnel's UDP DNS rule
//// produced no error at all. Defined unconditionally here, these are evaluated
//// on every build and the assertions below actually bite.
/////////////////////////////////////////////////////////////////

_cniNetworkPolicy: {
	policyTypes: ["Ingress", "Egress"]
	ingress: [
		// Metrics endpoint for monitoring/prometheus.
		{ports: [{protocol: "TCP", port: 15014}]},
		// Readiness probe endpoint.
		{ports: [{protocol: "TCP", port: 8000}]},
	]
	// Allow-all: the agent needs DNS and the API server, whose address and port
	// vary by distribution.
	egress: [{}]
}

_ztunnelNetworkPolicy: {
	policyTypes: ["Ingress", "Egress"]
	ingress: [
		// Readiness probe.
		{ports: [{protocol: "TCP", port: 15021}]},
		// Monitoring/prometheus.
		{ports: [{protocol: "TCP", port: 15020}]},
		// Admin interface.
		{ports: [{protocol: "TCP", port: 15000}]},
		// HBONE traffic.
		{ports: [{protocol: "TCP", port: 15008}]},
		// Outbound traffic endpoint.
		{ports: [{protocol: "TCP", port: 15001}]},
		// Inbound plaintext.
		{ports: [{protocol: "TCP", port: 15006}]},
		// DNS capture — BOTH protocols on the same port.
		{ports: [
			{protocol: "TCP", port: 15053},
			{protocol: "UDP", port: 15053},
		]},
	]
	egress: [{}]
}

// Rule counts and the DNS-capture protocol count. Arithmetic forces resolution,
// so a dropped rule or protocol cannot be repaired by the assertion.
_cniNetPolRules:     (len(_cniNetworkPolicy.ingress) + 0) & 2
_ztunnelNetPolRules: (len(_ztunnelNetworkPolicy.ingress) + 0) & 7

// Dropping UDP here breaks in-mesh DNS resolution at runtime, silently.
_ztunnelDNSProtocols: (len(_ztunnelNetworkPolicy.ingress[6].ports) + 0) & 2

// Egress must stay a single EMPTY rule. An empty rule is allow-all; naming
// "Egress" in policyTypes with NO rules is a deny-all, so losing the rule
// inverts the policy rather than relaxing it.
_cniEgressAllowAll:     (len(_cniNetworkPolicy.egress) + 0) & 1
_ztunnelEgressAllowAll: (len(_ztunnelNetworkPolicy.egress) + 0) & 1
