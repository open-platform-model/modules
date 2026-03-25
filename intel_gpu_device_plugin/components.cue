// Components for the intel-gpu-device-plugin module.
//
// Components:
//   plugin — Intel GPU Device Plugin DaemonSet
//
// The plugin registers gpu.intel.com/i915 and gpu.intel.com/xe extended resources
// with each node's kubelet via the Kubernetes device plugin gRPC API. No Kubernetes
// API server access is needed — no ServiceAccount, RBAC, or ClusterRole required.
//
// Volume layout (matching the official Intel manifest):
//   dev-dri     hostPath /dev/dri                        → /dev/dri (read-only)
//   sysfs-drm   hostPath /sys/class/drm                  → /sys/class/drm (read-only)
//   dp-socket   hostPath /var/lib/kubelet/device-plugins → /var/lib/kubelet/device-plugins
//   cdi-path    hostPath /var/run/cdi                    → /var/run/cdi (created if absent)
//
// Security (matching upstream):
//   readOnlyRootFilesystem: true
//   allowPrivilegeEscalation: false
//   capabilities: drop: ["ALL"]
//   seLinuxOptions: type: "container_device_plugin_t"
//   seccompProfile: type: "RuntimeDefault"
//   No runAsUser override — runs as default container user.
package intel_gpu_device_plugin

import (
	"list"

	resources_storage "opmodel.dev/opm/v1alpha1/resources/storage@v1"
	resources_workload "opmodel.dev/opm/v1alpha1/resources/workload@v1"
	traits_security "opmodel.dev/opm/v1alpha1/traits/security@v1"
	traits_workload "opmodel.dev/opm/v1alpha1/traits/workload@v1"
)

// _baseArgs holds CLI flags that are always present.
_baseArgs: [
	"-shared-dev-num", "\(#config.sharedDevNum)",
	"-allocation-policy", #config.allocationPolicy,
	"-bypath", #config.bypath,
	"-v", "\(#config.logLevel)",
]

// _monitoringArgs is appended when monitoring is enabled.
_monitoringArgs: *[] | ["-enable-monitoring"]
if #config.enableMonitoring {
	_monitoringArgs: ["-enable-monitoring"]
}

// _healthArgs is appended when health management is enabled.
_healthArgs: *[] | ["-health-management"]
if #config.healthManagement {
	_healthArgs: ["-health-management"]
}

// _allowIdsArgs is appended when allowIds is non-empty.
_allowIdsArgs: *[] | ["-allow-ids", #config.allowIds]
if #config.allowIds != "" {
	_allowIdsArgs: ["-allow-ids", #config.allowIds]
}

// _denyIdsArgs is appended when denyIds is non-empty.
_denyIdsArgs: *[] | ["-deny-ids", #config.denyIds]
if #config.denyIds != "" {
	_denyIdsArgs: ["-deny-ids", #config.denyIds]
}

// _tempLimitArgs is appended when a global temperature limit is set.
_tempLimitArgs: *[] | ["-temp-limit", "\(#config.tempLimit)"]
if #config.tempLimit > 0 {
	_tempLimitArgs: ["-temp-limit", "\(#config.tempLimit)"]
}

// _gpuTempLimitArgs is appended when a GPU-core temperature limit is set.
_gpuTempLimitArgs: *[] | ["-gpu-temp-limit", "\(#config.gpuTempLimit)"]
if #config.gpuTempLimit > 0 {
	_gpuTempLimitArgs: ["-gpu-temp-limit", "\(#config.gpuTempLimit)"]
}

// _memoryTempLimitArgs is appended when a GPU-memory temperature limit is set.
_memoryTempLimitArgs: *[] | ["-memory-temp-limit", "\(#config.memoryTempLimit)"]
if #config.memoryTempLimit > 0 {
	_memoryTempLimitArgs: ["-memory-temp-limit", "\(#config.memoryTempLimit)"]
}

#components: {

	/////////////////////////////////////////////////////////////////
	//// Plugin — Intel GPU Device Plugin (DaemonSet)
	////
	//// Runs on every Intel GPU node. The plugin creates a gRPC socket at:
	////   /var/lib/kubelet/device-plugins/gpu.intel.com-i915.sock
	//// Kubelet polls this socket to discover and allocate GPU resources.
	////
	//// No ServiceAccount or RBAC needed — the plugin communicates only
	//// with the kubelet via gRPC, not the Kubernetes API server.
	////
	//// Node targeting: defaults to amd64 via nodeSelector from #config.
	//// When NFD is deployed, also add:
	////   "intel.feature.node.kubernetes.io/gpu": "true"
	//// via a release override on #config.nodeSelector.
	/////////////////////////////////////////////////////////////////

	plugin: {
		resources_workload.#Container
		resources_storage.#Volumes
		traits_workload.#RestartPolicy
		traits_workload.#UpdateStrategy
		traits_workload.#GracefulShutdown

		traits_security.#SecurityContext
		// NOTE: No WorkloadIdentity — the plugin does not need a ServiceAccount.
		// It communicates only with the kubelet via gRPC socket, not the K8s API.

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

			// ── Main Container: intel-gpu-device-plugin ───────────────────────
			// Registers gpu.intel.com/i915 and gpu.intel.com/xe resources with
			// the node's kubelet. Communicates via a gRPC Unix socket created in
			// /var/lib/kubelet/device-plugins/.
			container: {
				name: "intel-gpu-device-plugin"
				image: {
					repository: #config.image.repository
					tag:        #config.image.tag
					digest:     ""
					pullPolicy: #config.image.pullPolicy
				}

				// All CLI flags — base flags always present, optional flags appended
				// only when the corresponding config is non-default.
				args: list.Concat([_baseArgs, _monitoringArgs, _healthArgs, _allowIdsArgs, _denyIdsArgs, _tempLimitArgs, _gpuTempLimitArgs, _memoryTempLimitArgs])

				env: {
					// Downward API: node name injected for per-node plugin identity.
					NODE_NAME: {
						name: "NODE_NAME"
						fieldRef: fieldPath: "spec.nodeName"
					}
					// Downward API: host IP for health endpoint binding.
					HOST_IP: {
						name: "HOST_IP"
						fieldRef: fieldPath: "status.hostIP"
					}
				}

				volumeMounts: {
					// Read /dev/dri to enumerate Intel GPU control and render nodes.
					"dev-dri": volumes["dev-dri"] & {
						mountPath: "/dev/dri"
						readOnly:  true
					}
					// DRM sysfs — GPU topology enumeration (read-only).
					"sysfs-drm": volumes["sysfs-drm"] & {
						mountPath: "/sys/class/drm"
						readOnly:  true
					}
					// Device plugin gRPC socket directory — kubelet discovers the plugin here.
					// Must be writable: the plugin creates its socket file in this directory.
					"dp-socket": volumes["dp-socket"] & {
						mountPath: "/var/lib/kubelet/device-plugins"
					}
					// CDI specs directory — used when CDI device injection is enabled.
					"cdi-path": volumes["cdi-path"] & {
						mountPath: "/var/run/cdi"
					}
				}

				resources: #config.resources

				// Security context matches the official upstream Intel manifest.
				// No runAsUser override — the plugin runs as its container image default user.
				// NOTE: seLinuxOptions (type: "container_device_plugin_t") and
				// seccompProfile (type: "RuntimeDefault") are required by the upstream manifest
				// but are not yet modeled by the OPM SecurityContextSchema. Apply them via
				// a cluster-level mutating webhook or release annotation.
				securityContext: {
					allowPrivilegeEscalation: false
					readOnlyRootFilesystem:   true
					capabilities: drop: ["ALL"]
				}
			}

			// ── Volumes ────────────────────────────────────────────────────────
			volumes: {
				// Intel GPU DRI device nodes — control (card*) and render (renderD*).
				// Read-only: the plugin enumerates devices but never writes to /dev/dri.
				"dev-dri": {
					name: "dev-dri"
					hostPath: {
						path: "/dev/dri"
						type: "Directory"
					}
				}
				// DRM sysfs info — used by the plugin to enumerate GPU topology.
				// Read-only: informational access only.
				"sysfs-drm": {
					name: "sysfs-drm"
					hostPath: {
						path: "/sys/class/drm"
						type: "Directory"
					}
				}
				// Kubelet device plugin socket directory.
				// The plugin creates its gRPC socket here for kubelet to dial.
				// Must be writable: the plugin creates a socket file in this directory.
				"dp-socket": {
					name: "dp-socket"
					hostPath: {
						path: "/var/lib/kubelet/device-plugins"
						type: "Directory"
					}
				}
				// Container Device Interface (CDI) specs directory.
				// Created automatically if absent (DirectoryOrCreate).
				// Used when CDI device injection is enabled.
				"cdi-path": {
					name: "cdi-path"
					hostPath: {
						path: "/var/run/cdi"
						type: "DirectoryOrCreate"
					}
				}
			}
		}
	}

}
