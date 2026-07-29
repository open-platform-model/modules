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
	version:     "2.3.0"
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
