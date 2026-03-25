// Components for the intel-gpu-exporter module.
//
// Components:
//   exporter — Intel GPU Metrics Exporter DaemonSet
//
// The exporter reads GPU utilization, memory, temperature, and power data from
// the host using the Intel XPU Manager daemon and exposes them as a
// Prometheus-compatible HTTP endpoint at :<metricsPort>/metrics.
//
// Requires hostPID to enumerate and observe per-process GPU utilization from
// the host process table.
//
// Volume layout:
//   dev-dri     hostPath /dev/dri         → /dev/dri
//   sysfs-drm   hostPath /sys/class/drm   → /sys/class/drm (read-only)
//
// Security:
//   privileged: true — required for direct GPU device access and metrics collection.
//   runAsUser: 0    — runs as root for host device and process visibility.
package intel_gpu_exporter

import (
	resources_storage "opmodel.dev/opm/v1alpha1/resources/storage@v1"
	resources_workload "opmodel.dev/opm/v1alpha1/resources/workload@v1"
	traits_security "opmodel.dev/opm/v1alpha1/traits/security@v1"
	traits_workload "opmodel.dev/opm/v1alpha1/traits/workload@v1"
)

#components: {

	/////////////////////////////////////////////////////////////////
	//// Exporter — Intel GPU Metrics Exporter (DaemonSet)
	////
	//// Runs on every Intel GPU node. Reads GPU metrics from the host
	//// and exposes them at http://<node-ip>:<metricsPort>/metrics.
	////
	//// Requires hostPID to enumerate and monitor host GPU processes.
	////
	//// Node targeting: defaults to amd64 architecture.
	//// Add "intel.feature.node.kubernetes.io/gpu": "true" when NFD
	//// is deployed via a release override on #config.nodeSelector.
	/////////////////////////////////////////////////////////////////

	exporter: {
		resources_workload.#Container
		resources_storage.#Volumes
		traits_workload.#RestartPolicy
		traits_workload.#UpdateStrategy
		traits_workload.#GracefulShutdown
		traits_security.#HostPID
		traits_security.#SecurityContext

		metadata: {
			name: "exporter"
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

			// hostPID required to enumerate and observe per-process GPU metrics on the host.
			hostPid: true

			container: {
				name: "intel-gpu-exporter"
				image: {
					repository: #config.image.repository
					tag:        #config.image.tag
					digest:     ""
					pullPolicy: #config.image.pullPolicy
				}

				volumeMounts: {
					// Intel GPU DRI device nodes — control (card*) and render (renderD*).
					"dev-dri": volumes["dev-dri"] & {
						mountPath: "/dev/dri"
					}
					// DRM sysfs — GPU topology and device info (read-only).
					"sysfs-drm": volumes["sysfs-drm"] & {
						mountPath: "/sys/class/drm"
						readOnly:  true
					}
				}

				resources: #config.resources

				// Privileged access required for direct GPU device and metric collection.
				securityContext: {
					privileged:               true
					allowPrivilegeEscalation: true
				}
			}

			// ── Volumes ────────────────────────────────────────────────────────
			volumes: {
				// Intel GPU DRI device nodes — control (card*) and render (renderD*).
				"dev-dri": {
					name: "dev-dri"
					hostPath: {
						path: "/dev/dri"
						type: "Directory"
					}
				}
				// DRM sysfs info — GPU topology enumeration (read-only).
				"sysfs-drm": {
					name: "sysfs-drm"
					hostPath: {
						path: "/sys/class/drm"
						type: "Directory"
					}
				}
			}

			// Security context — runs as root with full privilege
			// required for host GPU device access and process visibility.
			securityContext: {
				runAsNonRoot:             false
				runAsUser:                0
				allowPrivilegeEscalation: true
			}
		}
	}

}
