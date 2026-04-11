// Package wolf defines a Wolf GPU game streaming server module.
//
// Wolf (https://games-on-whales.github.io/wolf/stable/) is a Moonlight-compatible
// game streaming server that lets multiple users stream GPU-accelerated virtual
// desktops and games simultaneously from a single server.
//
// ## Multi-user
//
// Wolf natively supports concurrent streaming sessions. Each Moonlight client
// that connects gets its own GPU-accelerated virtual desktop (via Wayland) and
// audio session (via PulseAudio), running in isolated Docker containers that Wolf
// manages on-demand.
//
// ## Architecture
//
// A single StatefulSet is deployed with these containers:
//
//   initContainer: config-seed
//     Seeds /etc/wolf/cfg/config.toml on first start only.
//     Wolf modifies this file as clients pair and apps are registered.
//
//   sidecar: dind  (docker:dind)
//     Docker-in-Docker daemon. Wolf uses the Docker API to spawn per-session app
//     containers (Steam, Firefox, etc.). Required on Kubernetes/Talos because the
//     host has no accessible Docker socket. Shares the config PVC and XDG socket
//     emptyDir with Wolf so app containers can access the right paths.
//
//   sidecar: wolfmanager  (optional, ghcr.io/salty2011/wolfmanager)
//     Web-based management UI for Wolf. Provides authenticated user management,
//     Moonlight device pairing, session monitoring, and profile management.
//     Communicates with Wolf via the Unix domain socket at /run/wolf/wolf.sock.
//     Stores its SQLite database on the wolf-config volume.
//     Source: https://github.com/salty2011/wolfmanager
//
//   main: wolf  (ghcr.io/games-on-whales/wolf:stable)
//     The Wolf streaming server. Talks to DinD to manage app containers, streams
//     GPU-encoded video/audio to Moonlight clients over RTP/UDP.
//
// ## Pairing
//
// When WolfManager is enabled, use its web UI (default port 9971) to pair
// Moonlight clients. It provides a PIN-entry form, user accounts, and device
// tracking. Without WolfManager, Wolf logs a PIN entry URL to stdout.
//
// ## Ports
//
//   47984/tcp  HTTPS  — pairing
//   47989/tcp  HTTP   — pairing
//   48010/tcp  RTSP   — stream setup
//   47999/udp  Control — input & control channel
//   48100/udp  Video  — encoded video stream (H.264 / HEVC / AV1)
//   48200/udp  Audio  — Opus audio stream
//
// Wolf recommends host networking (hostNetwork: true at the K8s pod level) to
// avoid NAT overhead on the latency-sensitive UDP streams. Configure this at the
// ModuleRelease or K8s provider level.
//
// ## GPU
//
// Intel/AMD: DRI devices (/dev/dri/*) are passed through via hostPath.
// NVIDIA: DRI devices + /dev/nvidia* devices + a pre-built driver volume.
//   See the README for instructions to prepare the NVIDIA driver hostPath.
//
// ## Security
//
// Wolf and DinD require elevated privileges:
//   - DinD must run as privileged (K8s pod securityContext.privileged: true).
//   - Wolf needs capabilities: NET_RAW, MKNOD, NET_ADMIN, SYS_ADMIN, SYS_NICE,
//     and device cgroup rule "c 13:* rmw" for virtual input device creation.
// These are applied at the K8s provider / transformer level and must be
// permitted by the cluster PodSecurityAdmission / PodSecurityPolicy.
package wolf

import (
	m "opmodel.dev/core/v1alpha1/module@v1"
	schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)

// Module definition
m.#Module

// Module metadata
metadata: {
	modulePath:       "example.com/modules"
	name:             "wolf"
	version:          "0.1.0"
	description:      "Wolf GPU game streaming server — Moonlight-compatible, multi-user, GPU-accelerated"
	defaultNamespace: "default"
}

// _#portSchema: valid Kubernetes port number
_#portSchema: uint & >0 & <=65535

// Module config schema
#config: {
	// === Wolf container image ===
	image: schemas.#Image & {
		repository: string | *"ghcr.io/games-on-whales/wolf"
		tag:        string | *"stable"
		digest:     string | *""
	}

	// === Init container image ===
	// Alpine + CUE image used by the config-init init container to merge the
	// ConfigMap-provided config.toml with existing paired_clients data on disk.
	// Build with: docker build -f modules/wolf/Dockerfile.init -t ttl.sh/<name>/wolf-init:1h .
	// Publish with: docker push ttl.sh/<name>/wolf-init:1h
	// Then set this to the pushed image reference in the release.
	initImage: schemas.#Image & {
		repository: string | *"ttl.sh/wolf-init"
		tag:        string | *"latest"
		digest:     string | *""
	}

	// === Wolf daemon settings ===
	wolf: {
		// Display name shown in Moonlight's host list
		hostname: string | *"wolf"

		// Enable HEVC video encoding support
		supportHevc: bool | *true

		// Log verbosity. Set to DEBUG when troubleshooting connection issues.
		logLevel: *"INFO" | "ERROR" | "WARNING" | "DEBUG" | "TRACE"

		// Stop and remove per-session app containers when the stream ends.
		// Set to false to leave containers running for inspection after disconnect.
		stopContainerOnExit: bool | *true

		// GStreamer debug level (integer 0–9 or plugin:level string).
		// Only set when diagnosing encoding pipeline issues (very verbose).
		gstDebug?: string
	}

	// === GPU configuration ===
	gpu: {
		// GPU vendor.
		//   "intelamd" — mounts /dev/dri/* via hostPath (VAAPI / QSV)
		//   "nvidia"   — additionally mounts /dev/nvidia* and the driver hostPath
		type: *"intelamd" | "nvidia"

		// DRI render node. Use the following to identify which node is your GPU:
		//   ls -l /sys/class/drm/renderD*/device/driver
		renderNode: string | *"/dev/dri/renderD128"

		// NVIDIA-specific configuration (required when type == "nvidia")
		nvidia?: {
			// Path on the host containing NVIDIA driver files.
			// Prepare this once per host with:
			//
			//   curl https://raw.githubusercontent.com/games-on-whales/gow/master/images/nvidia-driver/Dockerfile \
			//     | docker build -t gow/nvidia-driver:latest -f - \
			//         --build-arg NV_VERSION=$(cat /sys/module/nvidia/version) .
			//   docker volume create nvidia-driver-vol
			//   docker create --rm \
			//     --mount source=nvidia-driver-vol,destination=/usr/nvidia \
			//     gow/nvidia-driver:latest sh
			//
			// Then set driverPath to the Docker volume's data directory:
			//   /var/lib/docker/volumes/nvidia-driver-vol/_data
			//
			// Or use any other directory containing the NVIDIA userspace libraries.
			driverPath: string | *"/var/lib/docker/volumes/nvidia-driver-vol/_data"

			// hostPathType for the driver volume mount
			// "" bypasses the kubelet's type check — required on Talos where
			// the glibc extension path resolves in a different mount namespace.
			hostPathType: *"Directory" | "DirectoryOrCreate" | ""
		}
	}

	// === Docker-in-Docker sidecar ===
	// Wolf requires a Docker daemon to spawn per-session app containers (Steam,
	// Firefox, etc.). On Kubernetes/Talos, the host has no accessible Docker
	// socket, so this module runs Docker-in-Docker (DinD) as a sidecar.
	//
	// The DinD container:
	//   - Listens on a shared Unix socket at /run/dind/docker.sock
	//   - Shares the Wolf config PVC at /etc/wolf so app containers can be
	//     bind-mounted with the correct per-user state paths
	//   - Shares the XDG socket emptyDir at /tmp/wolf-sockets so PulseAudio
	//     and Wayland compositor sockets are reachable from app containers
	//
	// IMPORTANT: DinD requires privileged: true at the Kubernetes pod level.
	// This must be permitted by the cluster security policy (PSA/PSP).
	dind: {
		// Container image for the Docker-in-Docker daemon
		image: schemas.#Image & {
			repository: string | *"docker"
			tag:        string | *"dind"
			digest:     string | *""
		}

		// Storage for Docker image layers pulled by the DinD daemon.
		// A PVC is strongly recommended — app images (Steam, etc.) are 10–20 GB
		// and re-pulling on every pod restart causes significant startup delay.
		storage: {
			type: *"pvc" | "emptyDir" | "hostPath"

			// PVC fields (when type == "pvc")
			// Tune size to the number and size of app images you run.
			// A minimal setup (Wolf UI only) needs ~5 Gi.
			// Steam requires ~20–30 Gi. Multiple games need 50–100 Gi.
			size:          string | *"50Gi"
			storageClass?: string

			// hostPath fields (when type == "hostPath")
			path?:         string
			hostPathType?: *"Directory" | "DirectoryOrCreate"
		}

		resources?: schemas.#ResourceRequirementsSchema

		// dockerd log level. Set to "debug" when troubleshooting DinD container
		// launch failures (e.g. Steam grey screen, mount issues, socket errors).
		// Valid values mirror dockerd --log-level: debug, info, warn, error, fatal.
		logLevel: *"info" | "debug" | "warn" | "error" | "fatal"
	}

	// === Networking ===
	networking: {
		// Bind the pod directly to the node's network stack.
		// When true, Wolf's streaming ports are exposed on the node IP without
		// NAT — lowest latency for UDP streams. When false, traffic flows
		// through the Kubernetes Service (LoadBalancer/NodePort/ClusterIP).
		// Set to false when using MetalLB or another LB that can handle the
		// streaming ports without NAT overhead.
		hostNetwork: bool | *true

		// Kubernetes Service type for the Wolf streaming ports.
		// LoadBalancer is typical for home/bare-metal clusters with MetalLB.
		// NodePort is an alternative when no LoadBalancer is available.
		serviceType: *"LoadBalancer" | "NodePort" | "ClusterIP"

		// Streaming protocol ports. Only override these if the defaults conflict
		// with other services on the same node. Wolf reads the corresponding
		// WOLF_*_PORT environment variables.
		httpsPort:   _#portSchema | *47984 // TCP — Moonlight HTTPS pairing
		httpPort:    _#portSchema | *47989 // TCP — Moonlight HTTP pairing
		controlPort: _#portSchema | *47999 // UDP — control channel
		rtspPort:    _#portSchema | *48010 // TCP — RTSP stream setup
		videoPort:   _#portSchema | *48100 // UDP — encoded video (H.264/HEVC/AV1)
		audioPort:   _#portSchema | *48200 // UDP — Opus audio
	}

	// === WolfManager (optional) ===
	// Web-based management interface for Wolf. Provides authenticated user
	// management, Moonlight device pairing UI, session monitoring, and
	// profile management. Communicates with Wolf via the Unix domain socket
	// at /run/wolf/wolf.sock. Stores its SQLite database on the wolf-config
	// volume so it inherits the same persistence as Wolf's own state.
	//
	// Source: https://github.com/salty2011/wolfmanager
	manager?: {
		// Enable the WolfManager sidecar container
		enabled: bool | *false

		// TCP port for the WolfManager web UI
		port: _#portSchema | *9971

		// WolfManager container image
		image: schemas.#Image & {
			repository: string | *"ghcr.io/salty2011/wolfmanager"
			tag:        string | *"main"
			digest:     string | *""
		}

		// Default admin account password (created on first start).
		// Injected as a K8s Secret — set value: or secretKeyRef: in the release.
		adminPassword: schemas.#Secret & {
			$secretName:  "wolfmanager"
			$dataKey:     "admin-password"
			$description: "WolfManager admin account password"
		}

		// JWT signing key for API token authentication (min 32 characters).
		// Injected as a K8s Secret — set value: or secretKeyRef: in the release.
		jwtSecretKey: schemas.#Secret & {
			$secretName:  "wolfmanager"
			$dataKey:     "jwt-secret-key"
			$description: "JWT signing key for API token auth (min 32 chars)"
		}

		resources?: schemas.#ResourceRequirementsSchema
	}

	// === Persistent storage for Wolf config and app state ===
	// Everything under /etc/wolf is stored here:
	//   cfg/config.toml              — Wolf config, paired clients, app definitions
	//   profile_data/$id/$app/       — Per-user, per-app persistent home directories
	//   fake-udev                    — Hotplug helper binary (auto-populated by Wolf)
	//
	// Size it to hold per-user app state. Steam client data alone is ~1–2 Gi per user.
	storage: {
		config: {
			type: *"pvc" | "hostPath" | "nfs"

			// PVC fields
			size:          string | *"20Gi"
			storageClass?: string

			// hostPath fields (when type == "hostPath")
			path?:         string
			hostPathType?: *"Directory" | "DirectoryOrCreate"

			// NFS fields (when type == "nfs")
			nfsServer?: string // NFS server hostname or IP (e.g. "10.10.0.2")
			nfsPath?:   string // Exported NFS path (e.g. "/mnt/nas/wolf")
		}
	}

	// === Resource limits for the Wolf container ===
	resources?: schemas.#ResourceRequirementsSchema

	// === GPU scheduling (optional) ===
	// Wolf renders via hostPath device passthrough (/dev/dri/*, /dev/nvidia*),
	// not the Kubernetes device plugin. A GPU resource claim is still useful to
	// ensure Kubernetes schedules the pod onto a node that has a physical GPU.
	//
	// Only set this if a compatible device plugin is installed on your cluster:
	//   NVIDIA GPU Operator → resource: "nvidia.com/gpu"
	//   AMD device plugin   → resource: "amd.com/gpu"
	//   Intel i915 plugin   → resource: "gpu.intel.com/i915"
	//   Intel Xe plugin     → resource: "gpu.intel.com/xe"
	//
	// Without a device plugin, use nodeSelector or node affinity in the
	// ModuleRelease to pin the pod to a GPU node instead.
	gpuScheduling?: {
		// Extended resource key reported by the device plugin on the node.
		resource: string // required — no default

		// Number of GPUs to claim. Defaults to 1.
		count: int & >=1 | *1
	}

	// === Wolf config file version ===
	// Wolf config.toml format version. Increment if Wolf introduces breaking changes.
	configVersion: int | *6

	// === Stable instance UUID ===
	// Required for consistent Moonlight pairing. Wolf embeds this UUID in its TLS
	// certificate and advertises it during host discovery. Changing this UUID breaks
	// all existing paired clients — they will need to re-pair.
	// Generate once with: uuidgen
	uuid: string

	// === GStreamer pipeline overrides (optional) ===
	// Override Wolf's built-in GStreamer audio/video pipelines. Only needed when
	// the defaults don't work well with your GPU hardware (e.g. custom VA-API nodes,
	// non-standard NVENC configurations, or specific codec tuning requirements).
	// When absent, Wolf uses its compiled-in default pipelines.
	gstreamer?: #GstreamerConfig

	// === Streaming profiles ===
	// Each profile groups a set of apps that Moonlight clients can launch.
	// At least one profile is required. Profiles are referenced by paired_clients
	// at runtime (managed by Wolf). The first profile is used for new pairings
	// unless a specific profile is assigned.
	profiles: [...#ProfileConfig]
}

// debugValues exercises the full #config surface for `cue vet` / `cue eval`.
debugValues: {
	wolf: {
		hostname:            "wolf"
		supportHevc:         true
		logLevel:            "DEBUG"
		stopContainerOnExit: true
	}

	gpu: {
		type:       "nvidia"
		renderNode: "/dev/dri/renderD129"
		nvidia: {
			driverPath:   "/var/lib/docker/volumes/nvidia-driver-vol/_data"
			hostPathType: "Directory"
		}
	}

	dind: {
		storage: {
			type:         "pvc"
			size:         "100Gi"
			storageClass: "local-path"
		}
		resources: {
			requests: {cpu: "500m", memory: "512Mi"}
			limits: {cpu: "4000m", memory: "4Gi"}
		}
	}

	networking: {
		serviceType: "LoadBalancer"
		httpsPort:   47984
		httpPort:    47989
		controlPort: 47999
		rtspPort:    48010
		videoPort:   48100
		audioPort:   48200
	}

	manager: {
		enabled: true
		port:    9971
		adminPassword: {value: "Debug@dmin99!"}
		jwtSecretKey: {value: "debug-wolf-jwt-secret-key-32chars-x"}
	}

	storage: config: {
		type:         "pvc"
		size:         "50Gi"
		storageClass: "local-path"
	}

	resources: {
		requests: {cpu: "1000m", memory: "2Gi"}
		limits: {cpu: "8000m", memory: "8Gi"}
	}

	gpuScheduling: {
		resource: "nvidia.com/gpu"
		count:    1
	}

	initImage: {
		repository: "ttl.sh/wolf-init"
		tag:        "latest"
		digest:     ""
	}

	uuid:          "00000000-0000-0000-0000-000000000001"
	configVersion: 6

	profiles: [{
		id:   "debug-profile"
		name: "Debug"
		apps: [{
			title:                    "Desktop"
			start_virtual_compositor: true
			start_audio_server:       true
			runner: {
				type:    "process"
				run_cmd: "bash"
			}
		}]
	}]
}
