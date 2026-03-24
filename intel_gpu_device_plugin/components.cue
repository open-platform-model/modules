// Components for the intel-gpu-device-plugin module.
//
// Components:
//   plugin — Intel GPU Device Plugin DaemonSet (init container + plugin container)
//   rbac   — ClusterRole + ClusterRoleBinding for the plugin ServiceAccount
//
// The plugin component's WorkloadIdentity trait creates the ServiceAccount resource
// via the serviceaccount-transformer (same pattern as metric_server, metallb, openebs_zfs).
//
// The plugin registers gpu.intel.com/i915 extended resources via the Kubernetes
// device plugin API. Each Intel GPU node receives one DaemonSet pod.
//
// Volume layout:
//   dev-dri   hostPath /dev/dri                        → /dev/dri (init + plugin, read-only)
//   dp-socket hostPath /var/lib/kubelet/device-plugins → /var/lib/kubelet/device-plugins (plugin)
//
// Security note:
//   The plugin container runs as root (uid 0) because creating a Unix socket in
//   /var/lib/kubelet/device-plugins/ requires write access to that root-owned directory.
//   The init container probes /dev/dri read-only and runs as non-root.
//   All Linux capabilities are dropped to limit the blast radius of both containers.
package intel_gpu_device_plugin

import (
	"list"

	resources_storage "opmodel.dev/opm/v1alpha1/resources/storage@v1"
	resources_workload "opmodel.dev/opm/v1alpha1/resources/workload@v1"
	traits_security "opmodel.dev/opm/v1alpha1/traits/security@v1"
	traits_workload "opmodel.dev/opm/v1alpha1/traits/workload@v1"
)

// _baseArgs holds the always-present plugin CLI arguments.
_baseArgs: [
	"-shared-dev-num", "\(#config.sharedDevNum)",
	"-allocation-policy", #config.allocationPolicy,
]

// _monitoringArgs is appended when monitoring is enabled.
_monitoringArgs: *[] | ["-enable-monitoring"]
if #config.enableMonitoring {
	_monitoringArgs: ["-enable-monitoring"]
}

#components: {

	/////////////////////////////////////////////////////////////////
	//// Plugin — Intel GPU Device Plugin (DaemonSet)
	////
	//// Runs on every Intel GPU node. The init container verifies that
	//// /dev/dri is populated with Intel GPU nodes before the plugin starts,
	//// preventing registration of zero devices with the kubelet.
	////
	//// The plugin creates a gRPC socket at:
	////   /var/lib/kubelet/device-plugins/gpu.intel.com-i915.sock
	//// Kubelet polls this socket to discover and allocate GPU resources.
	////
	//// Node targeting: DaemonSet pods should be restricted to nodes labelled
	////   intel.feature.node.io/gpu: "true"
	//// This label is set by the Node Feature Discovery (NFD) operator.
	//// Apply the nodeSelector via platform-level annotations or a release
	//// override when NFD is present.
	/////////////////////////////////////////////////////////////////

	plugin: {
		resources_workload.#Container
		resources_storage.#Volumes
		traits_workload.#InitContainers
		traits_workload.#RestartPolicy
		traits_workload.#UpdateStrategy
		traits_workload.#GracefulShutdown
		traits_security.#SecurityContext
		traits_security.#WorkloadIdentity

		metadata: {
			name: "plugin"
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

			gracefulShutdown: terminationGracePeriodSeconds: 30

			// ServiceAccount created by the serviceaccount-transformer for this trait.
			workloadIdentity: {
				name:           "intel-gpu-device-plugin"
				automountToken: true
			}

			// ── Init Container: init ───────────────────────────────────────────
			// Probes /dev/dri on the node to confirm an Intel GPU is present.
			// Exits non-zero (triggering a pod restart) when no GPU is detected
			// and FAIL_ON_INIT_ERROR=true. Set false on mixed-GPU clusters where
			// some nodes may not have Intel GPUs — prevents crash-loop restarts.
			initContainers: [{
				name: "init"
				image: {
					repository: #config.initImage.repository
					tag:        #config.initImage.tag
					digest:     ""
					pullPolicy: #config.initImage.pullPolicy
				}

				env: {
					FAIL_ON_INIT_ERROR: {
						name:  "FAIL_ON_INIT_ERROR"
						value: "\(#config.failOnInitError)"
					}
				}

				// Probe the DRI device directory for Intel GPU control and render nodes.
				volumeMounts: {
					"dev-dri": volumes["dev-dri"] & {
						mountPath: "/dev/dri"
						readOnly:  true
					}
				}

				securityContext: {
					allowPrivilegeEscalation: false
					readOnlyRootFilesystem:   true
					runAsNonRoot:             true
					capabilities: drop: ["ALL"]
				}
			}]

			// ── Main Container: intel-gpu-device-plugin ───────────────────────
			// Registers gpu.intel.com/i915 resources with the node's kubelet.
			// Communicates with kubelet via a gRPC Unix socket created in
			// /var/lib/kubelet/device-plugins/.
			container: {
				name: "intel-gpu-device-plugin"
				image: {
					repository: #config.image.repository
					tag:        #config.image.tag
					digest:     ""
					pullPolicy: #config.image.pullPolicy
				}

				// Base plugin args with optional -enable-monitoring appended.
				args: list.Concat([_baseArgs, _monitoringArgs])

				env: {
					// Downward API: node name injected for per-node plugin identity.
					NODE_NAME: {
						name: "NODE_NAME"
						fieldRef: fieldPath: "spec.nodeName"
					}
				}

				volumeMounts: {
					// Read /dev/dri to enumerate Intel GPU control and render nodes.
					"dev-dri": volumes["dev-dri"] & {
						mountPath: "/dev/dri"
						readOnly:  true
					}
					// Device plugin gRPC socket directory — kubelet discovers the plugin here.
					// Must be writable: the plugin creates its socket in this directory.
					"dp-socket": volumes["dp-socket"] & {
						mountPath: "/var/lib/kubelet/device-plugins"
					}
				}

				if #config.resources != _|_ {
					resources: #config.resources
				}

				// Runs as root: creating a Unix socket in /var/lib/kubelet/device-plugins/
				// requires write access to that root-owned kubelet directory.
				// readOnlyRootFilesystem and dropped capabilities limit the blast radius.
				securityContext: {
					allowPrivilegeEscalation: false
					readOnlyRootFilesystem:   true
					runAsNonRoot:             false
					runAsUser:                0
					capabilities: drop: ["ALL"]
				}
			}

			// ── Volumes ────────────────────────────────────────────────────────
			volumes: {
				// Intel GPU DRI device nodes — control (card*) and render (renderD*) nodes.
				// Mounted read-only: the plugin only enumerates devices, never writes to them.
				"dev-dri": {
					name: "dev-dri"
					hostPath: {
						path: "/dev/dri"
						type: "Directory"
					}
				}
				// Kubelet device plugin socket directory.
				// The plugin creates its gRPC socket here for kubelet to dial.
				"dp-socket": {
					name: "dp-socket"
				hostPath: {
					path: "/var/lib/kubelet/device-plugins"
					type: "Directory"
				}
				}
			}

			// Pod-level security: no runAsUser set here so the init container (runAsNonRoot: true)
			// inherits no conflicting UID. The plugin container sets runAsUser: 0 explicitly.
			securityContext: {
				allowPrivilegeEscalation: false
			}
		}
	}

}
