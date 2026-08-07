// Components for the intel-gpu-exporter module.
//
//	exporter — intel_gpu_top wrapper (DaemonSet) + metrics Service
//
// The exporter shells out to `intel_gpu_top -J` and republishes its engine
// statistics on an HTTP endpoint. It needs no Kubernetes API access — no
// ServiceAccount, Role or ClusterRole is emitted — and reaches the GPU through
// a read-only /dev/dri host mount plus the i915 PMU, not through a device-plugin
// allocation. See module.cue for why that distinction is load-bearing.
package intel_gpu_exporter

import (
	"list"

	bp "opmodel.dev/catalogs/opm/blueprints/workload"
	res "opmodel.dev/catalogs/opm/resources"
	tr "opmodel.dev/catalogs/opm/traits"
)

// Flags always present. Long-form names match upstream 0.6.1 — `-prom.addr`
// and `-prom.path` did not exist before 0.6.0 (0.3.1, which `latest` still
// points at, listens on :9090 via a bare `-addr`), so this argument list is
// version-specific and moves with the image pin.
_baseArgs: [
	"-interval", #config.interval,
	"-prom.addr", ":\(#config.port)",
	"-prom.path", #config.metricsPath,
	"-log.level", #config.logLevel,
]

// Appended only when set. Omitting it lets intel_gpu_top choose, which is
// correct on a single-i915 host and wrong on any other.
_deviceArgs: *[] | ["-device", #config.device]
if #config.device != _|_ {
	_deviceArgs: ["-device", #config.device]
}

#components: {

	/////////////////////////////////////////////////////////////////
	//// Exporter — intel_gpu_top wrapper (DaemonSet)
	/////////////////////////////////////////////////////////////////

	exporter: {
		bp.#DaemonWorkload
		res.#Volumes
		tr.#Expose
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
					name: "intel-gpu-exporter"
					image: {
						repository: #config.image.repository
						tag:        #config.image.tag
						digest:     #config.image.digest
						pullPolicy: #config.image.pullPolicy
					}

					args: list.Concat([_baseArgs, _deviceArgs])

					ports: metrics: {
						name:       "metrics"
						targetPort: #config.port
					}

					resources: #config.resources

					volumeMounts: "dev-dri": spec.volumes."dev-dri" & {
						mountPath: #config.driPath
						readOnly:  true
					}

					// Capabilities rather than `privileged: true` — the upstream
					// example asks for privileged, and it is more than the job
					// needs. Verified: PERFMON + SYS_ADMIN is enough to
					// perf_event_open the i915 PMU.
					//
					// readOnlyRootFilesystem is deliberately NOT set: the
					// exporter forks intel_gpu_top, and nothing upstream states
					// whether igt-gpu-tools writes under / at runtime. Left
					// alone rather than asserted and discovered in production.
					securityContext: {
						allowPrivilegeEscalation: false
						capabilities: add: #config.capabilities
					}
				}
			}

			volumes: "dev-dri": {
				name:     "dev-dri"
				readOnly: true
				hostPath: {
					// Directory, not DirectoryOrCreate: if /dev/dri is absent
					// the node has no DRM device at all, and failing to mount is
					// a better outcome than an exporter reporting a healthy
					// nothing from an empty directory it created itself.
					path: #config.driPath
					type: "Directory"
				}
			}

			// Scrape target. The port name `metrics` is fixed, because endpoint
			// discovery keeps targets on service_name;port_name.
			expose: {
				ports: metrics: daemonWorkload.container.ports.metrics & {
					exposedPort: #config.port
				}
				type: "ClusterIP"
				if #config.serviceName != _|_ {
					name: #config.serviceName
				}
			}

			// Nothing to drain: the process holds no state and no connections
			// worth finishing. The default 30s would only slow a rollout.
			gracefulShutdown: terminationGracePeriodSeconds: 10

			podScheduling: nodeSelector: #config.nodeSelector
		}
	}
}
