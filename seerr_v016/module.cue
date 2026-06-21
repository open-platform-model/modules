// Package main defines the Seerr media request manager module.
// A single-container stateful application (formerly Jellyseerr/Overseerr):
// - module.cue: metadata and config schema
// - components.cue: component definitions
package seerr

import (
	m "opmodel.dev/core/v1alpha1/module@v1"
	schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)

// Module definition
m.#Module

// Module metadata
metadata: {
	modulePath:       "opmodel.dev/modules"
	name:             "seerr"
	version:          "0.1.0"
	description:      "Seerr media request manager - request and manage media for Jellyfin, Plex, and Emby"
	defaultNamespace: "seerr"
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

// Schema only - constraints for users, no defaults
#config: {
	// Container image
	image: schemas.#Image & {
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

	// Optional: pre-set the API key via secret reference
	apiKey?: schemas.#Secret & {
		$secretName:  string
		$dataKey:     string
		$description: "Seerr API key"
	}

	// Optional: PostgreSQL database (default: SQLite stored in config volume)
	postgres?: {
		host: string
		port: int | *5432
		user: string
		password: schemas.#Secret & {
			$secretName:  string
			$dataKey:     string
			$description: "PostgreSQL password for Seerr"
		}
		name:   string | *"seerr"
		useSSL: bool | *false
	}

	// Storage definitions — config is required, holds SQLite DB + settings.json
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

	// Optional K8up backup configuration.
	// When set, creates a K8up Schedule CR and (for SQLite mode) a PreBackupPod CR for consistency.
	backup?: {
		// Name of the config PVC as rendered by OPM (e.g. "seerr-seerr-config").
		// Required so the PreBackupPod can mount the correct volume.
		configPvcName: string
		// Cron schedule for backups (default: 2 AM daily)
		schedule: *"0 2 * * *" | string
		// S3 backend configuration
		s3: {
			endpoint: string
			bucket:   string
			accessKeyID: schemas.#Secret & {
				$secretName:  "backup-s3"
				$dataKey:     "access-key-id"
				$description: "S3 access key ID for K8up backup"
			}
			secretAccessKey: schemas.#Secret & {
				$secretName:  "backup-s3"
				$dataKey:     "secret-access-key"
				$description: "S3 secret access key for K8up backup"
			}
		}
		// Restic repository password secret
		repoPassword: schemas.#Secret & {
			$secretName:  "backup-restic"
			$dataKey:     "password"
			$description: "Restic repository encryption password"
		}
		// Retention policy for prune
		retention: {
			keepDaily:   *7 | int
			keepWeekly:  *4 | int
			keepMonthly: *6 | int
		}
		// Cron schedule for repository integrity checks (default: 4 AM Sundays)
		checkSchedule: *"0 4 * * 0" | string
		// Cron schedule for pruning old snapshots (default: 5 AM Sundays)
		pruneSchedule: *"0 5 * * 0" | string
	}

	// Container resource requests and limits.
	resources?: schemas.#ResourceRequirementsSchema & {
		requests: {
			cpu:    *"100m" | _
			memory: *"256Mi" | _
		}
		limits: {
			cpu:    *"1000m" | _
			memory: *"1Gi" | _
		}
	}
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
	apiKey: {
		$secretName:  "seerr-api"
		$dataKey:     "api-key"
		$description: "Seerr API key"
	}
	postgres: {
		host: "postgres.db.svc.cluster.local"
		port: 5432
		user: "seerr"
		password: {
			$secretName:  "seerr-db"
			$dataKey:     "password"
			$description: "PostgreSQL password for Seerr"
		}
		name:   "seerr"
		useSSL: false
	}
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
	backup: {
		configPvcName: "seerr-seerr-config"
		s3: {
			endpoint: "http://10.10.0.2:30304"
			bucket:   "seerr-backup"
			accessKeyID: {value: "debug-access-key-id-value"}
			secretAccessKey: {value: "debug-secret-access-key-value"}
		}
		repoPassword: {value: "debug-restic-password-32chars!!"}
		retention: {
			keepDaily:   7
			keepWeekly:  4
			keepMonthly: 6
		}
	}
}
