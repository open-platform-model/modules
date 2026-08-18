// Package intel_gpu_exporter defines the Intel GPU metrics exporter module.
// Deploys clambin/intel-gpu-exporter as a DaemonSet: it runs `intel_gpu_top`
// against an i915 GPU and republishes its output as Prometheus metrics:
// - module.cue:     metadata and config schema
// - components.cue: the DaemonSet + Service component
//
// Upstream: https://github.com/clambin/intel-gpu-exporter
// Pinned release: 0.6.1
//
// ⚠ NOT A PORT OF `intel_gpu_exporter@v0`. That module wraps Intel **XPU
// Manager**, which reads Data Center GPUs (Flex, Max) and Arc **Pro** through
// Level Zero and the Intel Graphics Compute Runtime. It does not support
// consumer Arc (Alchemist/DG2) parts at all. This module has the same name and
// a different upstream on purpose; the v0 one stays on the v0_legacy branch.
//
// ⚠ WHAT THIS ACTUALLY EXPORTS, measured rather than taken from the upstream
// README. On a discrete Arc A310 (DG2, i915) the only populated metric is:
//
//	gpumon_engine_usage{engine, attrib}
//	  engine = Video | VideoEnhance | Render/3D | Blitter | Compute
//	  attrib = busy | sema | wait
//
// `gpumon_power` is emitted but reads a constant **0**, because this card's
// `intel_gpu_top -J` output carries no `power` key. `gpumon_frequency`,
// `gpumon_rc6`, `gpumon_clients_count` and `gpumon_imc_*` are documented
// upstream but were not produced at all on this hardware. Treat the engine
// metrics as the deliverable and source power/temperature/fan elsewhere —
// node-exporter's hwmon collector already publishes them for the same card
// (`node_hwmon_*{chip_name="i915"}`), and they are real.
//
// ⚠ THE PUBLISHED IMAGE LAGS THE REPOSITORY, and `latest` is the worst of
// both. At the time of writing `latest` resolved to **0.3.1**, which has no
// `-device` flag, defaults its listener to `:9090` instead of `:9100`, and
// labels engines with an instance suffix (`Video/0`) that breaks any query
// written against the documented names. The newest published tag is 0.6.1
// while the repository is tagged v0.7.1. Pin a tag AND a digest; never track
// `latest`.
package intel_gpu_exporter

import (
	id "opmodel.dev/modules/intel_gpu_exporter/identity"
	m "opmodel.dev/core@v2"
	res "opmodel.dev/catalogs/opm/resources/v1beta1"
)

// Module definition
m.#Module

// Module metadata — modulePath is the COMPLETE CUE module path including the
// major, byte-identical to cue.mod's module field and identity/identity.cue;
// fqn/registryPath/uuid derive from it (enhancement 0010).
metadata: {
	name:        "intel_gpu_exporter"
	modulePath:  id.ModulePath
	version:     id.Version
	description: "Intel GPU exporter — republishes intel_gpu_top engine statistics for an i915 GPU as Prometheus metrics"
}

// Schema only — constraints for users, defaults matching the verified release.
#config: {
	// Container image for the exporter.
	image: res.#Image & {
		repository: string | *"ghcr.io/clambin/intel-gpu-exporter"
		// 0.6.1 is the newest tag published to ghcr; the repo is tagged v0.7.1.
		// See the header for why `latest` is not an option.
		tag: string | *"0.6.1"
		// Multi-arch index digest for 0.6.1. Both are set for the same reason
		// jellyfin's are: the digest binds, the tag makes the version legible.
		digest: string | *"sha256:a728c91fa413a298d6d64f201842ef0b665ccc0e809afa4d11bce7ff4711002e"
	}

	// Which GPU to read, passed through as intel_gpu_top's `-d`. Two accepted
	// spellings: "drm:/dev/dri/card0" or "pci:slot=0000:00:08.0".
	//
	// OPTIONAL, because on a host with a single i915 GPU intel_gpu_top picks
	// the right one unaided — but SET IT on any host with more than one GPU.
	// i915 registers a discrete card's PMU under a PCI-suffixed name
	// (`i915_0000_00_08.0`, not a bare `i915`), so an unqualified run can fail
	// or select the wrong device. Note that a non-Intel second GPU does not
	// create this ambiguity: intel_gpu_top only enumerates i915 devices.
	device?: string

	// Sampling interval passed to intel_gpu_top. The exporter re-reads its
	// subprocess's JSON at this rate; the scrape interval is independent and
	// should not be shorter.
	interval: string | *"5s"

	// Metrics listener. The default matches upstream 0.6.1 (`-prom.addr`).
	port: int & >0 & <=65535 | *9100

	// Path the metrics are served on (`-prom.path`).
	metricsPath: string | *"/metrics"

	// Exporter log level (`-log.level`).
	logLevel: "debug" | "info" | "warn" | "error" | *"info"

	// Host directory holding the DRI device nodes, mounted read-only.
	//
	// A hostPath and NOT a `gpu.intel.com/i915` resource claim, deliberately.
	// Extended resources are exclusive: the device plugin hands a card to
	// exactly one holder (`sharedDevNum` defaults to 1), and that holder should
	// be the workload doing the transcoding, not the observer watching it. A
	// claim here would either sit Pending forever or evict the real consumer.
	// Reading the PMU needs no allocation.
	driPath: string | *"/dev/dri"

	// Capabilities added so `perf_event_open` on the i915 PMU is permitted.
	//
	// PERFMON is the modern one; SYS_ADMIN covers kernels predating it. This is
	// deliberately NOT `privileged: true`, which is what the upstream example
	// asks for — verified sufficient on Talos with an Arc A310.
	//
	// ⚠ Added capabilities are forbidden by the `baseline` Pod Security
	// Standard, so this must run in a namespace enforcing `privileged`.
	capabilities: [...string] | *["PERFMON", "SYS_ADMIN"]

	// Explicit Service name, rendered verbatim instead of the default
	// {instance}-{component}. Set it when a scrape job matches the Service by
	// name — Prometheus/VictoriaMetrics `role: endpoints` discovery keeps
	// targets on `service_name;port_name`, which is a contract outside this
	// module. The port is always named `metrics`.
	serviceName?: string

	// Container resource requests and limits. The exporter is a thin wrapper
	// around one intel_gpu_top subprocess; the defaults are sized for that and
	// should be re-checked before shortening `interval`.
	resources: res.#ResourceRequirementsSchema | *{
		requests: {cpu: "10m", memory: "32Mi"}
		limits: {cpu: "200m", memory: "128Mi"}
	}

	// Which nodes the DaemonSet runs on. The default only excludes foreign
	// architectures; narrow it on a mixed cluster, e.g. with the NFD label
	// `intel.feature.node.kubernetes.io/gpu: "true"` where NFD is deployed.
	// Without a selector the DaemonSet lands on GPU-less nodes too, where the
	// exporter starts and reports nothing.
	nodeSelector: {[string]: string} | *{"kubernetes.io/arch": "amd64"}
}

debugValues: {
	image: {
		repository: "ghcr.io/clambin/intel-gpu-exporter"
		tag:        "0.6.1"
		digest:     "sha256:a728c91fa413a298d6d64f201842ef0b665ccc0e809afa4d11bce7ff4711002e"
	}
	device:      "drm:/dev/dri/card0"
	interval:    "5s"
	port:        9100
	metricsPath: "/metrics"
	logLevel:    "info"
	driPath:     "/dev/dri"
	capabilities: ["PERFMON", "SYS_ADMIN"]
	serviceName: "intel-gpu-exporter"
	resources: {
		requests: {cpu: "10m", memory: "32Mi"}
		limits: {cpu: "200m", memory: "128Mi"}
	}
	nodeSelector: {"kubernetes.io/arch": "amd64"}
}
