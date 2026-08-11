// Package nvidia_device_plugin defines the NVIDIA GPU device plugin module.
// Deploys the plugin as a DaemonSet that registers NVIDIA GPUs with each node's
// kubelet as schedulable `nvidia.com/gpu` resources:
// - module.cue:     metadata and config schema
// - components.cue: the DaemonSet component
//
// Upstream: https://github.com/NVIDIA/k8s-device-plugin
// Pinned upstream release: v0.19.3
//
// The plugin needs NO Kubernetes API access — it speaks the device-plugin gRPC
// protocol to the kubelet over a socket — so this module emits no
// ServiceAccount, Role or RoleBinding.
//
// ⚠ RUNTIME CLASS. The plugin only sees a GPU when its pod runs under the
// NVIDIA container runtime. On Talos the `nvidia-container-toolkit` system
// extension registers an `nvidia` containerd handler, and Sidero deliberately
// does NOT make it the node-wide default — so `runtimeClassName` is required,
// matching upstream's `--set=runtimeClassName=nvidia`. A cluster RuntimeClass
// of that name must already exist; this module references it, it does not
// create it:
//
//	apiVersion: node.k8s.io/v1
//	kind: RuntimeClass
//	metadata: {name: nvidia}
//	handler: nvidia
//
// Set `runtimeClass: ""` only on clusters where the NVIDIA runtime is already
// the default; the field is then omitted entirely.
//
// ⚠ The NODE must already have a working NVIDIA driver. On Talos that means the
// `nonfree-kmod-nvidia-*` and `nvidia-container-toolkit-*` system extensions at
// a MATCHING driver version, plus the nvidia/nvidia_uvm/nvidia_drm/nvidia_modeset
// kernel modules in machine config. Pascal-era cards (and older) must use the
// `-lts` branch: 580 is the last driver line supporting Maxwell/Pascal/Volta,
// and the open-GPU kernel modules need Turing or newer. Without a driver the
// plugin crashes or advertises zero devices.
package nvidia_device_plugin

import (
	m "opmodel.dev/core@v2"
	res "opmodel.dev/catalogs/opm/resources/v1beta1"
)

// Module definition
m.#Module

// Module metadata — modulePath is the COMPLETE CUE module path including the
// major, byte-identical to cue.mod's module field and identity/identity.cue;
// fqn/registryPath/uuid derive from it (enhancement 0010).
metadata: {
	name:        "nvidia_device_plugin"
	modulePath:  "opmodel.dev/modules/nvidia_device_plugin@v2"
	version:     "2.0.0"
	description: "NVIDIA GPU device plugin — exposes NVIDIA GPUs as nvidia.com/gpu resources for Kubernetes workload scheduling"
}

// Schema only — constraints for users, defaults matching the upstream manifest.
#config: {
	// Image configuration for the device plugin container.
	image: res.#Image & {
		repository: string | *"nvcr.io/nvidia/k8s-device-plugin"
		// Plugin release tag. See
		// https://github.com/NVIDIA/k8s-device-plugin/releases.
		tag:    string | *"v0.19.3"
		digest: string | *""
	}

	// Name of the cluster RuntimeClass whose handler is the NVIDIA container
	// runtime. Required on Talos and on any cluster that has not made the
	// NVIDIA runtime the containerd default. Set to "" to omit the field.
	runtimeClass: string | *"nvidia"

	// How GPUs are advertised to the kubelet.
	//   "none"   — one nvidia.com/gpu per physical GPU (default)
	//   "time-slicing" / "mps" require an additional config file and are NOT
	//   modelled here; use deviceListStrategy/config upstream instead.
	// Maps to the plugin's default behaviour; exposed for documentation only.
	migStrategy: *"none" | "single" | "mixed"

	// How the plugin tells the runtime which devices to inject.
	//   "envvar"      — NVIDIA_VISIBLE_DEVICES (default, works everywhere)
	//   "volume-mounts" — for runtimes that do not read the env var
	//   "cdi-annotations" / "cdi-cri" — Container Device Interface
	// Maps to --device-list-strategy.
	deviceListStrategy: *"envvar" | "volume-mounts" | "cdi-annotations" | "cdi-cri"

	// Fail the plugin instead of degrading when a GPU has a problem
	// (e.g. XID errors, ECC failures). Maps to --fail-on-init-error.
	failOnInitError: bool | *true

	// Pass device nodes' major/minor to the container rather than device paths.
	// Maps to --pass-device-specs.
	passDeviceSpecs: bool | *false

	// Resource requests and limits (optional — omit to use cluster defaults).
	// Upstream ships none.
	resources?: res.#ResourceRequirementsSchema

	// Restrict which nodes the DaemonSet runs on. Empty by default, matching
	// upstream, which relies on the toleration below plus node labels. Set
	// e.g. {"nvidia.com/gpu.present": "true"} when NFD/GFD is deployed, so the
	// plugin does not run on nodes with no NVIDIA GPU.
	nodeSelector: {[string]: string} | *{}

	// Scheduling priority. Upstream uses system-node-critical so the plugin is
	// not evicted before the workloads that depend on it.
	priorityClassName: string | *"system-node-critical"
}

// debugValues exercises the full #config surface for local `cue vet` / `cue eval`.
debugValues: {
	image: {
		repository: "nvcr.io/nvidia/k8s-device-plugin"
		tag:        "v0.19.3"
		digest:     ""
		pullPolicy: "IfNotPresent"
	}
	runtimeClass:       "nvidia"
	migStrategy:        "none"
	deviceListStrategy: "envvar"
	failOnInitError:    true
	passDeviceSpecs:    false
	resources: {
		requests: {
			cpu:    "50m"
			memory: "64Mi"
		}
		limits: {
			cpu:    "200m"
			memory: "128Mi"
		}
	}
	nodeSelector: "nvidia.com/gpu.present": "true"
	priorityClassName: "system-node-critical"
}
