// Components for the nvidia-gpu-exporter module.
//
//	exporter — NVML/nvidia-smi reader (DaemonSet) + metrics Service
//
// The exporter reads the NVIDIA driver and republishes the result on an HTTP
// endpoint. It needs no Kubernetes API access — no ServiceAccount, Role or
// ClusterRole is emitted — and reaches the GPU through the `nvidia` RuntimeClass
// plus NVIDIA_VISIBLE_DEVICES, NOT through a device-plugin allocation. See
// module.cue for why that distinction is load-bearing.
package nvidia_gpu_exporter

import (
	"list"

	bp "opmodel.dev/catalogs/opm/blueprints/workload"
	tr "opmodel.dev/catalogs/opm/traits"
)

// Flags always present. Long-form kingpin names, verified against
// `nvidia_gpu_exporter --help` from the pinned 1.13.1 image rather than taken
// from the README — this argument list is version-specific and moves with the
// image pin.
_baseArgs: [
	"--web.listen-address", ":\(#config.port)",
	"--web.telemetry-path", #config.metricsPath,
	"--collect.backend", #config.backend,
	"--collect.interval", #config.collectInterval,
	"--collect.timeout", #config.collectTimeout,
	"--log.level", #config.logLevel,
]

// Appended only when non-empty. Passing an empty exclude list is harmless but
// noisy in `kubectl describe`, and an empty string is the schema default.
_excludeArgs: *[] | ["--query-field-names-exclude", #config.queryFieldNamesExclude]
if #config.queryFieldNamesExclude != "" {
	_excludeArgs: ["--query-field-names-exclude", #config.queryFieldNamesExclude]
}

// Boolean flag: present or absent, never `--flag=false`.
_pcieArgs: *[] | ["--collect.pcie-throughput"]
if #config.pcieThroughput {
	_pcieArgs: ["--collect.pcie-throughput"]
}

#components: {

	/////////////////////////////////////////////////////////////////
	//// Exporter — NVML reader (DaemonSet)
	/////////////////////////////////////////////////////////////////

	exporter: {
		bp.#DaemonWorkload
		tr.#Expose
		tr.#SecurityContext
		tr.#RuntimeClass
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
					name: "nvidia-gpu-exporter"
					image: {
						repository: #config.image.repository
						tag:        #config.image.tag
						digest:     #config.image.digest
						pullPolicy: #config.image.pullPolicy
					}

					args: list.Concat([_baseArgs, _excludeArgs, _pcieArgs])

					ports: metrics: {
						name:       "metrics"
						targetPort: #config.port
					}

					resources: #config.resources

					// Read by the container runtime, not by the exporter. Both
					// are required: without VISIBLE_DEVICES nothing is injected,
					// and without DRIVER_CAPABILITIES including `utility` the
					// device nodes appear but libnvidia-ml does not, so the
					// process starts and finds no GPU.
					env: {
						NVIDIA_VISIBLE_DEVICES: {
							name:  "NVIDIA_VISIBLE_DEVICES"
							value: #config.visibleDevices
						}
						NVIDIA_DRIVER_CAPABILITIES: {
							name:  "NVIDIA_DRIVER_CAPABILITIES"
							value: #config.driverCapabilities
						}
					}

					// Fully unprivileged, and unlike the Intel exporter that is
					// not a compromise: reading NVML through the injected device
					// nodes needs no capability at all. Every field below was
					// verified together on a Talos node with a Quadro P2200 —
					// non-root, all capabilities dropped, read-only rootfs, and
					// the exporter still reported live power and temperature.
					//
					// This means the module does NOT require a namespace
					// enforcing `privileged` PSS. It satisfies `restricted`.
					securityContext: {
						allowPrivilegeEscalation: false
						readOnlyRootFilesystem:   true
						runAsNonRoot:             true
						runAsUser:                65534
						runAsGroup:               65534
						capabilities: drop: ["ALL"]
					}
				}
			}

			// ⚠ REQUIRED. Without the nvidia RuntimeClass no driver is injected
			// and the exporter starts cleanly reporting nothing. Silent, not a
			// crash — which is why this is not optional in the schema either.
			runtimeClass: #config.runtimeClass

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
