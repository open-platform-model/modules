// Package intel_gpu_device_plugin defines the Intel GPU device plugin module.
// Deploys the plugin as a DaemonSet that registers Intel GPUs with each node's
// kubelet as schedulable `gpu.intel.com/i915` / `gpu.intel.com/xe` resources:
// - module.cue:     metadata and config schema
// - components.cue: the DaemonSet component
//
// Upstream: https://github.com/intel/intel-device-plugins-for-kubernetes
// Pinned upstream release: v0.36.0
//
// Ported from the OPM v0 module (`intel_gpu_device_plugin@v0`, last published
// v0.0.14 against upstream 0.35.0) onto the v1 catalog. Config surface is
// preserved; see DEPLOYMENT_NOTES.md for what changed.
//
// OPM v2 line: path major v2 (the v1 train publishes this registry path at
// major v1 — cross-train major separation), core@v2 identity reshape
// (complete modulePath with major, identity/ package, derived fqn), and the
// version-segment catalog imports (resources/v1beta1 etc.).
//
// The plugin needs NO Kubernetes API access — it speaks the device-plugin gRPC
// protocol to the kubelet over a socket — so this module emits no
// ServiceAccount, Role or RoleBinding.
//
// ⚠ The NODE must already have a working Intel GPU driver; this module only
// advertises what the kernel exposes. On Talos that means the `siderolabs/i915`
// system extension, plus `siderolabs/mei` for Arc discrete GPUs (the Management
// Engine is a prerequisite for them). Without a driver the plugin starts
// cleanly and advertises zero devices, which presents as a scheduling problem
// rather than a missing driver.
package intel_gpu_device_plugin

import (
	id "opmodel.dev/modules/intel_gpu_device_plugin/identity"
	m "opmodel.dev/core@v2"
	res "opmodel.dev/catalogs/opm/resources/v1beta1"
)

// Module definition
m.#Module

// Module metadata — modulePath is the COMPLETE CUE module path including the
// major, byte-identical to cue.mod's module field and identity/identity.cue;
// fqn/registryPath/uuid derive from it (enhancement 0010).
metadata: {
	name:        "intel_gpu_device_plugin"
	modulePath:  id.ModulePath
	version:     id.Version
	description: "Intel GPU device plugin — exposes Intel GPUs (i915/Xe) as gpu.intel.com resources for Kubernetes workload scheduling"
}

// Schema only — constraints for users, defaults matching the upstream manifest.
#config: {
	// Image configuration for the Intel GPU device plugin container.
	image: res.#Image & {
		// Override to use a private mirror, e.g. "my-mirror.io/intel/intel-gpu-plugin".
		repository: string | *"intel/intel-gpu-plugin"
		// Plugin release tag. See
		// https://github.com/intel/intel-device-plugins-for-kubernetes/releases.
		tag:    string | *"0.36.0"
		digest: string | *""
	}

	// Number of containers that may simultaneously share a single GPU device.
	// Set > 1 for inference or transcoding workloads that can time-share a GPU.
	//
	// ⚠ This is plain overcommit — the plugin hands out more references to the
	// same device. There is no isolation, quota or fair-share between them.
	sharedDevNum: int & >=1 | *1

	// Expose GPU utilization metrics via a Prometheus-compatible endpoint.
	// Passes -enable-monitoring.
	enableMonitoring: bool | *false

	// GPU allocation policy when a node has multiple GPUs.
	//   "none":     any available GPU (first-fit, no ordering guarantee)
	//   "balanced": distribute pods evenly across all GPUs
	//   "packed":   fill one GPU fully before using the next
	allocationPolicy: *"none" | "balanced" | "packed"

	// Resource requests and limits. Defaults match the upstream manifest.
	resources: *{
		requests: {cpu: "40m", memory: "45Mi"}
		limits: {cpu: "100m", memory: "90Mi"}
	} | res.#ResourceRequirementsSchema

	// Filter which GPUs the plugin manages by PCI device ID. Comma-separated
	// hex IDs (e.g. "0x49c5,0x49c6"). Empty means all detected Intel GPUs.
	// Maps to -allow-ids.
	allowIds: *"" | string

	// Exclude specific GPUs by PCI device ID. Comma-separated hex IDs
	// (e.g. "0x56c0"). Empty means nothing is excluded. Maps to -deny-ids.
	denyIds: *"" | string

	// Enable GPU health monitoring via the levelzero sidecar. Requires a
	// separate intel-gpu-levelzero sidecar to be deployed. Maps to
	// -health-management. The temperature limits below do nothing without it.
	healthManagement: *false | bool

	// How DRM by-path symlinks are exposed in containers.
	//   "single" (default): mount by-path symlinks individually per GPU
	//   "none":             no by-path symlinks — containers have all device files
	//   "all":              mount the whole /dev/dri/by-path/ directory
	// Maps to -bypath.
	bypath: *"single" | "none" | "all"

	// Plugin log verbosity (0 = minimal, 4 = verbose debug). Maps to -v.
	logLevel: *2 | int & >=0 & <=4

	// Global GPU temperature limit in Celsius; devices above it are marked
	// unhealthy. 0 disables. Requires healthManagement. Maps to -temp-limit.
	tempLimit: *0 | int & >=0

	// GPU-core temperature limit in Celsius, overriding tempLimit for the core.
	// 0 disables. Requires healthManagement. Maps to -gpu-temp-limit.
	gpuTempLimit: *0 | int & >=0

	// GPU-memory temperature limit in Celsius, overriding tempLimit for memory.
	// 0 disables. Requires healthManagement. Maps to -memory-temp-limit.
	memoryTempLimit: *0 | int & >=0

	// Restrict which nodes the DaemonSet runs on. Defaults to amd64, matching
	// upstream. Add "intel.feature.node.kubernetes.io/gpu": "true" when NFD is
	// deployed, so the plugin does not run on nodes with no Intel GPU.
	nodeSelector: *{"kubernetes.io/arch": "amd64"} | {[string]: string}
}

// debugValues exercises the full #config surface for local `cue vet` / `cue eval`.
debugValues: {
	image: {
		repository: "intel/intel-gpu-plugin"
		tag:        "0.36.0"
		digest:     ""
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
