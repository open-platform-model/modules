// Package mc_router defines a standalone mc-router for hostname-based TCP routing.
//
// Unlike a static-mapping router, this runs itzg/mc-router in Kubernetes
// service-discovery mode (IN_KUBE_CLUSTER): it watches Services and reads the
// mc-router.itzg.me/externalServerName and mc-router.itzg.me/defaultServer
// annotations to auto-register backends at runtime. The mc_java_server module
// stamps those annotations onto each server's Service, so adding/removing a
// server requires no router change.
//
// ## Watch scope
//
// By default the router watches ONLY its own namespace (KUBE_NAMESPACE), and its
// RBAC is a namespaced Role/RoleBinding. This makes it safe to run multiple
// routers in one cluster (e.g. a trial alongside production) — each only ever
// sees the Services in its own namespace and they never fight over backends.
// Set router.watchAllNamespaces: true to widen discovery cluster-wide (then a
// ClusterRole is used instead).
package mc_router

import (
	m "opmodel.dev/core/v1alpha1/module@v1"
	schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)

// Module definition
m.#Module

// Module metadata
metadata: {
	modulePath:       "opmodel.dev/modules"
	name:             "mc-router"
	version:          "0.1.0"
	description:      "Standalone itzg/mc-router in Kubernetes service-discovery mode (namespace-scoped by default)"
	defaultNamespace: "default"
}

_#portSchema: uint & >0 & <=65535

// Module config schema
#config: {
	// Must match the ModuleRelease metadata.name exactly. Used to name the router
	// identity (ServiceAccount/Role/RoleBinding = {releaseName}-router).
	releaseName: string

	// Kubernetes namespace the router is deployed into.
	namespace: string

	router: {
		// Container image for mc-router
		image: schemas.#Image & {
			repository: string | *"itzg/mc-router"
			tag:        string | *"1.40.3"
			digest:     string | *""
		}

		// Minecraft listening port on the router Service
		port: _#portSchema | *25565

		// Service type for the router (typically LoadBalancer for public access)
		serviceType: *"LoadBalancer" | "ClusterIP" | "NodePort"

		// Maximum connection rate per second
		connectionRateLimit: int & >0 | *1

		// Enable debug logging
		debug: bool | *false

		// Simplify SRV record lookup
		simplifySrv: bool | *false

		// Enable PROXY protocol for downstream servers
		useProxyProtocol: bool | *false

		// === Watch scope ===
		// Namespace mc-router restricts its Service watch to. Defaults to the
		// router's own namespace so it never observes Services elsewhere.
		watchNamespace: string | *namespace

		// Widen discovery to ALL namespaces (cluster-wide). When true, KUBE_NAMESPACE
		// is omitted and the RBAC is rendered as a ClusterRole/ClusterRoleBinding.
		watchAllNamespaces: bool | *false

		// Default server when no hostname matches (optional). Prefer marking a
		// server with mc-router.itzg.me/defaultServer instead; this is a fallback.
		defaultServer?: {
			host: string
			port: _#portSchema
		}

		// Auto-scale configuration (wake/sleep StatefulSets on player connect/disconnect)
		autoScale?: {
			up?: {
				enabled: bool
			}
			down?: {
				enabled: bool
				after?:  string
			}
		}

		// Metrics backend configuration
		metrics?: {
			backend: "discard" | "expvar" | "influxdb" | "prometheus"
		}

		// REST API configuration
		api: {
			enabled: bool | *false
			port:    _#portSchema | *8080
		}

		// Resource limits for the router container
		resources?: schemas.#ResourceRequirementsSchema
	}
}

// debugValues exercises the #config surface for local cue vet / cue eval.
debugValues: {
	releaseName: "mc-router-test"
	namespace:   "minecraft-test"
	router: {
		port:        25565
		serviceType: "ClusterIP"
		api: {
			enabled: true
			port:    8080
		}
	}
}
