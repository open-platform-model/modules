// Components for the nvidia-device-plugin module.
//
//	plugin — NVIDIA GPU device plugin (DaemonSet)
//
// The plugin registers nvidia.com/gpu extended resources with each node's
// kubelet via the device-plugin gRPC API. No Kubernetes API server access is
// needed — no ServiceAccount, Role or ClusterRole is emitted, and the token is
// not mounted.
//
// The container is unprivileged: upstream drops ALL capabilities and disallows
// privilege escalation. GPU access comes from the NVIDIA container runtime
// selected by runtimeClassName, NOT from privilege or host device mounts —
// which is why that one field is load-bearing here in a way it is not for the
// Intel plugin.
package nvidia_device_plugin

import (
	bp "opmodel.dev/catalogs/opm/blueprints/workload"
	res "opmodel.dev/catalogs/opm/resources"
	tr "opmodel.dev/catalogs/opm/traits"
)

#components: {

	/////////////////////////////////////////////////////////////////
	//// Plugin — NVIDIA GPU device plugin (DaemonSet)
	////
	//// Creates a gRPC socket under /var/lib/kubelet/device-plugins which
	//// the kubelet dials to discover and allocate GPUs.
	////
	//// Tolerates the conventional nvidia.com/gpu taint so the plugin can
	//// land on dedicated GPU nodes — without it, a tainted GPU node would
	//// never get the plugin that makes its GPUs schedulable.
	/////////////////////////////////////////////////////////////////

	plugin: {
		bp.#DaemonWorkload
		res.#Volumes
		tr.#SecurityContext

		tr.#PodScheduling
		// No WorkloadIdentity: the plugin never calls the Kubernetes API, so it
		// needs no ServiceAccount. The trait would also force a name and pull an
		// SA object into the render.

		// Only compose the RuntimeClass trait when a class name is configured,
		// so `runtimeClass: ""` renders a pod with no runtimeClassName at all
		// rather than an empty string, which the API server rejects.
		if #config.runtimeClass != "" {
			tr.#RuntimeClass
		}

		spec: {
			daemonWorkload: {
				restartPolicy: "Always"
				updateStrategy: {
					type: "RollingUpdate"
					rollingUpdate: maxUnavailable: 1
				}

				container: {
					name: "nvidia-device-plugin-ctr"
					image: {
						repository: #config.image.repository
						tag:        #config.image.tag
						digest:     #config.image.digest
						pullPolicy: #config.image.pullPolicy
					}

					args: [
						"--mig-strategy=\(#config.migStrategy)",
						"--device-list-strategy=\(#config.deviceListStrategy)",
						"--fail-on-init-error=\(#config.failOnInitError)",
						"--pass-device-specs=\(#config.passDeviceSpecs)",
					]

					if #config.resources != _|_ {
						resources: #config.resources
					}

					volumeMounts: {
						"device-plugin": spec.volumes."device-plugin" & {
							mountPath: "/var/lib/kubelet/device-plugins"
							readOnly:  false
						}
					}

					// Matches the upstream manifest. The plugin needs no
					// capabilities — device access arrives via the NVIDIA runtime.
					securityContext: {
						allowPrivilegeEscalation: false
						capabilities: drop: ["ALL"]
					}
				}
			}

			volumes: {
				// Kubelet device-plugin socket directory. Writable: the plugin
				// creates its own socket here for the kubelet to dial.
				"device-plugin": {
					name:     "device-plugin"
					readOnly: false
					hostPath: {
						path: "/var/lib/kubelet/device-plugins"
						type: "Directory"
					}
				}
			}

			if #config.runtimeClass != "" {
				runtimeClass: #config.runtimeClass
			}

			podScheduling: {
				nodeSelector:      #config.nodeSelector
				priorityClassName: #config.priorityClassName
				tolerations: [{
					key:      "nvidia.com/gpu"
					operator: "Exists"
					effect:   "NoSchedule"
				}]
			}
		}
	}
}
