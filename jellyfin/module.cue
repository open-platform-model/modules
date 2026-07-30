// Package jellyfin defines the Jellyfin media server module.
// A single-container stateful application using the LinuxServer.io image:
// - module.cue:     metadata and config schema
// - components.cue: component definitions (catalog_opm blueprints/traits)
//
// Rebased onto the OPM core catalog (opmodel.dev/catalogs/opm@v1). The previous
// K8up backup feature has been dropped — the core catalog has no backup
// resource. Config storage, media mounts, the web Service, optional GPU
// passthrough, optional Gateway HTTPRoute, and optional Serilog logging remain.
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
	version:     "2.4.0"
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

	// Container resource requests and limits (incl. optional GPU passthrough).
	// When absent, no resource constraints are applied to the container.
	resources?: res.#ResourceRequirementsSchema

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
	// The motivating case is hardware transcoding: `resources.gpu` asks for a
	// device, but nothing steers the pod toward a node that HAS one. On a
	// mixed cluster the pod either lands somewhere without the device and
	// fails, or schedules only by luck. `nodeSelector` closes that gap, and
	// `tolerations` covers GPU nodes that carry a dedicated taint.
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
		gpu: {
			resource: "gpu.intel.com/i915"
			count:    1
		}
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
