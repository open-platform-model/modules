// MetalLB — bare metal load-balancer for Kubernetes.
// Deploys the MetalLB controller (Deployment), speaker (DaemonSet), all CRD definitions,
// and the required ClusterRoles + ClusterRoleBindings.
//
// https://metallb.io  |  https://github.com/metallb/metallb
package metallb

import (
	m       "opmodel.dev/core/v1alpha1/module@v1"
	schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)

m.#Module

metadata: {
	modulePath:       "opmodel.dev/modules"
	name:             "metallb"
	version:          "0.1.0"
	description:      "MetalLB bare metal load-balancer for Kubernetes — deploys controller, speaker, CRDs, and RBAC"
	defaultNamespace: "metallb-system"
	labels: {
		"app.kubernetes.io/component": "load-balancer"
	}
}

#config: {
	// Image configuration — tag is shared across all MetalLB components (controller, speaker).
	image: {
		// MetalLB release tag (e.g., "v0.15.3"). See https://github.com/metallb/metallb/releases.
		tag: string | *"v0.15.3"
		// Image pull policy applied to both controller and speaker.
		pullPolicy: "Always" | *"IfNotPresent" | "Never"
	}

	// Controller configuration — handles IP address assignment for LoadBalancer Services.
	controller: {
		// Structured log level for the controller.
		logLevel: "debug" | *"info" | "warn" | "error"
		// Number of controller replicas.
		replicas: int & >=1 | *1
		// Resource requests and limits (optional — omit to use cluster defaults).
		resources?: schemas.#ResourceRequirementsSchema
	}

	// Speaker configuration — runs on every node and announces LoadBalancer IPs via L2/BGP.
	speaker: {
		// Structured log level for the speaker.
		logLevel: "debug" | *"info" | "warn" | "error"
		// Resource requests and limits (optional — omit to use cluster defaults).
		resources?: schemas.#ResourceRequirementsSchema
		// Memberlist gossip encryption key — shared across all speaker pods.
		// OPM creates and manages the K8s Secret; provide the key value in release values.
		// Generate with: head -c 128 /dev/urandom | base64 | tr -d '\n'
		memberlistKey: schemas.#Secret & {
			$secretName: "memberlist"
			$dataKey:    "secretkey"
		}
	}
}

// debugValues exercises the full #config surface for local `cue vet` / `cue eval`.
debugValues: {
	image: {
		tag:        "v0.15.3"
		pullPolicy: "IfNotPresent"
	}
	controller: {
		logLevel: "info"
		replicas: 1
		resources: {
			requests: {
				cpu:    "100m"
				memory: "64Mi"
			}
			limits: {
				cpu:    "200m"
				memory: "128Mi"
			}
		}
	}
	speaker: {
		logLevel: "info"
		memberlistKey: value: "debug-gossip-key-for-cue-vet-only"
		resources: {
			requests: {
				cpu:    "100m"
				memory: "64Mi"
			}
			limits: {
				cpu:    "200m"
				memory: "128Mi"
			}
		}
	}
}
