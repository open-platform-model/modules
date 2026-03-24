// Intel GPU Device Plugin — exposes Intel GPUs as gpu.intel.com/i915 Kubernetes resources.
// Deploys a DaemonSet with an init container (GPU presence probe) and the device plugin
// container, plus a ClusterRole + ClusterRoleBinding for the plugin ServiceAccount.
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
		// Override to use a private mirror, e.g. "my-mirror.io/intel/intel-gpu-device-plugin".
		repository: string | *"intel/intel-gpu-device-plugin"
		// Plugin release tag. See https://github.com/intel/intel-device-plugins-for-kubernetes/releases.
		tag: string | *"0.35.0"
		// Image pull policy.
		pullPolicy: "Always" | *"IfNotPresent" | "Never"
	}

	// Image configuration for the init container.
	// The init container probes for an Intel GPU before the plugin starts,
	// preventing the plugin from registering zero resources with kubelet.
	initImage: {
		// Full image repository path for the init container.
		repository: string | *"intel/intel-gpu-initcontainer"
		// Init container release tag — should match the plugin image tag.
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

	// When true, the init container exits non-zero if no Intel GPU is detected,
	// causing the DaemonSet pod to crash-loop on nodes without an Intel GPU.
	// Set false on mixed-GPU clusters where some nodes may not have Intel GPUs.
	failOnInitError: bool | *true

	// Resource requests and limits for the device plugin container.
	// The plugin is lightweight — upstream defaults require minimal resources.
	resources?: schemas.#ResourceRequirementsSchema
}

// debugValues exercises the full #config surface for local `cue vet`.
debugValues: {
	image: {
		repository: "intel/intel-gpu-device-plugin"
		tag:        "0.35.0"
		pullPolicy: "IfNotPresent"
	}
	initImage: {
		repository: "intel/intel-gpu-initcontainer"
		tag:        "0.35.0"
		pullPolicy: "IfNotPresent"
	}
	sharedDevNum:     2
	enableMonitoring: true
	allocationPolicy: "balanced"
	failOnInitError:  false
	resources: {
		requests: {
			cpu:    "100m"
			memory: "128Mi"
		}
		limits: {
			cpu:    "200m"
			memory: "256Mi"
		}
	}
}
