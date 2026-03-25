package zot_registry_ttl

import (
	m "opmodel.dev/core/v1alpha1/module@v1"
	schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)

m.#Module

metadata: {
	modulePath:  "opmodel.dev/modules"
	name:        "zot-registry-ttl"
	version:     "0.1.0"
	description: "Ephemeral OCI registry with automatic image expiration via Zot retention policies"
	labels: {
		"app.kubernetes.io/component": "registry"
	}
}

#config: {
	// Image configuration -- always use full image (retention policies require full zot)
	image: schemas.#Image & {
		repository: string | *"ghcr.io/project-zot/zot"
		tag:        string | *"v2.1.15"
		digest:     string | *"sha256:376cb38a335bab89571af306eff481547212746aff11828043c22f32637fe17b"
	}

	// TTL policies -- maps repository path prefixes to expiration durations
	ttl: {
		// List of per-path TTL policies.
		// Convention: push images to `<ttl-prefix>/image:tag` to apply a specific TTL.
		// e.g. registry/1h/my-image:tag expires in ~1h
		policies: [...{
			// Repository glob patterns (e.g. ["1h/**"])
			repositories: [...string]
			// Keep images pushed/pulled within this window
			pushedWithin: string
			pulledWithin: string
		}] | *[
			{repositories: ["1h/**"], pushedWithin: "1h", pulledWithin: "1h"},
			{repositories: ["6h/**"], pushedWithin: "6h", pulledWithin: "6h"},
			{repositories: ["24h/**"], pushedWithin: "24h", pulledWithin: "24h"},
		]

		// Fallback TTL applied to all repos not matched by above policies
		defaultTTL: string | *"24h"

		// Grace period before deletion executes after retention marks an image
		delay: string | *"1h"
	}

	// Storage configuration
	storage: {
		type:         "pvc" | *"emptyDir"
		rootDir:      string | *"/var/lib/registry"
		size:         string | *"20Gi"
		storageClass: string | *"standard"

		// Garbage collection settings
		gc: {
			delay:    string | *"1h"
			interval: string | *"1h"
		}
	}

	// HTTP server
	http: {
		port:    int | *5000
		address: string | *"0.0.0.0"
	}

	// Logging
	log: {
		level: "debug" | *"info" | "warn" | "error"
	}

	// Optional Gateway API HTTPRoute
	httpRoute?: {
		hostnames: [...string]
		tls?: {
			secretName: string
		}
		gatewayRef?: {
			name:      string
			namespace: string
		}
	}

	// Workload
	replicas: int & >=1 & <=3 | *1

	resources: schemas.#ResourceRequirementsSchema | *{
		requests: {
			memory: "128Mi"
			cpu:    "50m"
		}
		limits: {
			memory: "512Mi"
			cpu:    "250m"
		}
	}

	security: schemas.#SecurityContextSchema | *{
		runAsNonRoot:             true
		runAsUser:                1000
		runAsGroup:               1000
		readOnlyRootFilesystem:   false
		allowPrivilegeEscalation: false
		capabilities: {
			drop: ["ALL"]
		}
	}
}

// debugValues exercises the full #config surface for local cue vet / cue eval.
debugValues: {
	image: {
		repository: "ghcr.io/project-zot/zot"
		tag:        "v2.1.15"
		digest:     "sha256:376cb38a335bab89571af306eff481547212746aff11828043c22f32637fe17b"
	}
	ttl: {
		policies: [
			{repositories: ["1h/**"], pushedWithin: "1h", pulledWithin: "1h"},
			{repositories: ["6h/**"], pushedWithin: "6h", pulledWithin: "6h"},
			{repositories: ["24h/**"], pushedWithin: "24h", pulledWithin: "24h"},
		]
		defaultTTL: "24h"
		delay:      "1h"
	}
	storage: {
		type:         "emptyDir"
		rootDir:      "/var/lib/registry"
		size:         "20Gi"
		storageClass: "standard"
		gc: {
			delay:    "1h"
			interval: "1h"
		}
	}
	http: {
		port:    5000
		address: "0.0.0.0"
	}
	log: {
		level: "info"
	}
	httpRoute: {
		hostnames: ["ttl.registry.local"]
		gatewayRef: {
			name:      "gateway"
			namespace: "default"
		}
	}
	replicas: 1
	resources: {
		requests: {
			memory: "128Mi"
			cpu:    "50m"
		}
		limits: {
			memory: "512Mi"
			cpu:    "250m"
		}
	}
	security: {
		runAsNonRoot:             true
		runAsUser:                1000
		runAsGroup:               1000
		readOnlyRootFilesystem:   false
		allowPrivilegeEscalation: false
		capabilities: drop: ["ALL"]
	}
}
