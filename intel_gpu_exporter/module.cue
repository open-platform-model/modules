// Intel GPU Exporter — exports Intel GPU metrics as Prometheus metrics.
// Deploys a DaemonSet that reads GPU utilization, memory, temperature,
// and power data from the host and exposes them via a Prometheus-compatible
// HTTP endpoint at /metrics.
//
// Requires hostPID to enumerate and observe per-process GPU utilization.
// Designed as a companion to the intel-gpu-device-plugin module.
//
// https://github.com/intel/xpumanager
package intel_gpu_exporter

import (
	m "opmodel.dev/core/v1alpha1/module@v1"
	schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)

m.#Module

metadata: {
	modulePath:       "opmodel.dev/modules"
	name:             "intel-gpu-exporter"
	version:          "1.2.28"
	description:      "Intel GPU Exporter — exports Intel GPU utilization, memory, temperature, and power metrics as Prometheus metrics via XPU Manager"
	defaultNamespace: "monitoring"
	labels: {
		"app.kubernetes.io/component": "gpu-exporter"
	}
}

#config: {
	// Image configuration for the Intel GPU Exporter container.
	image: schemas.#Image & {
		// Full image repository path including registry.
		// Override to use a private mirror, e.g. "my-mirror.io/intel/xpumanager".
		repository: string | *"intel/xpumanager"
		// Exporter release tag. See https://github.com/intel/xpumanager/releases.
		tag: string | *"v1.2.27"
		// Image digest for the container.
		digest: string | *"sha256:7c2123abfdf87ba97fce3865e0db86a8728a8fefdebe96961ab066b2aabcbc86"
	}

	// metricsPort is the TCP port on which the Prometheus metrics endpoint is exposed.
	// The endpoint is available at http://<node-ip>:<metricsPort>/metrics.
	metricsPort: *9090 | int & >=1024 & <=65535

	// env configures environment variables passed to the exporter container.
	// These defaults enable XPU Manager's exporter-only mode which bypasses
	// the REST API and its TLS certificate requirement.
	env: {
		// Run in Prometheus exporter-only mode — skips REST API and TLS requirement.
		XPUM_EXPORTER_ONLY: string | *"1"
		// Disable authentication for the /metrics endpoint.
		XPUM_EXPORTER_NO_AUTH: string | *"1"
		// Disable TLS for the REST API (redundant with EXPORTER_ONLY but defensive).
		XPUM_REST_NO_TLS: string | *"1"
	}

	// Resource requests and limits for the exporter container.
	// Defaults sized for a lightweight metrics scrape process.
	resources: schemas.#ResourceRequirementsSchema & _ | *{
		requests: {cpu: "10m", memory: "30Mi"}
		limits: {cpu: "200m", memory: "128Mi"}
	}

	// nodeSelector restricts which nodes the DaemonSet is scheduled on.
	// Defaults to amd64 architecture. Add the NFD GPU label when NFD is deployed:
	//   "intel.feature.node.kubernetes.io/gpu": "true"
	nodeSelector: *{"kubernetes.io/arch": "amd64"} | {[string]: string}
}

// debugValues exercises the full #config surface for local `cue vet`.
debugValues: {
	image: {
		repository: "intel/xpumanager"
		tag:        "v1.2.27"
		digest:     "sha256:7c2123abfdf87ba97fce3865e0db86a8728a8fefdebe96961ab066b2aabcbc86"
	}
	metricsPort: 9090
	resources: {
		requests: {cpu: "10m", memory: "30Mi"}
		limits: {cpu: "200m", memory: "128Mi"}
	}
	nodeSelector: {
		"kubernetes.io/arch":                   "amd64"
		"intel.feature.node.kubernetes.io/gpu": "true"
	}
	env: {
		XPUM_EXPORTER_ONLY:    "1"
		XPUM_EXPORTER_NO_AUTH: "1"
		XPUM_REST_NO_TLS:      "1"
	}
}
