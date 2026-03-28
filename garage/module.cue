// Package garage defines the Garage S3-compatible object storage module.
// A single-container stateless application configured via a TOML ConfigMap:
// - module.cue: metadata and config schema
// - components.cue: component definitions
package garage

import (
	m "opmodel.dev/core/v1alpha1/module@v1"
	schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)

// Module definition
m.#Module

// Module metadata
metadata: {
	modulePath:       "opmodel.dev/modules"
	name:             "garage"
	version:          "0.1.0"
	description:      "Garage - lightweight S3-compatible distributed object storage"
	defaultNamespace: "garage"
}

// #config defines the configuration schema for the Garage module.
#config: {
	// Container image
	image: schemas.#Image & {
		repository: *"dxflrs/garage" | string
		tag:        *"v2.2.0" | string
		digest:     *"sha256:45a61ce3f7c9c24fc23d9ed2b09b27ed560ab87b34605d175d5c588f539c24e4" | string
	}

	// Target namespace
	namespace: *"garage" | string

	// S3 API port
	s3Port: *3900 | int

	// Admin API port
	adminPort: *3903 | int

	// Cluster RPC port
	rpcPort: *3901 | int

	// S3 region name
	region: *"garage" | string

	// Admin API bearer token — required, no default
	adminToken: string

	// RPC secret — required, no default (64 hex chars for single-node setup)
	rpcSecret: string

	// Container resource requests and limits
	resources: {
		requests: {
			cpu:    *"100m" | string
			memory: *"256Mi" | string
		}
		limits: {
			cpu:    *"500m" | string
			memory: *"512Mi" | string
		}
	}

	// Storage configuration for meta and data directories.
	// emptyDir loses data on pod restart; use "pvc" for persistence.
	storage: {
		type:         *"emptyDir" | "pvc"
		size:         *"1Gi" | string
		storageClass: *"" | string
	}

	// Kubernetes Service type
	serviceType: *"ClusterIP" | string
}

debugValues: {
	image: {
		repository: "dxflrs/garage"
		tag:        "v2.2.0"
		digest:     "sha256:45a61ce3f7c9c24fc23d9ed2b09b27ed560ab87b34605d175d5c588f539c24e4"
	}
	namespace:  "garage"
	s3Port:     3900
	adminPort:  3903
	rpcPort:    3901
	region:     "garage"
	adminToken: "debug-admin-token"
	rpcSecret:  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	resources: {
		requests: {
			cpu:    "100m"
			memory: "256Mi"
		}
		limits: {
			cpu:    "500m"
			memory: "512Mi"
		}
	}
	storage: {
		type:         "emptyDir"
		size:         "1Gi"
		storageClass: ""
	}
	serviceType: "ClusterIP"
}
