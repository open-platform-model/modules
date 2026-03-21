// Components defines the Wolf game streaming server workload.
//
// A single StatefulSet (`wolf`) is deployed containing:
//
//   initContainer: config-init
//     Merges the immutable ConfigMap-provided config.toml with existing
//     paired_clients data on disk. On first start: copies the ConfigMap
//     config directly. On subsequent starts: appends paired_clients blocks
//     from the existing on-disk config to preserve paired devices.
//
//   sidecar: dind
//     Docker-in-Docker daemon providing the Docker API Wolf uses to spawn
//     per-session app containers. Shares the config PVC and XDG socket volume
//     so that Wolf can pass correct bind-mount paths to those containers.
//
//   main: wolf
//     The Wolf streaming server. Talks to DinD via a shared Unix socket.
//     Mounts /dev and /run/udev from the host for GPU and virtual input access.
//
// Volume layout:
//
//   wolf-config   PVC/hostPath/NFS   → /etc/wolf       (wolf + dind)
//   docker-data   PVC/emptyDir/hostPath → /var/lib/docker  (dind only)
//   docker-socket emptyDir           → /run/dind        (wolf + dind)  ← shared socket
//   wolf-api      emptyDir           → /run/wolf        (wolf + dind)  ← wolf.sock (DinD needs it for Wolf-UI)
//   xdg-sockets   emptyDir           → /run/wolf-sockets (wolf + dind) ← PulseAudio/Wayland
//   dev           hostPath /dev      → /dev             (wolf + dind)
//   udev          hostPath /run/udev → /run/udev        (wolf + dind)
//   nvidia-driver hostPath (nvidia)  → /usr/nvidia      (wolf only, nvidia only)
//   wolf-config-toml configMap       → /etc/wolf-init/cfg  (config-init only) ← immutable config
//
// Security note:
//   DinD requires privileged: true at the pod level.
//   Wolf requires capabilities: [NET_RAW, MKNOD, NET_ADMIN, SYS_ADMIN, SYS_NICE]
//   and device cgroup rule "c 13:* rmw" for virtual input device (uinput/uhid) support.
//   These must be configured via the K8s provider / ModuleRelease annotations or
//   a cluster-level mutating webhook — the current OPM SecurityContextSchema does
//   not yet model container-level privileged or device cgroup rules.
package wolf

import (
	"encoding/toml"
	"list"

	resources_config "opmodel.dev/resources/config@v1"
	resources_workload "opmodel.dev/resources/workload@v1"
	resources_storage "opmodel.dev/resources/storage@v1"
	traits_workload "opmodel.dev/traits/workload@v1"
	traits_network "opmodel.dev/traits/network@v1"
)

// #components contains component definitions resolved at build time.
#components: {
	wolf: {
		resources_workload.#Container
		resources_storage.#Volumes
		resources_config.#ConfigMaps
		traits_workload.#InitContainers
		traits_workload.#SidecarContainers
		traits_workload.#Scaling
		traits_workload.#RestartPolicy
		traits_workload.#UpdateStrategy
		traits_workload.#GracefulShutdown
		traits_network.#HostNetwork
		traits_network.#Expose

		// StatefulSet — Wolf stores paired client state on the config PVC
		metadata: labels: "core.opmodel.dev/workload-type": "stateful"

		spec: {
			scaling: count: 1

			// hostNetwork: true binds Wolf directly to the node's network stack.
			// Wolf's streaming ports (47984/47989/48010 TCP, 47999/48100/48200 UDP)
			// are in the 47000–48200 range which falls outside the Kubernetes
			// NodePort range (30000–32767), so hostNetwork is required for clients
			// to reach Wolf on its standard ports.
			hostNetwork: true

			restartPolicy: "Always"

			// Recreate strategy — only one Wolf instance can use the GPU + uinput
			// devices safely at a time
			updateStrategy: type: "Recreate"

			// Allow in-flight streams and DinD containers to wind down gracefully
			gracefulShutdown: terminationGracePeriodSeconds: 60

			// ── Init Container: config-init ────────────────────────────────────
			// Merges the immutable ConfigMap config.toml with existing paired_clients
			// data on disk. This preserves Moonlight device pairings across restarts
			// and config updates.
			//
			// First start:      touches an empty on-disk config, then runs the CUE
			//                   merge tool — no paired_clients → writes incoming only.
			// Subsequent starts: CUE merge tool strips existing to paired_clients only,
			//                   unifies with incoming, validates, and writes atomically.
			//
			// The init container image contains Alpine + CUE and the wolfinit module.
			// Build from modules/wolf/Dockerfile.init and publish to ttl.sh.
			// ENTRYPOINT runs /init-entrypoint.sh which calls: cue cmd merge
			initContainers: [{
				name:  "config-init"
				image: #config.initImage

				// Reference volumes so the source type satisfies the matchN(1, [...]) constraint
				volumeMounts: {
					// Incoming config from the immutable ConfigMap (read-only)
					"wolf-config-toml": volumes["wolf-config-toml"] & {
						mountPath: "/etc/wolf-init/cfg"
						readOnly:  true
					}
					// Persistent config PVC — init writes merged result here
					"wolf-config": volumes["wolf-config"] & {
						mountPath: "/etc/wolf"
					}
				}
			}]

			// ── Sidecar: dind ─────────────────────────────────────────────────
			// Docker-in-Docker daemon providing the Docker API for Wolf to spawn
			// per-session app containers. Listens on a shared Unix socket so Wolf
			// does not need host Docker access.
			//
			// Required env:
			//   DOCKER_TLS_CERTDIR=""  — disables TLS so Wolf can connect without certs
			//
			// Required args passed to dockerd:
			//   --host unix:///run/dind/docker.sock — write socket to shared emptyDir
			//   --tls=false                          — no TLS on the socket
			//
			// Security: DinD requires privileged: true. Apply at the K8s provider level.
			//
			// The config PVC is mounted at /etc/wolf in DinD so that when Wolf tells
			// DinD to create an app container with "-v /etc/wolf/profile_data/...:/home/retro",
			// DinD can resolve that bind mount path from its own filesystem.
			//
			// The XDG socket emptyDir is mounted at /tmp/wolf-sockets in DinD so
			// PulseAudio containers spawned by DinD can bind-mount the same path.
			let _dindSidecar = [{
				name:  "dind"
				image: #config.dind.image
			args: [
				"--host", "unix:///run/dind/docker.sock",
				"--tls=false",
				// Use traditional overlay2 storage driver instead of the default
				// containerd-snapshotter (io.containerd.snapshotter.v1.overlayfs).
				// In containerd-snapshotter mode, Docker 29+ backs child container
				// bind mounts with a fresh tmpfs instead of real kernel bind mounts,
				// so sockets written by PA/Wolf-UI into /tmp/wolf-sockets land in that
				// tmpfs and are invisible to the wolf K8s container. overlay2 uses
				// standard kernel bind mounts, correctly sharing the K8s emptyDir.
				"--storage-driver", "overlay2",
				// Log level for the dockerd daemon. Defaults to "info".
				// Set dind.logLevel to "debug" in the release to diagnose container
				// launch failures (e.g. bind-mount errors, cgroup issues).
				"--log-level", #config.dind.logLevel,
			]
				// DinD requires privileged: true — Docker-in-Docker needs full
				// kernel access to create network namespaces, cgroups, and mounts.
				securityContext: {
					privileged: true
				}
				env: {
					// Empty string disables TLS certificate generation at startup
					DOCKER_TLS_CERTDIR: {
						name:  "DOCKER_TLS_CERTDIR"
						value: ""
					}
				}
				volumeMounts: {
					"wolf-config": volumes["wolf-config"] & {
						mountPath: "/etc/wolf"
					}
					"docker-data": volumes["docker-data"] & {
						mountPath: "/var/lib/docker"
					}
					"docker-socket": volumes["docker-socket"] & {
						mountPath: "/run/dind"
					}
					// Wolf REST API socket — DinD must be able to resolve /run/wolf/wolf.sock
					// (and /var/run/wolf/wolf.sock via the /var/run→/run symlink) when
					// bind-mounting it into Wolf-UI and other app containers.
					"wolf-api": volumes["wolf-api"] & {
						mountPath: "/run/wolf"
					}
					"xdg-sockets": volumes["xdg-sockets"] & {
						// /run is NOT mounted as tmpfs in DinD; child containers correctly
						// inherit this K8s emptyDir bind mount. /tmp IS tmpfs in DinD
						// and would shadow the emptyDir, breaking socket sharing.
						mountPath: "/run/wolf-sockets"
					}
					dev: volumes.dev & {
						mountPath: "/dev"
					}
					// Host udev database — needed so DinD can resolve /run/udev bind mounts
					// inside app containers (fake-udev and virtual device enumeration).
					udev: volumes.udev & {
						mountPath: "/run/udev"
					}
				}

				if #config.dind.resources != _|_ {
					resources: #config.dind.resources
				}
			}]

			// ── Optional management UI sidecar: WolfManager ──────────────────
			// Blazor Server web UI for Wolf management — user accounts, device
			// pairing, session monitoring, and profile management.
			// Enabled only when #config.manager is defined and manager.enabled is true.
			// Source: https://github.com/salty2011/wolfmanager
			let _managerSidecar = [if #config.manager != _|_ if #config.manager.enabled {
				{
					name:  "wolfmanager"
					image: #config.manager.image
					ports: {
						http: {
							targetPort: #config.manager.port
							protocol:   "TCP"
						}
					}
					env: {
						// ASP.NET Core port binding
						ASPNETCORE_URLS: {
							name:  "ASPNETCORE_URLS"
							value: "http://+:\(#config.manager.port)"
						}
						// SQLite database on the persistent wolf-config volume
						ConnectionStrings__Default: {
							name:  "ConnectionStrings__Default"
							value: "Data Source=/etc/wolf/wolfmanager.db"
						}
						// Wolf Unix socket connection
						Wolf__UseUnixSocket: {
							name:  "Wolf__UseUnixSocket"
							value: "true"
						}
						Wolf__UnixSocketPath: {
							name:  "Wolf__UnixSocketPath"
							value: "/run/wolf/wolf.sock"
						}
						// Admin account password (created on first start)
						Admin__Password: {
							name:  "Admin__Password"
							value: #config.manager.adminPassword
						}
						// JWT signing key for API token authentication
						Jwt__SecretKey: {
							name:  "Jwt__SecretKey"
							value: #config.manager.jwtSecretKey
						}
					}
					volumeMounts: {
						// Wolf REST API socket
						"wolf-api": volumes["wolf-api"] & {
							mountPath: "/run/wolf"
							readOnly:  true
						}
						// Persistent storage for SQLite database (wolfmanager.db)
						"wolf-config": volumes["wolf-config"] & {
							mountPath: "/etc/wolf"
						}
					}
					if #config.manager.resources != _|_ {
						resources: #config.manager.resources
					}
				}
			}]

			sidecarContainers: list.Concat([_dindSidecar, _managerSidecar])

			// ── Main container: wolf ───────────────────────────────────────────
			container: {
				name:  "wolf"
				image: #config.image

				// No containerPorts declared: Wolf uses hostNetwork: true and binds
				// directly to the node's network interfaces. Declaring ports here
				// triggers the Kubernetes scheduler's host-port conflict check, which
				// can prevent scheduling if a stale pod entry is in the scheduler cache.
				// The Service port mapping is driven entirely by the expose: spec below.

				// Wolf requires privileged to:
				//   - Open DRI GPU render nodes (/dev/dri/*)
				//   - Create virtual input devices via uinput/uhid (mknod, device cgroups)
				//   - Manage network namespaces for per-session app containers
				securityContext: {
					privileged: true
				}

				env: {
					// ── Wolf daemon settings ───────────────────────────────────
					WOLF_LOG_LEVEL: {
						name:  "WOLF_LOG_LEVEL"
						value: #config.wolf.logLevel
					}
					WOLF_CFG_FILE: {
						name:  "WOLF_CFG_FILE"
						value: "/etc/wolf/cfg/config.toml"
					}
					WOLF_STOP_CONTAINER_ON_EXIT: {
						name:  "WOLF_STOP_CONTAINER_ON_EXIT"
						value: "\(#config.wolf.stopContainerOnExit)"
					}

					// ── GPU ────────────────────────────────────────────────────
					WOLF_RENDER_NODE: {
						name:  "WOLF_RENDER_NODE"
						value: #config.gpu.renderNode
					}

					// ── Docker socket ──────────────────────────────────────────
					// Point Wolf at the DinD socket on the shared emptyDir volume
					WOLF_DOCKER_SOCKET: {
						name:  "WOLF_DOCKER_SOCKET"
						value: "/run/dind/docker.sock"
					}

					// ── Paths ──────────────────────────────────────────────────
					// HOST_APPS_STATE_FOLDER tells Wolf the base path under which
					// it will store per-user per-app persistent state. Wolf passes
					// this path to DinD as a bind mount source for app containers,
					// so it must match the mountPath of the wolf-config volume.
					HOST_APPS_STATE_FOLDER: {
						name:  "HOST_APPS_STATE_FOLDER"
						value: "/etc/wolf"
					}
					// XDG_RUNTIME_DIR is used by Wolf for PulseAudio and Wayland
					// compositor Unix sockets shared with app containers.
					// IMPORTANT: must be outside /tmp — DinD mounts /tmp as a tmpfs,
					// so bind mounts from /tmp paths in DinD child containers resolve
					// to DinD's tmpfs overlay rather than the K8s emptyDir, making
					// sockets invisible to the wolf K8s container. /run is NOT tmpfs.
					XDG_RUNTIME_DIR: {
						name:  "XDG_RUNTIME_DIR"
						value: "/run/wolf-sockets"
					}
					// Wolf REST API Unix socket path (used by Wolf UI internally)
					WOLF_SOCKET_PATH: {
						name:  "WOLF_SOCKET_PATH"
						value: "/run/wolf/wolf.sock"
					}
					// PulseAudio socket path. The GOW pulseaudio image creates its socket
					// at $XDG_RUNTIME_DIR/pulse-socket, not the libpulse default
					// $XDG_RUNTIME_DIR/pulse/native. Setting PULSE_SERVER here ensures
					// Wolf's own GStreamer pulsesrc pipeline connects to the right socket.
					PULSE_SERVER: {
						name:  "PULSE_SERVER"
						value: "/run/wolf-sockets/pulse-socket"
					}

					// ── Port overrides (only emit when non-default) ────────────
					if #config.networking.httpsPort != 47984 {
						WOLF_HTTPS_PORT: {
							name:  "WOLF_HTTPS_PORT"
							value: "\(#config.networking.httpsPort)"
						}
					}
					if #config.networking.httpPort != 47989 {
						WOLF_HTTP_PORT: {
							name:  "WOLF_HTTP_PORT"
							value: "\(#config.networking.httpPort)"
						}
					}
					if #config.networking.controlPort != 47999 {
						WOLF_CONTROL_PORT: {
							name:  "WOLF_CONTROL_PORT"
							value: "\(#config.networking.controlPort)"
						}
					}
					if #config.networking.rtspPort != 48010 {
						WOLF_RTSP_SETUP_PORT: {
							name:  "WOLF_RTSP_SETUP_PORT"
							value: "\(#config.networking.rtspPort)"
						}
					}
					if #config.networking.videoPort != 48100 {
						WOLF_VIDEO_PING_PORT: {
							name:  "WOLF_VIDEO_PING_PORT"
							value: "\(#config.networking.videoPort)"
						}
					}
					if #config.networking.audioPort != 48200 {
						WOLF_AUDIO_PING_PORT: {
							name:  "WOLF_AUDIO_PING_PORT"
							value: "\(#config.networking.audioPort)"
						}
					}

					// ── GStreamer debug (optional) ──────────────────────────────
					if #config.wolf.gstDebug != _|_ {
						GST_DEBUG: {
							name:  "GST_DEBUG"
							value: #config.wolf.gstDebug
						}
					}

					// ── NVIDIA-specific ────────────────────────────────────────
					if #config.gpu.type == "nvidia" if #config.gpu.nvidia != _|_ {
						NVIDIA_DRIVER_VOLUME_NAME: {
							name:  "NVIDIA_DRIVER_VOLUME_NAME"
							value: "nvidia-driver-vol"
						}
						NVIDIA_DRIVER_CAPABILITIES: {
							name:  "NVIDIA_DRIVER_CAPABILITIES"
							value: "all"
						}
						NVIDIA_VISIBLE_DEVICES: {
							name:  "NVIDIA_VISIBLE_DEVICES"
							value: "all"
						}
					}
				}

				// Reference volumes from spec.volumes so the source type is included,
				// satisfying the #VolumeMountSchema matchN(1, [...]) constraint.
				volumeMounts: {
					// Wolf configuration, paired clients, and app state
					"wolf-config": volumes["wolf-config"] & {
						mountPath: "/etc/wolf"
					}
					// Shared Docker socket — talks to the DinD daemon
					"docker-socket": volumes["docker-socket"] & {
						mountPath: "/run/dind"
					}
					// Wolf REST API Unix socket
					"wolf-api": volumes["wolf-api"] & {
						mountPath: "/run/wolf"
					}
					// PulseAudio and Wayland compositor sockets — mounted at /run, not /tmp,
					// because DinD mounts /tmp as tmpfs which shadows K8s emptyDir bind mounts.
					"xdg-sockets": volumes["xdg-sockets"] & {
						mountPath: "/run/wolf-sockets"
					}
					// Host /dev — GPU, uinput, uhid device access
					dev: volumes.dev & {
						mountPath: "/dev"
					}
					// Host /run/udev — udev event socket for virtual device detection
					udev: volumes.udev & {
						mountPath: "/run/udev"
					}
					// NVIDIA driver libraries (nvidia only)
					if #config.gpu.type == "nvidia" if #config.gpu.nvidia != _|_ {
						"nvidia-driver": volumes["nvidia-driver"] & {
							mountPath: "/usr/nvidia"
						}
					}
				}

				if #config.resources != _|_ {
					resources: #config.resources
				}

				// GPU scheduling claim: merged into resources.gpu so the transformer
				// emits the extended resource to both requests and limits.
				if #config.gpuScheduling != _|_ {
					resources: gpu: {
						resource: #config.gpuScheduling.resource
						count:    #config.gpuScheduling.count
					}
				}
			}

			// ── Network exposure ───────────────────────────────────────────────
			// Expose all streaming ports via a Kubernetes Service.
			// For host-network pods (hostNetwork: true), this Service is still
			// useful as a stable DNS endpoint for management/observability — the
			// actual streaming traffic goes directly over the node IP.
			expose: {
				ports: {
					https: {
						targetPort:  #config.networking.httpsPort
						protocol:    "TCP"
						exposedPort: #config.networking.httpsPort
					}
					http: {
						targetPort:  #config.networking.httpPort
						protocol:    "TCP"
						exposedPort: #config.networking.httpPort
					}
					rtsp: {
						targetPort:  #config.networking.rtspPort
						protocol:    "TCP"
						exposedPort: #config.networking.rtspPort
					}
					control: {
						targetPort:  #config.networking.controlPort
						protocol:    "UDP"
						exposedPort: #config.networking.controlPort
					}
					video: {
						targetPort:  #config.networking.videoPort
						protocol:    "UDP"
						exposedPort: #config.networking.videoPort
					}
					audio: {
						targetPort:  #config.networking.audioPort
						protocol:    "UDP"
						exposedPort: #config.networking.audioPort
					}
					if #config.manager != _|_ if #config.manager.enabled {
						manager: {
							targetPort:  #config.manager.port
							protocol:    "TCP"
							exposedPort: #config.manager.port
						}
					}
				}
				type: #config.networking.serviceType
			}

			// ── ConfigMap: wolf-config-toml ────────────────────────────────────
			// Immutable ConfigMap containing the rendered config.toml (all sections
			// except paired_clients, which Wolf manages at runtime). Marked immutable
			// so any config change produces a new ConfigMap name (via content hash),
			// triggering a pod restart to pick up the new configuration.
			configMaps: {
				"wolf-config-toml": {
					immutable: true
					data: {
						// CUE renders the complete config.toml at build time via toml.Marshal.
						// paired_clients is intentionally omitted — Wolf writes that section.
						"config.toml": "\(toml.Marshal(#WolfTomlConfig & {
							config_version: #config.configVersion
							hostname:       #config.wolf.hostname
							uuid:           #config.uuid
							profiles:       #config.profiles
							if #config.gstreamer != _|_ {
								gstreamer: #config.gstreamer
							}
						}))"
					}
				}
			}

			// ── Volumes ────────────────────────────────────────────────────────
			volumes: {
				// Wolf configuration, paired clients, and per-user app state
				"wolf-config": {
					name: "wolf-config"
					if #config.storage.config.type == "pvc" {
						persistentClaim: {
							size: #config.storage.config.size
							if #config.storage.config.storageClass != _|_ {
								storageClass: #config.storage.config.storageClass
							}
						}
					}
					if #config.storage.config.type == "hostPath" {
						hostPath: {
							path: #config.storage.config.path
							type: #config.storage.config.hostPathType
						}
					}
					if #config.storage.config.type == "nfs" {
						nfs: {
							server: #config.storage.config.nfsServer
							path:   #config.storage.config.nfsPath
						}
					}
				}

				// Docker image layers for the DinD daemon
				"docker-data": {
					name: "docker-data"
					if #config.dind.storage.type == "pvc" {
						persistentClaim: {
							size: #config.dind.storage.size
							if #config.dind.storage.storageClass != _|_ {
								storageClass: #config.dind.storage.storageClass
							}
						}
					}
					if #config.dind.storage.type == "emptyDir" {
						emptyDir: {}
					}
					if #config.dind.storage.type == "hostPath" {
						hostPath: {
							path: #config.dind.storage.path
							type: #config.dind.storage.hostPathType
						}
					}
				}

				// Shared Unix socket between DinD and Wolf
				// DinD writes: /run/dind/docker.sock
				// Wolf reads:  /run/dind/docker.sock (via WOLF_DOCKER_SOCKET)
				"docker-socket": {
					name: "docker-socket"
					emptyDir: {}
				}

				// Wolf REST API Unix socket (wolf.sock)
				// Consumed by Wolf UI and optional nginx API proxy sidecar
				"wolf-api": {
					name: "wolf-api"
					emptyDir: {}
				}

				// PulseAudio and Wayland compositor Unix sockets (XDG_RUNTIME_DIR)
				// Wolf creates sockets here; app containers spawned by DinD bind-mount
				// this same path to access the audio and display streams.
				"xdg-sockets": {
					name: "xdg-sockets"
					emptyDir: {}
				}

				// Host /dev — grants Wolf and DinD access to:
				//   /dev/dri/*     — GPU render nodes (Intel/AMD/NVIDIA)
				//   /dev/uinput    — virtual joypad creation (requires udev rules)
				//   /dev/uhid      — DualSense emulation
				//   /dev/nvidia*   — NVIDIA device nodes (nvidia only)
				dev: {
					name: "dev"
					hostPath: {
						path: "/dev"
						type: "Directory"
					}
				}

				// Host /run/udev — udev socket and database for virtual device hotplug
				// Wolf uses fake-udev to send events into app container namespaces
				udev: {
					name: "udev"
					hostPath: {
						path: "/run/udev"
						type: "Directory"
					}
				}

				// ConfigMap volume: immutable config.toml rendered by CUE.
				// Mounted read-only by config-init at /etc/wolf-init/cfg.
				// Wolf reads the merged result from the wolf-config PVC, not here.
				"wolf-config-toml": {
					name:      "wolf-config-toml"
					configMap: spec.configMaps["wolf-config-toml"]
				}

				// NVIDIA driver libraries (mounted at /usr/nvidia inside Wolf)
				// Created from a gow/nvidia-driver Docker image — see README.
				if #config.gpu.type == "nvidia" if #config.gpu.nvidia != _|_ {
					"nvidia-driver": {
						name: "nvidia-driver"
						hostPath: {
							path: #config.gpu.nvidia.driverPath
							type: #config.gpu.nvidia.hostPathType
						}
					}
				}
			}
		}
	}
}
