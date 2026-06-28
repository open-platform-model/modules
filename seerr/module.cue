// Package seerr defines the Seerr media request manager module.
// A single-container stateful application (formerly Jellyseerr/Overseerr):
// - module.cue:     metadata and config schema
// - components.cue: component definitions (catalog_opm blueprints/traits)
//
// Rebased onto the OPM core catalog (opmodel.dev/catalogs/opm@v1) and
// simplified: the K8up backup, external PostgreSQL, and API-key-secret options
// were dropped. Seerr stores its settings in a SQLite database on the config
// PVC; service integrations are configured via the web UI after deploy.
package seerr

import (
	m "opmodel.dev/core@v1"
	res "opmodel.dev/catalogs/opm/resources"
)

// Module definition
m.#Module

// Module metadata
metadata: {
	modulePath:  "opmodel.dev/modules"
	name:        "seerr"
	version:     "1.0.0"
	description: "Seerr media request manager - request and manage media for Jellyfin, Plex, and Emby"
}

// #storageVolume is the shared schema for all storage entries.
#storageVolume: {
	mountPath:     string
	type:          "pvc" | "emptyDir" | "nfs"
	size?:         string // required when type == "pvc"
	storageClass?: string // optional, only used when type == "pvc"
	server?:       string // required when type == "nfs"
	path?:         string // required when type == "nfs"
}

// Schema only - constraints for users.
#config: {
	// Container image
	image: res.#Image & {
		repository: string | *"ghcr.io/seerr-team/seerr"
		tag:        string | *"v3.1.0"
		digest:     string | *"sha256:b35ba0461c4a1033d117ac1e5968fd4cbe777899e4cbfbdeaf3d10a42a0eb7e9"
	}

	// Exposed service port for the web UI
	port: int & >0 & <=65535 | *5055

	// Container timezone (TZ database format)
	timezone: string | *"Europe/Stockholm"

	// Optional: application log level
	logLevel?: "debug" | "info" | "warn" | "error"

	// Storage definitions — config is required, holds the SQLite DB + settings.json
	storage: {
		config: #storageVolume & {
			mountPath: *"/app/config" | string
			type:      *"pvc" | "emptyDir" | "nfs"
			size:      string | *"5Gi"
		}
	}

	// Kubernetes Service type
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
	resources?: res.#ResourceRequirementsSchema
}

debugValues: {
	image: {
		repository: "ghcr.io/seerr-team/seerr"
		tag:        "v3.1.0"
		digest:     "sha256:b35ba0461c4a1033d117ac1e5968fd4cbe777899e4cbfbdeaf3d10a42a0eb7e9"
	}
	port:        5055
	timezone:    "Europe/Stockholm"
	logLevel:    "info"
	serviceType: "ClusterIP"
	resources: {
		requests: {
			cpu:    "100m"
			memory: "256Mi"
		}
		limits: {
			cpu:    "1000m"
			memory: "1Gi"
		}
	}
	httpRoute: {
		hostnames: ["seerr.example.com"]
		gatewayRef: {
			name:      "gateway-gateway"
			namespace: "istio-ingress"
		}
	}
	storage: {
		config: {
			mountPath:    "/app/config"
			type:         "pvc"
			size:         "5Gi"
			storageClass: "local-path"
		}
	}
}
