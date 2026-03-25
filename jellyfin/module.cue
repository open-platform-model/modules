// Package main defines the Jellyfin media server module.
// A single-container stateful application using the LinuxServer.io image:
// - module.cue: metadata and config schema
// - components.cue: component definitions
// - values.cue: default values
package jellyfin

import (
	m "opmodel.dev/core/v1alpha1/module@v1"
	schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)

// Module definition
m.#Module

// Module metadata
metadata: {
	modulePath:       "opmodel.dev/modules"
	name:             "jellyfin"
	version:          "0.1.0"
	description:      "Jellyfin media server - a free software media system"
	defaultNamespace: "jellyfin"
}

// #storageVolume is the shared schema for all storage entries.
// Every volume — config, backup, and media — uses this same shape.
#storageVolume: {
	mountPath:     string
	type:          "pvc" | "emptyDir" | "nfs"
	size?:         string // required when type == "pvc"
	storageClass?: string // optional, only used when type == "pvc"
	server?:       string // required when type == "nfs"
	path?:         string // required when type == "nfs"
}

// Schema only - constraints for users, no defaults
#config: {
	// Container image
	image: schemas.#Image & {
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

	// All storage definitions in one place: config, optional backup, and media mounts.
	// Every entry uses #storageVolume; config applies sensible defaults.
	storage: {
		// Application data — defaults to a 10Gi PVC mounted at /config
		config: #storageVolume & {
			mountPath: *"/config" | string
			type:      *"pvc" | "emptyDir" | "nfs"
			size:      string | *"10Gi"
		}
		// Optional backup volume — defaults to Jellyfin's built-in backup path
		backup?: #storageVolume & {
			mountPath: *"/config/data/backups" | string
		}
		// Media library mounts keyed by library name (e.g. "movies", "series")
		media?: [Name=string]: #storageVolume
	}

	// Kubernetes Service type for the Jellyfin web UI
	serviceType: "ClusterIP" | "NodePort" | "LoadBalancer" | *"ClusterIP"

	// Container resource requests and limits.
	// When absent, no resource constraints are applied to the container.
	resources?: schemas.#ResourceRequirementsSchema & {
		requests?: {
			cpu?:    *"500m" | _
			memory?: *"1Gi" | _
		}
		limits?: {
			cpu?:    *"4000m" | _
			memory?: *"4Gi" | _
		}
	}

	// Optional Serilog structured logging configuration.
	// When set, a ConfigMap is created and mounted at /config/logging.json.
	logging?: {
		defaultLevel: *"Information" | "Debug" | "Warning" | "Error"
		overrides?: [string]: "Debug" | "Information" | "Warning" | "Error"
	}
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
			}
		}
	}
}
