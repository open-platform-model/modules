// Package jellyfin defines the Jellyfin media server module.
// A single-container stateful application using the LinuxServer.io image:
// - module.cue:     metadata and config schema
// - components.cue: component definitions (catalog_opm blueprints/traits)
//
// Rebased onto the OPM core catalog (opmodel.dev/catalogs/opm@v1). The previous
// K8up backup feature has been dropped — the core catalog has no backup
// resource. Config storage, media mounts, the web Service, optional hardware
// transcoding, optional Gateway HTTPRoute, and optional Serilog logging remain.
package jellyfin

import (
	m "opmodel.dev/core@v1"
	res "opmodel.dev/catalogs/opm/resources"
	tr "opmodel.dev/catalogs/opm/traits"
)

// Module definition
m.#Module

// Module metadata
metadata: {
	modulePath:  "opmodel.dev/modules"
	name:        "jellyfin"
	version:     "2.5.0"
	description: "Jellyfin media server - a free software media system"
}

// #storageVolume is the shared schema for all storage entries.
// Both config and media mounts use this same shape.
#storageVolume: {
	mountPath:     string
	type:          "pvc" | "emptyDir" | "nfs"
	size?:         string // required when type == "pvc"
	storageClass?: string // optional, only used when type == "pvc"
	server?:       string // required when type == "nfs"
	path?:         string // required when type == "nfs"

	// Mount this volume read-only. Applied to BOTH the volume source and the
	// container's volumeMount — setting only the mount still leaves the volume
	// itself writable to anything else that attaches it.
	//
	// Defaults false, so existing instances are unchanged. Set it on media
	// libraries shared with another server: Jellyfin writes sidecar metadata
	// (.nfo, .jpg, poster/fanart) back into the media tree on a metadata
	// refresh, so two servers pointed at one dataset can each rewrite the
	// other's files. Usually benign when both run the same providers — a
	// genuine delete or a divergent refresh is not.
	//
	// Leave false for `config`, which Jellyfin must write.
	readOnly: bool | *false
}

// Schema only - constraints for users, no defaults beyond sensible image/port.
#config: {
	// Container image
	image: res.#Image & {
		repository: string | *"linuxserver/jellyfin"
		tag:        string | *"latest"
		digest:     string | *""
	}

	// Exposed service port for the web UI
	port: int & >0 & <=65535 | *8096

	// LinuxServer.io user/group identity
	puid: int | *1000
	pgid: int | *1000

	// Container timezone
	timezone: string | *"Europe/Stockholm"

	// Optional: published server URL for client auto-discovery
	publishedServerUrl?: string

	// Storage: config is required; media mounts are optional.
	storage: {
		// Application data — defaults to a 10Gi PVC mounted at /config
		config: #storageVolume & {
			mountPath: *"/config" | string
			type:      *"pvc" | "emptyDir" | "nfs"
			size:      string | *"10Gi"
		}
		// Media library mounts keyed by library name (e.g. "movies", "series")
		media?: [Name=string]: #storageVolume
	}

	// Kubernetes Service type for the Jellyfin web UI
	serviceType: "ClusterIP" | "NodePort" | "LoadBalancer" | *"ClusterIP"

	// Optional Gateway API HTTPRoute for ingress routing.
	// When set, an HTTPRoute resource is created pointing to the jellyfin service.
	httpRoute?: {
		hostnames: [...string]
		gatewayRef?: {
			name:      string
			namespace: string
		}
	}

	// Container resource requests and limits.
	// When absent, no resource constraints are applied to the container.
	//
	// A GPU claim can be written here directly as `resources.gpu`, and instances
	// predating v2.5.0 do exactly that. Prefer `hardwareAcceleration` below —
	// the claim is only ever half of what a GPU needs, and this field cannot
	// express the other half.
	resources?: res.#ResourceRequirementsSchema

	// Optional hardware transcoding. Attaches exactly ONE GPU to the container
	// and derives everything that vendor needs from a single field.
	//
	// ONE CARD AT A TIME BY CONSTRUCTION. `vendor` is a scalar, so this cannot
	// express "both cards" — deliberately. Extended resources are not shareable:
	// a node's GPU has exactly one holder (the Intel plugin's sharedDevNum
	// defaults to 1, and raising it is plain overcommit with no isolation,
	// quota or fair-share), so claiming a second card here would strand every
	// other GPU consumer on the node. Switching card is a one-word edit plus
	// one pod restart.
	//
	// Why a discriminator rather than the raw knobs: NVIDIA needs a device
	// claim AND a RuntimeClass AND a driver-capability env var, and getting any
	// of the three wrong fails SILENTLY — the pod is healthy, the card is
	// visible, and every encode quietly runs on the CPU. Deriving all of it
	// from the vendor makes that state unrepresentable instead of documented.
	//
	// ⚠ THIS IS HALF THE CHANGE. It gets the device, the runtime and the
	// permissions into the container; it cannot make Jellyfin USE them.
	// HardwareAccelerationType lives in /config/encoding.xml — UI state on the
	// config PVC, the same class as TranscodingTempPath. Set it under
	// Dashboard -> Playback, and verify from a transcode log naming an
	// *_qsv / *_nvenc encoder, never from the dashboard toggle: a device
	// attached with the UI left at `none` is a CPU transcode that looks
	// exactly like success.
	hardwareAcceleration?: {
		// Which card. Everything below defaults from this.
		vendor: "intel" | "nvidia"

		// How many devices to claim. 1 unless a node carries several of the
		// same card.
		count: uint & >0 | *1

		// Extended resource the device plugin advertises. Defaults per vendor:
		// intel -> gpu.intel.com/i915, nvidia -> nvidia.com/gpu.
		//
		// Override only when the plugin advertises a different name. The Intel
		// one is decided by the KERNEL DRIVER, not by the vendor: Alchemist /
		// DG2 parts bind i915, while Xe2 / Battlemage and newer bind xe and are
		// advertised as gpu.intel.com/xe. Requesting the wrong one leaves the
		// pod Pending forever with "Insufficient <resource>".
		resource?: string

		// NVIDIA ONLY — ignored when vendor is "intel", which needs no special
		// runtime. Name of an existing cluster RuntimeClass whose handler is the
		// NVIDIA container runtime. This module references it; it does not
		// create it.
		//
		// Required rather than optional on Talos: the nvidia-container-toolkit
		// system extension registers an `nvidia` containerd handler and Sidero
		// deliberately does NOT make it the node-wide default, so per-pod
		// selection is the only path. Without it the pod starts cleanly,
		// /dev/nvidia* never appears, and every NVENC encode fails.
		runtimeClass: string | *"nvidia"

		// NVIDIA ONLY — value of NVIDIA_DRIVER_CAPABILITIES.
		//
		// `video` is the one that matters and the one that is missing by
		// default: the NVIDIA container runtime grants only `utility` when this
		// is unset, which is enough for nvidia-smi to report the card while
		// every NVENC encoder stays invisible to FFmpeg. That combination — GPU
		// clearly present, hardware encoding "unsupported" — is the classic dead
		// end.
		//
		// `compute` is not padding either: Jellyfin's HDR->SDR tone-mapping on
		// the NVENC path runs through CUDA/OpenCL, so a 4K HDR library loses
		// tone-mapping without it while ordinary SDR transcodes keep working.
		//
		// ⚠ NVIDIA_VISIBLE_DEVICES is deliberately never emitted, though every
		// upstream Docker example sets it to `all`. Under Kubernetes the device
		// plugin owns that variable — it writes the allocation into the
		// container's environment (or, in CDI mode, sets it to `void` and
		// injects the devices directly). Setting it in the pod spec overrides
		// the allocation and hands the container every GPU on the node.
		driverCapabilities: string | *"compute,video,utility"

		// Supplemental GIDs added to the pod so the process can open the DRI
		// render node. Applied for both vendors — harmless for NVIDIA, which
		// reaches its card through /dev/nvidia* rather than /dev/dri.
		//
		// 44 (video) and 109 (render) are the Debian-derived numbers the
		// LinuxServer.io image is built around. Belt-and-braces where the
		// injected render node arrives mode 0666, which is the common case; a
		// plugin or kernel handing it over 0660 makes these the difference
		// between working QSV and EACCES on every open.
		renderGroups: [...uint] | *[44, 109]
	}

	// Path the startup/liveness/readiness probes GET.
	//
	// Jellyfin serves ASP.NET Core health-check middleware at /health, and that
	// middleware includes a DbContext check — so /health answers only while the
	// SQLite database is readable. That is usually the health signal you want,
	// and it is also why the thresholds below are as generous as they are.
	// Point this at /System/Ping (anonymous, answers without touching the
	// database) when you would rather the probes ignore database state.
	healthPath: string | *"/health"

	// Consecutive 10-second probe failures tolerated before the container is
	// restarted (liveness) or pulled from the Service endpoints (readiness).
	//
	// The defaults give 180s and 120s, sized against a specific recurring event
	// rather than guessed. Jellyfin's built-in "Optimize database" scheduled
	// task VACUUMs jellyfin.db on a 6-hour interval, and VACUUM holds SQLite's
	// exclusive lock for the whole run, so /health blocks until it finishes. A
	// 232 MB database on iSCSI measured 40-45s per vacuum (nas1, 2026-07-30)
	// against the previous hardcoded 30s liveness budget: kubelet SIGTERMed the
	// container ~26s into every vacuum, four times a day. Nothing looked like a
	// crash — the exit was a clean 0, because Jellyfin handles SIGTERM
	// gracefully — which is exactly what made it hard to spot.
	//
	// Vacuum time scales with database size, so raise these for a larger
	// library or slower storage rather than assuming the defaults hold.
	//
	// Readiness is deliberately generous too, not just liveness. This workload
	// is single-replica by construction, so dropping the only endpoint mid-
	// vacuum cuts active clients without routing them anywhere better.
	//
	// Optional WITHOUT a default on purpose. #ProbeSchema.failureThreshold
	// already carries `uint | *3`, and unifying a second marked default into it
	// produces a disjunction with TWO defaults, which CUE cannot resolve — the
	// whole instance then renders non-concrete. The defaults are applied in
	// components.cue behind an explicit guard instead.
	livenessFailureThreshold?:  uint & >0
	readinessFailureThreshold?: uint & >0

	// How many 10-second startup probes may fail before the container is
	// considered failed to start. Default is 5 minutes of grace.
	//
	// Until this probe existed the only guard on a slow boot was liveness'
	// initialDelaySeconds: 30, so a restored library running schema migrations
	// before opening its listener could be killed and restarted forever. Same
	// guard/default arrangement as the thresholds above.
	startupFailureThreshold?: uint & >0

	// Seconds Kubernetes waits after SIGTERM before sending SIGKILL.
	//
	// 120 rather than Kubernetes' default 30, for the same VACUUM reason: a
	// SIGTERM landing mid-vacuum cannot take effect until the vacuum releases
	// the database, so a 30s grace period puts SIGKILL squarely inside an
	// in-flight SQLite write. Unlike the thresholds above this one can carry
	// its default here, because #GracefulShutdownSchema declares a bare `uint`
	// with no competing default to unify against.
	terminationGracePeriodSeconds: uint & >0 | *120

	// Optional Serilog structured logging configuration.
	// When set, a ConfigMap is created and mounted at /config/logging.json.
	logging?: {
		defaultLevel: *"Information" | "Debug" | "Warning" | "Error"
		overrides?: [string]: "Debug" | "Information" | "Warning" | "Error"
	}

	// Optional scheduling constraints — which nodes this pod may run on.
	//
	// NOT needed for GPU placement, contrary to what this comment said before
	// v2.5.0. A GPU claim is an extended-resource REQUEST, which is a hard
	// scheduling constraint in its own right: only a node advertising the
	// resource can fit the pod, so the scheduler already steers it. What this
	// field is genuinely for is `tolerations`, when GPU nodes carry a dedicated
	// taint to keep everything else off them, and `nodeSelector` when a node
	// must be chosen for a reason the resource does not encode.
	//
	// The schema is the catalog's, referenced rather than copied, so the
	// module cannot drift from the transformer that consumes it.
	podScheduling?: tr.#PodSchedulingSchema

	// Optional pod-template labels and annotations.
	//
	// Distinct from component metadata on purpose: component labels flow into
	// `spec.selector.matchLabels`, which Kubernetes makes IMMUTABLE, so a
	// semantic pod label routed that way could never be changed or removed
	// without deleting the StatefulSet. Anything belonging on the pod and not
	// on the selector goes here — mesh membership
	// (`istio.io/dataplane-mode`), backup hooks, scrape hints.
	//
	// This is also the supported way to attach backup tooling now that the
	// K8up feature was dropped: k8up's `k8up.io/backupcommand` and
	// `k8up.io/file-extension` are pod annotations, so a pre-backup SQLite
	// checkpoint is expressible here without the module modelling backups.
	podMetadata?: tr.#PodMetadataSchema
}

debugValues: {
	image: {
		repository: "linuxserver/jellyfin"
		tag:        "latest"
		digest:     ""
	}
	port:        8096
	puid:        3005
	pgid:        3005
	timezone:    "Europe/Stockholm"
	serviceType: "ClusterIP"
	resources: {
		requests: {
			cpu:    "500m"
			memory: "1Gi"
		}
		limits: {
			cpu:    "4000m"
			memory: "4Gi"
		}
	}
	// The NVIDIA arm on purpose: it is the branch that exercises the most
	// wiring — the derived nvidia.com/gpu claim, the RuntimeClass trait, the
	// NVIDIA_DRIVER_CAPABILITIES env var and the supplemental GIDs — so a
	// concrete render of debugValues covers all of it in one pass. The intel
	// arm renders a strict subset.
	hardwareAcceleration: {
		vendor: "nvidia"
	}
	httpRoute: {
		hostnames: ["jellyfin.example.com"]
		gatewayRef: {
			name:      "gateway-gateway"
			namespace: "istio-ingress"
		}
	}
	logging: {
		defaultLevel: "Information"
		overrides: {
			"Microsoft": "Warning"
			"System":    "Warning"
		}
	}
	storage: {
		config: {
			mountPath:    "/config"
			type:         "pvc"
			size:         "10Gi"
			storageClass: "local-path"
		}
		media: {
			movies: {
				mountPath: "/media/movies"
				type:      "pvc"
				size:      "1Gi"
			}
			tvshows: {
				mountPath: "/media/tvshows"
				type:      "pvc"
				size:      "1Gi"
			}
			nas: {
				mountPath: "/media/nas"
				type:      "nfs"
				server:    "192.168.1.1"
				path:      "/mnt/data/media"
				// Exercises the readOnly branch: a shared NFS library is
				// exactly the case the field exists for.
				readOnly: true
			}
		}
	}
}
