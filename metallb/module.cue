// Package metallb defines the MetalLB bare-metal load-balancer module.
// Deploys the MetalLB controller (Deployment), speaker (DaemonSet), all 9
// CRD definitions, the four RBAC pairs, and the metallb-system namespace:
// - module.cue:     metadata and config schema
// - components.cue: component definitions (catalog_opm blueprints/traits +
//                   the resources/v1alpha1 #Namespaces resource)
// - crds_data.cue:  vendored upstream CRDs (generated from crds/*.yaml)
//
// Upstream: https://metallb.io | https://github.com/metallb/metallb
// Pinned upstream release: v0.16.1 (native HTTPS metrics on :9120, health
// probes on :17472; webhook mode stays disabled — no VWC is deployed).
//
// The module emits NO IPAddressPool/L2Advertisement instances — pools are
// applied separately post-deploy (they would belong to a metallb provider
// catalog, not this module).
//
// ⚠ Instance-name coupling: RBAC resourceNames scoping references the
// rendered object names `metallb-controller` (Deployment) and
// `metallb-speaker-memberlist` (Secret), both of which embed the
// ModuleInstance name. Deploy this module as an instance named exactly
// `metallb` (namespace `metallb-system`).
package metallb

import (
	m "opmodel.dev/core@v2"
	res "opmodel.dev/catalogs/opm/resources/v1beta1"
)

// Module definition
m.#Module

// Module metadata — modulePath is the COMPLETE CUE module path including the
// major, byte-identical to cue.mod's module field and identity/identity.cue;
// fqn/registryPath/uuid derive from it (enhancement 0010).
metadata: {
	name:        "metallb"
	modulePath:  "opmodel.dev/modules/metallb@v2"
	version:     "2.0.0"
	description: "MetalLB bare metal load-balancer for Kubernetes — deploys controller, speaker, CRDs, RBAC, and the metallb-system namespace"
}

// Schema only — constraints for users, no defaults beyond image and log levels.
#config: {
	// Image configuration — tag is shared across all MetalLB components.
	image: res.#Image & {
		// Controller image repository; the speaker uses quay.io/metallb/speaker
		// with the same tag.
		repository: string | *"quay.io/metallb/controller"
		// MetalLB release tag. See https://github.com/metallb/metallb/releases.
		tag:    string | *"v0.16.1"
		digest: string | *""
	}

	// Controller configuration — handles IP address assignment for LoadBalancer Services.
	controller: {
		// Structured log level for the controller.
		logLevel: "debug" | *"info" | "warn" | "error"
		// Number of controller replicas.
		replicas: int & >=1 | *1
		// Resource requests and limits (optional — omit to use cluster defaults).
		resources?: res.#ResourceRequirementsSchema
	}

	// Speaker configuration — runs on every node and announces LoadBalancer IPs via L2/BGP.
	speaker: {
		// Structured log level for the speaker.
		logLevel: "debug" | *"info" | "warn" | "error"
		// Resource requests and limits (optional — omit to use cluster defaults).
		resources?: res.#ResourceRequirementsSchema
		// Memberlist gossip encryption key — shared across all speaker pods.
		// OPM creates and manages the K8s Secret; provide the key value in
		// instance values. Generate with:
		//   head -c 128 /dev/urandom | base64 | tr -d '\n'
		memberlistKey: res.#Secret & {
			$secretName: "memberlist"
			$dataKey:    "secretkey"
		}
	}
}

// debugValues exercises the full #config surface for local `cue vet` / `cue eval`.
debugValues: {
	image: {
		repository: "quay.io/metallb/controller"
		tag:        "v0.16.1"
		digest:     ""
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
				cpu:    "300m"
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
				cpu:    "300m"
				memory: "128Mi"
			}
		}
	}
}
