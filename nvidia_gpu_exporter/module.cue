// Package nvidia_gpu_exporter defines the NVIDIA GPU metrics exporter module.
// Deploys utkuozdemir/nvidia_gpu_exporter as a DaemonSet: it reads the NVIDIA
// driver (through libnvidia-ml, or by shelling out to nvidia-smi) and publishes
// the result as Prometheus metrics:
// - module.cue:     metadata and config schema
// - components.cue: the DaemonSet + Service component
//
// Upstream: https://github.com/utkuozdemir/nvidia_gpu_exporter
// Pinned release: 1.13.1 (the `-nvml` image variant)
//
// ⚠ 1.13.1 IS NEWER THAN 1.3.2. Semver, not decimals. `1.3.2` is an old tag
// that reads newer at a glance and is exactly what a careless pin lands on.
// Pin the digest as well as the tag.
//
// ⚠ WHY NOT DCGM. NVIDIA's own dcgm-exporter is the obvious institutional
// choice and it does work — but measured against a Pascal Quadro P2200 it costs
// **399 MiB** resident versus **22.7 MiB** here, requires SYS_ADMIN, and
// materialises only **15 of its 26 default fields**. The eleven that never
// appear include DCGM_FI_DEV_XID_ERRORS and every DCGM_FI_PROF_* field, and
// DCGM_FI_DEV_MEMORY_TEMP is reported as a confident `0` on a card that has no
// memory-temperature sensor. It also cannot report NVENC session count, which
// is the single most useful signal for a transcoding host. DCGM becomes the
// right answer on datacenter silicon; it is not the right answer for one
// Quadro encoding video.
//
// ⚠ THIS MODULE MUST NOT CLAIM `nvidia.com/gpu`, and does not. Extended
// resources are exclusive: the device plugin hands a card to exactly one holder,
// and that holder should be the workload doing the transcoding, not the observer
// watching it. Instead the container joins the `nvidia` RuntimeClass and sets
// NVIDIA_VISIBLE_DEVICES, which makes the container runtime inject the driver
// and device nodes with no scheduler allocation involved. Verified: with a
// separate pod holding the node's only `nvidia.com/gpu` AND an encode running,
// this exporter kept reading the card.
//
// ⚠ NVIDIA_VISIBLE_DEVICES READS BACK AS `void` INSIDE THE CONTAINER. The
// runtime consumes the variable, converts it into device injection, and rewrites
// it so the legacy hook cannot inject twice. A container with full GPU access
// reports `void`. Do not use it to debug whether injection worked — use
// `nvidia-smi -L`.
//
// ⚠ UTILISATION METRICS ARE RATIOS (0–1), NOT PERCENTAGES.
// `nvidia_smi_utilization_encoder_ratio` reads 0.17 for 17 %. Any dashboard
// sharing an axis with a percentage-native exporter must scale by 100.
package nvidia_gpu_exporter

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
	name:        "nvidia_gpu_exporter"
	modulePath:  "opmodel.dev/modules/nvidia_gpu_exporter@v2"
	version:     "2.0.0"
	description: "NVIDIA GPU exporter — publishes NVML/nvidia-smi statistics, including NVENC/NVDEC utilisation and encoder session count, as Prometheus metrics"
}

// Schema only — constraints for users, defaults matching the verified release.
#config: {
	// Container image for the exporter.
	image: res.#Image & {
		repository: string | *"docker.io/utkuozdemir/nvidia_gpu_exporter"
		// The `-nvml` variant differs from the plain tag only in which backend
		// it defaults to; both binaries carry both. See `backend` below.
		tag: string | *"1.13.1-nvml"
		// Multi-arch index digest for 1.13.1-nvml. Both are set for the same
		// reason jellyfin's are: the digest binds, the tag makes it legible.
		digest: string | *"sha256:3110be7b635d3df7dc836fead45abf19d15819a3dd44f18081a4b90a88db9840"
	}

	// How the exporter reads the GPU (`--collect.backend`).
	//
	//	nvml — reads libnvidia-ml directly. No subprocess per scrape.
	//	exec — forks `nvidia-smi` on every scrape.
	//	demo — synthetic data, no GPU or driver needed.
	//
	// `nvml` is the default because it removes a process fork per scrape
	// forever, which matters at a 15s interval. Measured on a Quadro P2200:
	// nvml 22.7 MiB resident / 83 metric names, exec 7.5 MiB / 87 names.
	//
	// ⚠ Upstream marks the nvml backend EXPERIMENTAL. `exec` is the fallback and
	// is a one-field change — that is why this is config and not hardcoded. Note
	// that switching to `exec` does NOT require changing the image.
	//
	// `demo` exists for rendering and dashboard work on a machine with no GPU.
	// It must never reach a real cluster: it serves plausible fabricated numbers,
	// which is worse than serving none.
	backend: "nvml" | "exec" | "demo" | *"nvml"

	// Metrics listener (`--web.listen-address`). 9835 is upstream's default and
	// its EXPOSEd port.
	port: int & >0 & <=65535 | *9835

	// Path the metrics are served on (`--web.telemetry-path`).
	metricsPath: string | *"/metrics"

	// Background collection interval (`--collect.interval`).
	//
	// "0" means collect synchronously on each scrape, which is what makes the
	// numbers align with the scrape timestamp. Set a duration only to decouple
	// an expensive collection from scrape latency; the cost is that every
	// scrape then serves a result up to that old, and NVENC utilisation is a
	// duty cycle over a sampling window already.
	collectInterval: string | *"0"

	// Maximum duration of one collection cycle (`--collect.timeout`).
	collectTimeout: string | *"10s"

	// Exporter log level (`--log.level`).
	logLevel: "debug" | "info" | "warn" | "error" | *"info"

	// Query fields to skip (`--query-field-names-exclude`), comma-separated,
	// `*` acting as a wildcard. Empty means query everything auto-detected.
	//
	// The escape hatch for a field that is slow or unsupported on a given card.
	// Older silicon is where this earns its place: a field the driver refuses
	// can otherwise make every scrape pay a timeout.
	queryFieldNamesExclude: string | *""

	// Collect PCIe throughput (`--collect.pcie-throughput`). Off by default —
	// it is a sampled counter that costs a driver round-trip per scrape and says
	// nothing about transcoding, which is what this module exists to watch.
	pcieThroughput: bool | *false

	// RuntimeClass the pod runs under.
	//
	// ⚠ REQUIRED, NOT DECORATIVE. Without it the container gets the default
	// runtime, no driver or device nodes are injected, and the exporter starts
	// cleanly and reports nothing — a silent failure, not a crash. The name must
	// match a RuntimeClass object that exists in the cluster; the NVIDIA device
	// plugin's standard install creates one called `nvidia`.
	runtimeClass: string | *"nvidia"

	// NVIDIA_VISIBLE_DEVICES. `all` is correct for an observer that should watch
	// whatever the node has, and is what allows this DaemonSet to coexist with
	// the workload holding the extended resource. Narrow it to a UUID or index
	// only to deliberately watch one card of several.
	visibleDevices: string | *"all"

	// NVIDIA_DRIVER_CAPABILITIES.
	//
	// `utility` alone is enough — it is what supplies libnvidia-ml and
	// nvidia-smi, and it was verified sufficient for every metric this module
	// publishes. Deliberately narrower than a transcoding workload's
	// `compute,video,utility`: this container reads counters and never encodes.
	driverCapabilities: string | *"utility"

	// Explicit Service name, rendered verbatim instead of the default
	// {instance}-{component}. Set it when a scrape job matches the Service by
	// name — Prometheus/VictoriaMetrics `role: endpoints` discovery keeps
	// targets on `service_name;port_name`, which is a contract outside this
	// module. The port is always named `metrics`.
	serviceName?: string

	// Container resource requests and limits. Measured 22.7 MiB resident on the
	// nvml backend with one GPU; the limit leaves room for a second card and for
	// the exec backend's transient nvidia-smi fork.
	resources: res.#ResourceRequirementsSchema | *{
		requests: {cpu: "10m", memory: "48Mi"}
		limits: {cpu: "100m", memory: "128Mi"}
	}

	// Which nodes the DaemonSet runs on.
	//
	// ⚠ THE DEFAULT IS AN ARCHITECTURE FILTER, NOT A GPU FILTER. On a mixed
	// cluster this DaemonSet lands on GPU-less nodes, where the runtime has no
	// driver to inject and the pod fails to start. There is no node label to
	// select on unless something publishes one: the plain device plugin does not
	// label nodes, and NFD is a separate install. Where NFD is deployed, narrow
	// this to `feature.node.kubernetes.io/pci-10de.present: "true"`.
	nodeSelector: {[string]: string} | *{"kubernetes.io/arch": "amd64"}
}

debugValues: {
	image: {
		repository: "docker.io/utkuozdemir/nvidia_gpu_exporter"
		tag:        "1.13.1-nvml"
		digest:     "sha256:3110be7b635d3df7dc836fead45abf19d15819a3dd44f18081a4b90a88db9840"
	}
	backend:                "nvml"
	port:                   9835
	metricsPath:            "/metrics"
	collectInterval:        "0"
	collectTimeout:         "10s"
	logLevel:               "info"
	queryFieldNamesExclude: ""
	pcieThroughput:         false
	runtimeClass:           "nvidia"
	visibleDevices:         "all"
	driverCapabilities:     "utility"
	serviceName:            "nvidia-gpu-exporter"
	resources: {
		requests: {cpu: "10m", memory: "48Mi"}
		limits: {cpu: "100m", memory: "128Mi"}
	}
	nodeSelector: {"kubernetes.io/arch": "amd64"}
}
