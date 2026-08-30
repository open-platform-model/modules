// Package fileflows defines the FileFlows media-processing module.
//
// FileFlows is a .NET file-processing/transcoding automation server: libraries
// are scanned, matched files are pushed through user-authored "flows", and the
// heavy step is almost always an FFmpeg transcode.
//   - module.cue:     metadata and config schema
//   - components.cue: component definitions (catalog_opm blueprints/traits)
//
// Renders the stateful server, plus optionally one stateless external
// *processing node* per `#config.nodes` entry — extra pods that register with
// the server and run flows on its behalf.
//
// Nodes were originally built to spread work across MACHINES, which is why this
// module declined to model them while the target cluster was a single host. The
// reason they earn their keep on ONE host is different and specific: FileFlows'
// runner budget is a property of a processing node, and a pod is allocated its
// GPUs by the device plugin. One card per node pod therefore buys two things a
// single server pod cannot express — per-card concurrency, and per-card encoder
// selection that needs no in-flow logic at all, because a pod holding one card
// has only one encoder for `Automatic` to resolve to.
package fileflows

import (
	id "opmodel.dev/modules/fileflows/identity"
	m "opmodel.dev/core@v2"
	res "opmodel.dev/catalogs/opm/resources/v1beta1"
	tr "opmodel.dev/catalogs/opm/traits/v1beta1"
)

// Module definition
m.#Module

// Brings the module's runtime context into LEXICAL scope.
//
// `m.#Module` above is EMBEDDED, and embedded fields are not visible to sibling
// top-level fields — so a bare `#ctx.instance.name` in components.cue fails to
// resolve with `reference "#ctx" not found`. No other module in this repo
// references #ctx, so there is no prior art to copy; this declaration is the
// whole fix. The VALUE still arrives from #ModuleInstance
// (core/src/module_instance.cue:68-74) — this only declares the identifier.
//
// Safe under `cue vet -c`: definitions are not concreteness-checked.
#ctx: _

// Module metadata — modulePath is the COMPLETE CUE module path including the
// major, byte-identical to cue.mod's module field and identity/identity.cue;
// fqn/registryPath/uuid derive from it (enhancement 0010).
metadata: {
	name:        "fileflows"
	modulePath:  id.ModulePath
	version:     id.Version
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

// Key charset for `#config.nodes`.
//
// Bounded to 58 runes rather than the usual 63: the generated component id is
// "node-<key>", and #components is pattern-constrained to core's #NameType
// (core/src/types.cue:10), which caps at 63. Spelled as one regex rather than
// strings.MaxRunes so #config stays importless and expressible as a single
// OpenAPI `pattern`.
#nodeKey: string & =~"^[a-z0-9]([a-z0-9-]{0,56}[a-z0-9])?$"

// The GPU attachment shape, shared verbatim by the server and by every node so
// the two cannot drift.
//
// Derived rather than assembled by hand because every wrong assembly is SILENT:
// an `nvidia.com/gpu` claim without a RuntimeClass is a healthy-looking pod with
// no NVENC at all, and nothing in the module can catch it. Deriving makes that
// unrepresentable rather than documented.
//
// ⚠ A GPU IS CONSUMED CLUSTER-WIDE. Each card claimed is unavailable to every
// other workload for as long as the pod exists, and Kubernetes does not preempt
// extended resources — a second claimant just sits Pending forever. Attaching a
// card another pod already holds means removing it there first, in the SAME
// change. That includes moving a card from this module's own server to one of
// its nodes.
//
// ⚠ THIS IS HALF THE CHANGE. It gets the device, the runtime and the
// permissions into the container; it cannot make FileFlows *use* them. The
// encoder is chosen per flow in the FFmpeg Builder, and the binary comes from
// the `FFmpeg` variable — see `ffmpegInjection`. Device attached and flow left
// on a software encoder is a working pod that transcodes on the CPU and looks
// exactly like success.
#hardwareAccelerationSpec: {
	// The cards to attach, keyed by vendor. One entry per card:
	//
	//   devices: {nvidia: {}}              // P2200 only
	//   devices: {nvidia: {}, intel: {}}   // both — adding a card is 1 line
	//
	// Keyed rather than a list so a vendor cannot be named twice, and so
	// per-card overrides have somewhere to live without a parallel map.
	//
	// MULTIPLE CARDS IN ONE POD ARE VALID, and this is where the module diverges
	// from `modules/jellyfin` v2.5.0, which takes a scalar `vendor`. That is not
	// inconsistency: Jellyfin's HardwareAccelerationType is a single global
	// setting, so it genuinely uses one card at a time. FileFlows chooses its
	// encoder **per flow**, so every attached card can be busy at once.
	//
	// On a NODE, prefer exactly one entry. A node pod holding one card resolves
	// `Encoder: Automatic` unambiguously, which is the whole reason to split
	// into nodes; a node holding two is back to the server's problem, where
	// Automatic walks a fixed vendor priority list and the second card idles.
	//
	// Needs `resources.gpus` from catalogs/opm >= v1.0.0-alpha.8. The singular
	// `resources.gpu` cannot express two claims, and
	// #ResourceRequirementsSchema is closed, so extended-resource keys cannot be
	// written into `limits` by hand either.
	devices: {
		[Vendor="intel" | "nvidia"]: {
			// How many of THIS card to claim. Raise only on a node that
			// carries several of the same model.
			count: uint & >0 | *1

			// Extended resource the device plugin advertises. Defaults per
			// vendor: intel -> gpu.intel.com/i915, nvidia -> nvidia.com/gpu.
			//
			// Override only when the plugin advertises a different name.
			// The Intel one is decided by the KERNEL DRIVER, not the
			// vendor: Alchemist/DG2 (the Arc A310, device id 56a6) binds
			// i915, while Xe2/Battlemage and newer bind xe and advertise
			// gpu.intel.com/xe. Requesting the wrong one leaves the pod
			// Pending forever with "Insufficient <resource>".
			resource?: string
		}
	}

	// NVIDIA ONLY — ignored unless `devices` contains an nvidia entry.
	// Name of a cluster RuntimeClass whose handler is the NVIDIA
	// container runtime.
	//
	// Required, not optional, on Talos: the nvidia-container-toolkit
	// extension registers an `nvidia` containerd handler and Sidero
	// deliberately does not make it the node default. Without it the pod
	// starts cleanly, /dev/nvidia* never appears, and every NVENC encode
	// fails while the pod looks healthy.
	runtimeClass: string | *"nvidia"

	// NVIDIA ONLY, and emitted only when an nvidia device is attached.
	// Value of NVIDIA_DRIVER_CAPABILITIES.
	//
	// `video` is the one that matters and the one that is missing by
	// default: the NVIDIA runtime grants only `utility` when unset, which
	// is enough for nvidia-smi to report the card while every NVENC encoder
	// stays invisible to FFmpeg. `compute` is not padding either — HDR
	// tone-mapping on NVENC runs through CUDA/OpenCL.
	//
	// ⚠ NVIDIA_VISIBLE_DEVICES is never set by this module, though every
	// upstream Docker example sets it to `all`. Under Kubernetes the device
	// plugin owns that variable; setting it here overrides the allocation
	// and hands the container every GPU on the node.
	driverCapabilities: string | *"compute,video,utility"

	// Supplemental GIDs so the process can open /dev/dri/renderD*. Applied
	// for both vendors — harmless for NVIDIA, which reaches its card
	// through /dev/nvidia* instead.
	//
	// 44 (video) and 109 (render) are the Debian-derived numbers.
	renderGroups: [...uint] | *[44, 109]
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

	// Container resource requests and limits.
	//
	// The legacy `resources.gpu` path still works, but prefer
	// `hardwareAcceleration` below — it derives the resource name, the runtime
	// and the permissions from one field instead of asking the instance to
	// assemble four that must agree. Setting both with different values fails
	// the build on a CUE conflict rather than silently picking one.
	resources?: res.#ResourceRequirementsSchema

	// Optional hardware transcoding for the SERVER pod. Full documentation of
	// the shape, and of the traps it exists to make unrepresentable, is on
	// #hardwareAccelerationSpec above.
	//
	// ⚠ LEAVE THIS UNSET WHEN USING `nodes`. A card given to a node must be
	// taken from whatever holds it in the same change, and the most likely
	// current holder is this field. A server that keeps a card competes with its
	// own nodes for it, and the node pod that loses the race sits Pending
	// forever with no self-correction.
	hardwareAcceleration?: #hardwareAccelerationSpec

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

	// Settings -> Security -> Access Token, exactly as already typed into the
	// server's UI. Each node sends it as an `x-token` header
	// (FileFlows.RemoteServices.dll) to register.
	//
	// ⚠ THE MODULE CANNOT SET THE SERVER SIDE. FileFlows.Server.dll reads no
	// environment variable for this (only FF_EULA_ACCEPTED), so the value lives
	// in the server's database and this field only hands a COPY to the nodes.
	// The two must agree, and nothing here can check that: a wrong value is a
	// silent "Failed to register node" in the node's log, not a build error.
	//
	// Optional at module level so an instance with no nodes needs no token —
	// but REQUIRED once `nodes` is non-empty, which components.cue enforces.
	// Only meaningful when server security is actually enabled; with security
	// off the server accepts unauthenticated registration and the label in the
	// node UI reads "Optional Access Token".
	// 0013: becomes c.#Secret when core ships it; plain string until then.
	accessToken?: string

	// Override the URL nodes dial. Almost never needed — the default is derived
	// from the instance's own name and namespace, which is exactly where the
	// server Service lands.
	//
	// ⚠ DO NOT REACH FOR #ctx.components.fileflows.dns.fqdn TO BUILD THIS, and
	// do not "fix" the derivation in components.cue to use it. That path derives
	// from metadata.resourceName, which defaults to metadata.name
	// (core/src/component.cue:13) = "fileflows" — but the RENDERED Service is
	// "\(instance)-\(component.metadata.name)" (service_transformer.cue:96),
	// i.e. `fileflows-fileflows` for an instance named `fileflows`. #ctx would
	// yield "fileflows.fileflows.svc.cluster.local", a name that does not
	// resolve, and the failure surfaces only as nodes that never register.
	serverUrl?: string

	// External processing nodes. One headless worker pod per entry.
	//
	// WHY THIS EXISTS. FileFlows' runner budget is a property of a processing
	// node, and a pod is allocated its GPUs by the device plugin — so one card
	// per node pod is the only way to express "N concurrent jobs on THIS card".
	// It also removes encoder selection from the flows entirely: `Automatic`
	// walks a fixed vendor priority list and stops at the first encoder that
	// probes clean, so a pod holding exactly one card cannot choose wrong.
	//
	// Everything not listed below is INHERITED from the server config above and
	// is deliberately not overridable — see the table in README.md. The two that
	// most often surprise: `image` (version lockstep is enforced by the node's
	// own auto-updater, which downloads into a container layer discarded on
	// restart, so a divergent tag is a permanent update loop) and
	// `storage.media` (identical mount paths on every pod is exactly what makes
	// FileFlows' NodeMappings unnecessary).
	//
	// A regular field rather than optional, so it is always at least `{}` and
	// components.cue can range over it without a guard.
	nodes: [Name=#nodeKey]: {
		// false renders the workload at 0 replicas: the pod goes away and
		// RELEASES ITS GPU, while the config stays in git and in review.
		//
		// Distinct from FileFlows' own NodeEnabled, which keeps the pod running
		// (and the card claimed) while telling the server not to send it work.
		enabled: bool | *true

		// The node's registered identity, defaulting to the map key.
		//
		// ⚠ MUST BE STABLE. FileFlows registers nodes by address and keys its
		// own records off this, so a name that churns across rollouts leaves a
		// new orphan node record in the server database every time.
		nodeName?: string

		// NodeRunnerCount — the per-card concurrency knob, and the reason to
		// split into nodes at all.
		//
		// ⚠ A UNIT BUDGET, NOT A FILE COUNT. In 26.07 active files consume this
		// budget according to their assigned cost (audio/SD/720p/1080p/4K), so
		// `2` is not necessarily two files. Start low and measure.
		//
		// ⚠ SETTING IT HANDS OWNERSHIP TO THE MODULE. FileFlows hides
		// env-provided settings in the Web Console rather than let the UI
		// overwrite them, so this field becomes the only place it can change.
		// Leave unset to keep the UI in charge.
		runners?: uint & >0

		// Scratch space for in-flight transcodes. REQUIRED, and deliberately
		// not inherited from the server.
		//
		// ⚠ NEVER POINT TWO NODES AT ONE DIRECTORY. Each node sweeps its own
		// temp on a schedule and skips only the Runner-<uid> directories IT
		// knows are executing — it has no visibility into another node's
		// runners. A shared temp therefore lets one node delete another's
		// in-flight working copy mid-encode. Give every node its own dataset.
		//
		// ⚠ SIZE FOR A WHOLE FILE PER RUNNER, not a buffer: FileFlows writes
		// the full working copy here before moving the result into place, so a
		// 60 GB remux needs 60 GB of temp and `runners` multiplies that.
		//
		// mountPath defaults to /temp because the image entrypoint chowns
		// exactly /temp; the node binary's own built-in default is /mnt/temp,
		// which nothing mounts and nothing chowns.
		temp!: #storageVolume & {
			mountPath: *"/temp" | string
		}

		// The card this node owns. One entry — see #hardwareAccelerationSpec.
		//
		// ⚠ ONE PHYSICAL CARD PER POD IS NOT GUARANTEED BY THIS FIELD. It asks
		// for one device from a plugin; whether two such asks land on two
		// different cards is the plugin's business. With the Intel plugin's
		// sharedDevNum > 1, N advertised slots may map onto one physical card,
		// and only `allocationPolicy: balanced` makes spreading likely — not
		// certain. sharedDevNum: 1 is the only setting that makes it certain.
		hardwareAcceleration?: #hardwareAccelerationSpec

		// Per-node CPU and memory. Worth setting differently per card: filters,
		// muxing and audio encoding stay on the CPU even with hardware video
		// encode, so a node whose card is fast can starve on CPU while another
		// idles.
		resources?: res.#ResourceRequirementsSchema

		// Per-node scheduling. On a multi-node cluster this is what steers each
		// node pod toward the host that physically has its card — `resources`
		// asks for a device but nothing steers the pod to a host that has one.
		podScheduling?: tr.#PodSchedulingSchema

		podMetadata?: tr.#PodMetadataSchema

		// Falls back to the server's value when unset. Same reasoning as the
		// server's: the unit of work is a transcode, not a request.
		//
		// Inheritance is "set it or inherit it", never a partial merge — see
		// the note in components.cue on why `*#config.x | T` is not used.
		terminationGracePeriodSeconds?: uint & >0
	}
}

debugValues: {
	image: {
		repository: "revenz/fileflows"
		tag:        "modded-26.07"
		digest:     ""
	}
	port:        5000
	puid:        3005
	pgid:        3005
	timezone:    "Europe/Stockholm"
	serviceType: "ClusterIP"
	resources: {
		requests: {
			cpu:    "1000m"
			memory: "2Gi"
		}
		limits: {
			cpu:    "8000m"
			memory: "8Gi"
		}
	}
	// Both cards, so a render test exercises the multi-claim path, the
	// RuntimeClass trait, the driver-capabilities env var and the render GIDs
	// in one pass.
	//
	// A real instance using `nodes` would leave this UNSET and hand both cards
	// to the nodes; it is kept here only so one render covers the server's GPU
	// branches as well as the nodes'.
	hardwareAcceleration: devices: {
		nvidia: {}
		intel: {}
	}
	ffmpegInjection: {}

	// Required once `nodes` is non-empty — components.cue._validate enforces it.
	accessToken: "debug-access-token"

	// Three nodes, chosen so one render exercises every branch:
	//   p2200    NVIDIA + emptyDir temp -> RuntimeClass, driver caps, chown init
	//   arc-1    Intel + NFS temp       -> no RuntimeClass, NO chown init
	//   cpu-only no GPU + PVC temp      -> no gpus/runtimeClass/supplementalGroups,
	//                                      no NodeRunnerCount, grace override
	nodes: {
		p2200: {
			runners: 2
			hardwareAcceleration: devices: nvidia: {}
			temp: {
				mountPath: "/temp"
				type:      "emptyDir"
			}
		}
		"arc-1": {
			runners: 3
			hardwareAcceleration: devices: intel: {}
			temp: {
				mountPath: "/temp"
				type:      "nfs"
				server:    "192.168.1.1"
				path:      "/mnt/data/media/fileflows-temp-arc1"
			}
		}
		"cpu-only": {
			temp: {
				mountPath:    "/temp"
				type:         "pvc"
				size:         "500Gi"
				storageClass: "local-path"
			}
			terminationGracePeriodSeconds: 600
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
