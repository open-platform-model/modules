// Intel GPU Device Plugin — exposes Intel GPUs as gpu.intel.com/i915 Kubernetes resources.
// Deploys a DaemonSet with the Intel GPU device plugin container, which registers
// gpu.intel.com/i915 and gpu.intel.com/xe extended resources with the kubelet.
//
// The plugin registers gpu.intel.com/i915 extended resources with each node's kubelet.
// Workloads request GPUs via: resources.limits["gpu.intel.com/i915"]: 1
//
// https://github.com/intel/intel-device-plugins-for-kubernetes
package intel_gpu_device_plugin

import (
	m "opmodel.dev/core/v1alpha1/module@v1"
	schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)

m.#Module

metadata: {
	modulePath:       "opmodel.dev/modules"
	name:             "intel-gpu-device-plugin"
	version:          "0.35.0"
	description:      "Intel GPU Device Plugin — exposes Intel GPUs (i915/Xe) as gpu.intel.com/i915 resources for Kubernetes workload scheduling"
	defaultNamespace: "kube-system"
	labels: {
		"app.kubernetes.io/component": "gpu-device-plugin"
	}
}

#config: {
	// Image configuration for the Intel GPU Device Plugin container.
	image: {
		// Full image repository path including registry.
		// Override to use a private mirror, e.g. "my-mirror.io/intel/intel-gpu-plugin".
		repository: string | *"intel/intel-gpu-plugin"
		// Plugin release tag. See https://github.com/intel/intel-device-plugins-for-kubernetes/releases.
		tag: string | *"0.35.0"
		// Image pull policy.
		pullPolicy: "Always" | *"IfNotPresent" | "Never"
	}

	// Number of containers that may simultaneously share a single GPU device.
	// Set > 1 for inference or low-intensity workloads that can time-share the GPU.
	// See: https://intel.github.io/intel-device-plugins-for-kubernetes/cmd/gpu_plugin/README.html
	sharedDevNum: int & >=1 | *1

	// Expose GPU utilization metrics via a Prometheus-compatible endpoint.
	// When true, passes -enable-monitoring to the plugin process.
	enableMonitoring: bool | *false

	// GPU allocation policy when multiple GPUs are available on a node.
	// "none":     any available GPU (first-fit, no ordering guarantee — default)
	// "balanced": distributes pods evenly across all GPUs
	// "packed":   fills one GPU fully before using the next
	allocationPolicy: *"none" | "balanced" | "packed"

	// Resource requests and limits for the device plugin container.
	// Defaults match the official upstream Intel manifest.
	resources: *{
		requests: {cpu: "40m", memory: "45Mi"}
		limits: {cpu: "100m", memory: "90Mi"}
	} | schemas.#ResourceRequirementsSchema

	// allowIds filters which GPUs the plugin manages by PCI device ID.
	// Comma-separated list of hex IDs (e.g. "0x49c5,0x49c6").
	// Empty string means all detected Intel GPUs are managed.
	// Maps to the -allow-ids CLI flag.
	allowIds: *"" | string

	// denyIds excludes specific GPUs from plugin management by PCI device ID.
	// Comma-separated list of hex IDs (e.g. "0x56c0").
	// Empty string means no GPUs are excluded.
	// Maps to the -deny-ids CLI flag.
	denyIds: *"" | string

	// healthManagement enables GPU health monitoring via the levelzero sidecar.
	// Requires a separate intel-gpu-levelzero sidecar container to be deployed.
	// Maps to the -health-management CLI flag.
	healthManagement: *false | bool

	// bypath controls how DRM by-path symlinks are exposed in containers.
	//   "single" (default): mounts by-path symlinks individually per GPU device.
	//   "none": no by-path symlinks — use when containers have all device files.
	//   "all": mounts the entire /dev/dri/by-path/ directory (best for scale-up).
	// Maps to the -bypath CLI flag.
	bypath: *"single" | "none" | "all"

	// logLevel sets the plugin log verbosity (0 = minimal, 4 = verbose debug).
	// Maps to the -v CLI flag.
	logLevel: *2 | int & >=0 & <=4

	// tempLimit sets a global GPU temperature limit in Celsius.
	// When non-zero, devices exceeding this limit are marked unhealthy.
	// Requires healthManagement: true. 0 = disabled.
	// Maps to the -temp-limit CLI flag.
	tempLimit: *0 | int & >=0

	// gpuTempLimit sets a GPU-core-specific temperature limit in Celsius.
	// When non-zero, overrides tempLimit for GPU core temperature.
	// Requires healthManagement: true. 0 = disabled.
	// Maps to the -gpu-temp-limit CLI flag.
	gpuTempLimit: *0 | int & >=0

	// memoryTempLimit sets a GPU-memory-specific temperature limit in Celsius.
	// When non-zero, overrides tempLimit for GPU memory temperature.
	// Requires healthManagement: true. 0 = disabled.
	// Maps to the -memory-temp-limit CLI flag.
	memoryTempLimit: *0 | int & >=0

	// nodeSelector restricts which nodes the DaemonSet is scheduled on.
	// Defaults to amd64 architecture, matching the official upstream manifest.
	// Add "intel.feature.node.kubernetes.io/gpu": "true" when NFD is deployed.
	nodeSelector: *{"kubernetes.io/arch": "amd64"} | {[string]: string}
}

// debugValues exercises the full #config surface for local `cue vet`.
debugValues: {
	image: {
		repository: "intel/intel-gpu-plugin"
		tag:        "0.35.0"
		pullPolicy: "IfNotPresent"
	}
	sharedDevNum:     2
	enableMonitoring: true
	allocationPolicy: "balanced"
	resources: {
		requests: {
			cpu:    "40m"
			memory: "45Mi"
		}
		limits: {
			cpu:    "100m"
			memory: "90Mi"
		}
	}
	allowIds:         "0x49c5,0x49c6"
	denyIds:          "0x56c0"
	healthManagement: true
	bypath:           "all"
	logLevel:         3
	tempLimit:        80
	gpuTempLimit:     85
	memoryTempLimit:  75
	nodeSelector: {
		"kubernetes.io/arch":                   "amd64"
		"intel.feature.node.kubernetes.io/gpu": "true"
	}
}
