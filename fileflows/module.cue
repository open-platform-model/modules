// Package fileflows defines the FileFlows media-processing module.
//
// FileFlows is a .NET file-processing/transcoding automation server: libraries
// are scanned, matched files are pushed through user-authored "flows", and the
// heavy step is almost always an FFmpeg transcode. A single-container stateful
// application:
//   - module.cue:     metadata and config schema
//   - components.cue: component definitions (catalog_opm blueprints/traits)
//
// Server role only. FileFlows also supports external *processing nodes* — extra
// containers that register with the server and run flows on its behalf — and
// this module deliberately does not model them. They exist to spread work
// across MACHINES; on a single-node cluster a second pod on the same host adds
// scheduling and path-mapping surface while contending for the same CPU, disk
// and GPUs. Adding them later is a `nodes: [Name=string]: {...}` map plus
// `FFNODE=1` / `ServerUrl` / `NodeName` on the extra pods — the server does not
// change shape, so nothing here has to be undone to get there.
package fileflows

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
	name:        "fileflows"
	version:     "1.0.0"
	description: "FileFlows - media processing and transcoding automation server"
}

// #storageVolume is the shared schema for all storage entries.
// Same shape for the data volume, logs, temp, and every media mount.
#storageVolume: {
	mountPath:     string
	type:          "pvc" | "emptyDir" | "nfs"
	size?:         string // required when type == "pvc"
	storageClass?: string // optional, only used when type == "pvc"
	server?:       string // required when type == "nfs"
	path?:         string // required when type == "nfs"

	// Mount read-only. Applied to BOTH the volume source and the container's
	// volumeMount — setting only the mount leaves the volume itself writable to
	// anything else that attaches it.
	//
	// Leave false for anything FileFlows processes. Unlike a media *server*,
	// which only reads, FileFlows exists to rewrite files in place: it writes
	// the transcoded output back over the original. A read-only library is a
	// valid choice only for a flow that copies elsewhere, and it will fail every
	// in-place flow at the final move.
	readOnly: bool | *false
}

// Schema only - constraints for users, no defaults beyond sensible image/port.
#config: {
	// Container image.
	//
	// ⚠ THE `modded` PREFIX IS LOAD-BEARING ON KUBERNETES, not a preference.
	// The plain `stable`/`latest` images ship WITHOUT FFmpeg and acquire it at
	// runtime through DockerMods, which talk to a Docker daemon over the
	// /var/run/docker.sock bind mount in every upstream example. There is no
	// Docker daemon under containerd, so that path cannot work here at all —
	// and the failure is late and confusing: the server starts, the web UI
	// loads, libraries scan, and only the first flow that reaches an FFmpeg
	// node fails. Upstream frames `modded-*` as the workaround for hosts with
	// no internet; on Kubernetes it is the only correct tag.
	//
	// Pinned to a dated tag rather than `modded-stable` so an upgrade is a
	// deliberate edit. `modded` and `modded-stable` are moving targets.
	image: res.#Image & {
		repository: string | *"revenz/fileflows"
		tag:        string | *"modded-26.07"
		digest:     string | *""
	}

	// Exposed Service port. The container always listens on 5000 regardless.
	port: int & >0 & <=65535 | *5000

	// Process user/group the app drops to.
	puid: int | *1000
	pgid: int | *1000

	// Container timezone.
	timezone: string | *"Europe/Stockholm"

	// Storage. `data` is required and is the only volume that must survive a
	// restart; the rest are optional but `temp` is strongly recommended.
	storage: {
		// Configuration, flow definitions and the SQLite database.
		// /app/Data is the image's built-in default — the docs' `/data` is wrong.
		data: #storageVolume & {
			mountPath: *"/app/Data" | string
			type:      *"pvc" | "emptyDir" | "nfs"
			size:      string | *"10Gi"
		}

		// Application logs. Optional: unmounted they stay on the container
		// filesystem and vanish with the pod, which is usually fine because the
		// UI reads them through the server rather than off disk.
		logs?: #storageVolume & {
			mountPath: *"/app/Logs" | string
		}

		// Scratch space for in-flight transcodes.
		//
		// ⚠ SIZE THIS FOR A WHOLE FILE, NOT A BUFFER. FileFlows writes the full
		// working copy here before moving the result into place, so a 60 GB
		// remux needs 60 GB of temp. Left as the default emptyDir that lands on
		// the node's ephemeral partition, a large job can fill it and trigger
		// kubelet eviction of unrelated pods on the same node — the damage is
		// not contained to FileFlows. Point it at a PVC or an NFS dataset on
		// bulk storage for anything beyond trivial files.
		temp?: #storageVolume & {
			mountPath: *"/temp" | string
		}

		// Library mounts keyed by name. Paths must match what the flows and
		// library definitions use, because FileFlows stores absolute paths.
		media?: [Name=string]: #storageVolume
	}

	// Kubernetes Service type for the FileFlows web UI.
	serviceType: "ClusterIP" | "NodePort" | "LoadBalancer" | *"ClusterIP"

	// Optional Gateway API HTTPRoute for ingress routing.
	httpRoute?: {
		hostnames: [...string]
		gatewayRef?: {
			name:      string
			namespace: string
		}
	}

	// Container resource requests and limits, including GPU claims.
	//
	// `resources.gpus` (plural) is what makes a two-GPU transcoder expressible:
	//
	//   gpus: {
	//     nvidia: {resource: "nvidia.com/gpu", count: 1}
	//     intel:  {resource: "gpu.intel.com/i915", count: 1}
	//   }
	//
	// Both devices land in the same container and FileFlows picks between them
	// per flow — NVENC on one, QSV/VAAPI on the other. This needs
	// catalogs/opm >= v1.0.0-alpha.8; the older singular `resources.gpu` cannot
	// express it and `limits` rejects extended-resource keys written by hand.
	resources?: res.#ResourceRequirementsSchema

	// Optional: copy a known-good FFmpeg toolchain in from another image at
	// startup, rather than trusting whatever the FileFlows image ships.
	//
	// WHY THIS EXISTS. FileFlows resolves its encoder through an editable
	// `FFmpeg` variable — the same indirection that lets a processing node point
	// at a different install path, and which upstream documents as the way to
	// "work around limitations in specific builds". That makes the FFmpeg binary
	// a swappable input rather than a property of the image, so the module can
	// supply one whose hardware support is known instead of inferred.
	//
	// It matters because neither FileFlows image is a good bet for GPU work: the
	// plain tags ship no FFmpeg at all (DockerMods, which need a Docker socket
	// that does not exist under containerd), and the `modded-*` tags ship one
	// whose encoder support upstream never states. Injecting removes the
	// question. `jellyfin-ffmpeg` is the natural donor — it is a self-contained
	// tree (ffmpeg, ffprobe, vainfo and its own lib/, including the bundled
	// libva drivers) built precisely for mixed NVENC/QSV/VAAPI transcoding.
	//
	// ⚠ HALF THE CHANGE IS IN THE UI. This makes the binary available; it cannot
	// make FileFlows use it. Set Settings -> Variables -> `FFmpeg` to
	// "<path>/ffmpeg". Until then the injected tree is mounted and ignored.
	ffmpegInjection?: {
		// Donor image. Any image carrying a self-contained FFmpeg tree works;
		// the default is the LinuxServer Jellyfin image, pinned rather than
		// floating because this is a toolchain, not an app.
		image: res.#Image & {
			repository: string | *"linuxserver/jellyfin"
			tag:        string | *"10.11.11ubu2604-ls43"
			digest:     string | *""
		}

		// Where the tree is copied from in the donor, and mounted to here.
		//
		// ONE path for both on purpose. jellyfin-ffmpeg finds its bundled VA-API
		// drivers (lib/dri/iHD_drv_video.so) relative to its own install
		// location, so relocating it silently costs QSV and VAAPI unless
		// LIBVA_DRIVERS_PATH is also set. Keeping the donor's path removes that
		// coupling instead of documenting it.
		path: string | *"/usr/lib/jellyfin-ffmpeg"
	}

	// Name of a cluster RuntimeClass whose handler is the NVIDIA container
	// runtime, normally "nvidia".
	//
	// REQUIRED FOR NVIDIA, IGNORED BY INTEL. Intel GPUs arrive as device nodes
	// from the device plugin and work under the default runtime; NVIDIA devices
	// are injected by the runtime itself, so without this the pod starts
	// cleanly, `nvidia-smi` is absent, and every NVENC flow fails while QSV
	// keeps working. Leave unset on an Intel-only deployment.
	runtimeClass?: string

	// Value of NVIDIA_DRIVER_CAPABILITIES, emitted only when `runtimeClass` is
	// set.
	//
	// `video` is the one that matters and the one that is missing by default:
	// the NVIDIA container runtime grants only `utility` when this is unset,
	// which is enough for `nvidia-smi` to run and report the card while every
	// NVENC encoder stays invisible to FFmpeg. That combination — GPU clearly
	// present, hardware encoding "unsupported" — is the classic dead end.
	nvidiaDriverCapabilities: string | *"compute,video,utility"

	// Supplemental GIDs added to the pod so the process can open the DRI render
	// node. Applied only when a GPU is requested.
	//
	// 44 (video) and 109 (render) are the Debian-derived defaults, which the
	// FileFlows image is. Without them an Intel GPU is present in the container
	// but every open of /dev/dri/renderD* is EACCES.
	renderGroups: [...int] | *[44, 109]

	// Consecutive 10-second probe failures tolerated before the container is
	// restarted (liveness) or pulled from Service endpoints (readiness).
	//
	// Optional WITHOUT defaults on purpose: #ProbeSchema.failureThreshold
	// already carries `uint | *3`, and unifying a second marked default into it
	// yields a disjunction with TWO defaults that CUE cannot resolve, rendering
	// the whole instance non-concrete. Defaults are applied in components.cue
	// behind an explicit guard instead.
	livenessFailureThreshold?:  uint & >0
	readinessFailureThreshold?: uint & >0

	// How many 10-second startup probes may fail before the container is
	// considered failed to start. Default is 5 minutes, which covers first-run
	// database creation and schema migration after an image bump.
	startupFailureThreshold?: uint & >0

	// Seconds Kubernetes waits after SIGTERM before SIGKILL.
	//
	// 300 rather than Kubernetes' default 30 because the unit of work is a
	// transcode, not a request. A SIGKILL mid-flow abandons the partial output
	// in `temp` and leaves the library file marked as processing, so the job is
	// re-run from the start on the next boot after a manual reset.
	terminationGracePeriodSeconds: uint & >0 | *300

	// Optional scheduling constraints.
	//
	// The motivating case is GPUs: `resources.gpus` asks for devices but nothing
	// steers the pod toward a node that HAS them. Irrelevant on a single-node
	// cluster, essential on a mixed one, where the pod otherwise lands somewhere
	// without the device and fails, or schedules correctly only by luck.
	podScheduling?: tr.#PodSchedulingSchema

	// Optional pod-template labels and annotations.
	//
	// Distinct from component metadata on purpose: component labels flow into
	// `spec.selector.matchLabels`, which Kubernetes makes IMMUTABLE, so a
	// semantic pod label routed that way could never be changed or removed
	// without deleting the StatefulSet.
	podMetadata?: tr.#PodMetadataSchema
}

debugValues: {
	image: {
		repository: "revenz/fileflows"
		tag:        "modded-26.07"
		digest:     ""
	}
	port:         5000
	puid:         3005
	pgid:         3005
	timezone:     "Europe/Stockholm"
	serviceType:  "ClusterIP"
	runtimeClass: "nvidia"
	resources: {
		requests: {
			cpu:    "1000m"
			memory: "2Gi"
		}
		limits: {
			cpu:    "8000m"
			memory: "8Gi"
		}
		// The case this module exists to cover: both vendors in one container.
		gpus: {
			nvidia: {
				resource: "nvidia.com/gpu"
				count:    1
			}
			intel: {
				resource: "gpu.intel.com/i915"
				count:    1
			}
		}
	}
	httpRoute: {
		hostnames: ["fileflows.example.com"]
		gatewayRef: {
			name:      "gateway-gateway"
			namespace: "istio-ingress"
		}
	}
	storage: {
		data: {
			mountPath:    "/app/Data"
			type:         "pvc"
			size:         "10Gi"
			storageClass: "local-path"
		}
		temp: {
			mountPath: "/temp"
			type:      "nfs"
			server:    "192.168.1.1"
			path:      "/mnt/data/media/fileflows-temp"
		}
		media: {
			movies: {
				mountPath: "/media/movies"
				type:      "nfs"
				server:    "192.168.1.1"
				path:      "/mnt/data/media/movies"
			}
		}
	}
}
