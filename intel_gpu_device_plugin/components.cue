// Components for the intel-gpu-device-plugin module.
//
//	plugin — Intel GPU device plugin (DaemonSet)
//
// The plugin registers gpu.intel.com/i915 and gpu.intel.com/xe extended
// resources with each node's kubelet via the device-plugin gRPC API. No
// Kubernetes API server access is needed — no ServiceAccount, Role or
// ClusterRole is emitted, and the token is not mounted.
//
// Volume layout (matching the upstream Intel manifest):
//
//	dev-dri     hostPath /dev/dri                        → /dev/dri (read-only)
//	sysfs-drm   hostPath /sys/class/drm                  → /sys/class/drm (read-only)
//	dp-socket   hostPath /var/lib/kubelet/device-plugins → same (writable: the socket lands here)
//	cdi-path    hostPath /var/run/cdi                    → /var/run/cdi (created if absent)
//
// ⚠ Upstream additionally sets seLinuxOptions (type "container_device_plugin_t")
// and seccompProfile (type "RuntimeDefault"). Neither is modelled by
// res.#SecurityContextSchema, so they are NOT emitted here — apply them with a
// cluster-level mutating webhook if your policy requires them. This is a
// hardening gap, not a functional one: the plugin runs correctly without them.
package intel_gpu_device_plugin

import (
	"list"

	bp "opmodel.dev/catalogs/opm/blueprints/v1beta1"
	res "opmodel.dev/catalogs/opm/resources/v1beta1"
	tr "opmodel.dev/catalogs/opm/traits/v1beta1"
)

// _baseArgs holds CLI flags that are always present.
_baseArgs: [
	"-shared-dev-num", "\(#config.sharedDevNum)",
	"-allocation-policy", #config.allocationPolicy,
	"-bypath", #config.bypath,
	"-v", "\(#config.logLevel)",
]

// The remaining flag groups are appended only when their config is non-default,
// so the rendered command line stays as close to upstream's as possible.
_monitoringArgs: *[] | ["-enable-monitoring"]
if #config.enableMonitoring {
	_monitoringArgs: ["-enable-monitoring"]
}

_healthArgs: *[] | ["-health-management"]
if #config.healthManagement {
	_healthArgs: ["-health-management"]
}

_allowIdsArgs: *[] | ["-allow-ids", #config.allowIds]
if #config.allowIds != "" {
	_allowIdsArgs: ["-allow-ids", #config.allowIds]
}

_denyIdsArgs: *[] | ["-deny-ids", #config.denyIds]
if #config.denyIds != "" {
	_denyIdsArgs: ["-deny-ids", #config.denyIds]
}

_tempLimitArgs: *[] | ["-temp-limit", "\(#config.tempLimit)"]
if #config.tempLimit > 0 {
	_tempLimitArgs: ["-temp-limit", "\(#config.tempLimit)"]
}

_gpuTempLimitArgs: *[] | ["-gpu-temp-limit", "\(#config.gpuTempLimit)"]
if #config.gpuTempLimit > 0 {
	_gpuTempLimitArgs: ["-gpu-temp-limit", "\(#config.gpuTempLimit)"]
}

_memoryTempLimitArgs: *[] | ["-memory-temp-limit", "\(#config.memoryTempLimit)"]
if #config.memoryTempLimit > 0 {
	_memoryTempLimitArgs: ["-memory-temp-limit", "\(#config.memoryTempLimit)"]
}

#components: {

	/////////////////////////////////////////////////////////////////
	//// Plugin — Intel GPU device plugin (DaemonSet)
	////
	//// Runs on every Intel GPU node and creates a gRPC socket at
	////   /var/lib/kubelet/device-plugins/gpu.intel.com-i915.sock
	//// which the kubelet dials to discover and allocate GPUs.
	////
	//// The container is unprivileged: upstream drops ALL capabilities and
	//// runs a read-only root filesystem. GPU access comes from the /dev/dri
	//// host mount, not from privilege.
	/////////////////////////////////////////////////////////////////

	plugin: {
		bp.#DaemonWorkload
		res.#Volumes
		tr.#SecurityContext
		tr.#GracefulShutdown
		tr.#PodScheduling

		spec: {
			daemonWorkload: {
				restartPolicy: "Always"
				updateStrategy: {
					type: "RollingUpdate"
					rollingUpdate: maxUnavailable: 1
				}

				container: {
					name: "intel-gpu-device-plugin"
					image: {
						repository: #config.image.repository
						tag:        #config.image.tag
						digest:     #config.image.digest
						pullPolicy: #config.image.pullPolicy
					}

					// Base flags always present; the rest appended only when their
					// config is non-default.
					args: list.Concat([
						_baseArgs,
						_monitoringArgs,
						_healthArgs,
						_allowIdsArgs,
						_denyIdsArgs,
						_tempLimitArgs,
						_gpuTempLimitArgs,
						_memoryTempLimitArgs,
					])

					env: {
						// Downward API: node name for per-node plugin identity.
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

					resources: #config.resources

					volumeMounts: {
						"dev-dri": spec.volumes."dev-dri" & {
							mountPath: "/dev/dri"
							readOnly:  true
						}
						"sysfs-drm": spec.volumes."sysfs-drm" & {
							mountPath: "/sys/class/drm"
							readOnly:  true
						}
						"dp-socket": spec.volumes."dp-socket" & {
							mountPath: "/var/lib/kubelet/device-plugins"
							readOnly:  false
						}
						"cdi-path": spec.volumes."cdi-path" & {
							mountPath: "/var/run/cdi"
							readOnly:  false
						}
					}

					// Matches the upstream manifest. No runAsUser override — the
					// plugin runs as its image's default user.
					securityContext: {
						allowPrivilegeEscalation: false
						readOnlyRootFilesystem:   true
						capabilities: drop: ["ALL"]
					}
				}
			}

			volumes: {
				// Intel GPU DRI device nodes — control (card*) and render (renderD*).
				"dev-dri": {
					name:     "dev-dri"
					readOnly: true
					hostPath: {
						path: "/dev/dri"
						type: "Directory"
					}
				}
				// DRM sysfs — where GPU topology and PCI identity are enumerated.
				"sysfs-drm": {
					name:     "sysfs-drm"
					readOnly: true
					hostPath: {
						path: "/sys/class/drm"
						type: "Directory"
					}
				}
				// Kubelet device-plugin socket directory. Writable: the plugin
				// creates its own socket here for the kubelet to dial.
				"dp-socket": {
					name:     "dp-socket"
					readOnly: false
					hostPath: {
						path: "/var/lib/kubelet/device-plugins"
						type: "Directory"
					}
				}
				// Container Device Interface specs. DirectoryOrCreate because a
				// node that has never run a CDI-aware runtime will not have it.
				"cdi-path": {
					name:     "cdi-path"
					readOnly: false
					hostPath: {
						path: "/var/run/cdi"
						type: "DirectoryOrCreate"
					}
				}
			}

			gracefulShutdown: terminationGracePeriodSeconds: 30

			// The v0 module accepted nodeSelector in #config but never applied it,
			// so the DaemonSet ran on every node regardless. Wired up here.
			podScheduling: nodeSelector: #config.nodeSelector
		}
	}
}
