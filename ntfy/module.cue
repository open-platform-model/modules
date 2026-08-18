// Package ntfy defines the ntfy notification server module.
// A single-container stateful application (Go) that delivers push
// notifications to phones and desktops over HTTP pub/sub topics:
// - module.cue:     metadata and config schema
// - components.cue: component definitions (catalog_opm blueprints/traits)
//
// Configuration is delivered as a CUE-rendered server.yml mounted read-only
// at /etc/ntfy/server.yml. The image ships NO config file of its own, so the
// mount is the entire configuration surface.
//
// Users, ACL entries and access tokens are PROVISIONED — ntfy seeds its auth
// database from auth-users / auth-access / auth-tokens on every start, and a
// user removed from that config is deleted on the next restart. That makes
// the whole auth surface CUE-owned rather than something managed by hand with
// `ntfy user add`. Password hashes and tokens arrive through env vars sourced
// from a Secret (NTFY_AUTH_USERS / NTFY_AUTH_TOKENS) so no credential
// material lands in the ConfigMap; the non-secret half (topic ACLs, default
// access) is rendered into server.yml.
//
// OPM v2 line: path major v2 (the v1 train publishes this registry path at
// major v1 — cross-train major separation), core@v2 identity reshape
// (complete modulePath with major, identity/ package, derived fqn), and the
// version-segment catalog imports (resources/v1beta1 etc.).
package ntfy

import (
	id "opmodel.dev/modules/ntfy/identity"
	m "opmodel.dev/core@v2"
	res "opmodel.dev/catalogs/opm/resources/v1beta1"
)

// Module definition
m.#Module

// Module metadata — modulePath is the COMPLETE CUE module path including the
// major, byte-identical to cue.mod's module field and identity/identity.cue;
// fqn/registryPath/uuid derive from it (enhancement 0010).
metadata: {
	name:        "ntfy"
	modulePath:  id.ModulePath
	version:     id.Version
	description: "ntfy - self-hosted pub/sub push notification server for phone and desktop"
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

// #accessEntry is one ACL row, rendered into auth-access as
// "<user>:<topic>:<permission>" and applied to the auth database at startup.
#accessEntry: {
	// Username the entry applies to. "*" means anonymous (unauthenticated)
	// callers — the form UnifiedPush needs.
	user: string | *"*"

	// Topic name or pattern. Trailing "*" wildcards are supported, e.g.
	// "alerts*" matches "alerts-nas1".
	topic: string

	// Short permission forms, matching what ntfy writes in its own docs.
	permission: "rw" | "ro" | "wo" | "deny"
}

// Schema only - constraints for users.
#config: {
	// Container image. Docker Hub tags carry the leading "v" ("v2.27.0").
	image: res.#Image & {
		repository: string | *"binwiederhier/ntfy"
		tag:        string | *"v2.27.0"
		digest:     string | *"sha256:f2419f405127afa868f10985c1a41449e673477cee1eb19994339a5ae8b592e7"
	}

	// Kubernetes Service port.
	port: int & >0 & <=65535 | *80

	// Port the server listens on inside the container (listen-http). The
	// image runs as root, so the default 80 binds fine. Raise this above
	// 1024 if you add a securityContext that drops to a non-root UID — this
	// module does not set one, because the PVC would then also need matching
	// fsGroup ownership.
	listenPort: int & >0 & <=65535 | *80

	// Public URL clients use to reach this server, scheme included. REQUIRED:
	// ntfy refuses to start without base-url once behind a proxy, and every
	// attachment/click URL it generates is built from it.
	baseUrl: string & =~"^https?://"

	// Trust X-Forwarded-For for the visitor IP. Correct behind an ingress
	// gateway; without it every request appears to come from the proxy and
	// rate limiting applies to the proxy rather than the caller.
	behindProxy: bool | *true

	// Container timezone (TZ database format).
	timezone: string | *"Europe/Stockholm"

	// Authentication and access control. auth-file is always set (it is what
	// enables auth at all), and defaults to deny-all so a fresh instance is
	// private until an ACL entry opens something up.
	auth: {
		// Fallback access when no ACL entry matches.
		defaultAccess: "deny-all" | "read-only" | "write-only" | "read-write" | *"deny-all"

		// The complete auth-users value: a comma-separated list of
		// "<username>:<bcrypt-hash>:<role>" entries, where role is "admin"
		// or "user". Supplied as a Secret rather than plain config because
		// bcrypt hashes are crackable offline and a ConfigMap is readable by
		// anything with get access in the namespace.
		//
		// Generate a hash with:  ntfy user hash
		// Example value:         "emil:$2a$10$...:admin,alerts:$2a$10$...:user"
		//
		// REQUIRED: with defaultAccess deny-all and no users, nothing can
		// publish or subscribe at all, which is never what you want.
		//
		// The v2 #Secret is a disjunction: the instance either supplies
		// `value` (a literal — the transformer creates the Kubernetes Secret)
		// or `secretName` + `remoteKey` (a reference to a pre-existing Secret;
		// OPM emits no resource and only wires the secretKeyRef).
		users: res.#Secret & {
			$secretName:  string | *"ntfy"
			$dataKey:     string | *"auth-users"
			$description: "ntfy provisioned users — comma-separated user:bcrypt-hash:role entries"
		}

		// Optional pre-created access tokens, as a comma-separated list of
		// "<username>:tk_<32 chars>[:<label>]" entries. Useful for handing a
		// fixed token to an alerting system instead of a password.
		tokens?: res.#Secret & {
			$secretName:  string | *"ntfy"
			$dataKey:     string | *"auth-tokens"
			$description: "ntfy provisioned access tokens — comma-separated user:token:label entries"
		}

		// Topic ACLs. These are not secret, so they render into server.yml
		// where they stay reviewable in a diff.
		access: [...#accessEntry] | *[]
	}

	// Grant anonymous write-only access to "up*" topics, which is all a
	// UnifiedPush distributor needs. Appended to the ACL list above rather
	// than replacing it.
	unifiedPush: bool | *false

	// Message cache. ntfy keeps messages in SQLite so a phone that was
	// offline can catch up; duration is how far back that history reaches.
	cache: {
		duration: string | *"12h"
	}

	// Attachment support. Omit the block entirely to disable attachments —
	// attachment-cache-dir unset is what turns the feature off.
	attachments?: {
		totalSizeLimit: string | *"5G"
		fileSizeLimit:  string | *"15M"
		expiryDuration: string | *"3h"
	}

	// Forward poll requests to an upstream ntfy server so iOS devices get
	// instant delivery. ONLY the message ID is sent upstream; the phone then
	// fetches the body from this server. Without it, iOS delivery degrades to
	// whatever interval the OS feels like polling at — hours, per upstream.
	// Set to "https://ntfy.sh" to use the public instance for the APNs hop.
	upstreamBaseUrl?: string & =~"^https?://"

	// Which web app pages are served at the root path. "app" serves the web
	// app, "home" the landing page, "disable" turns the web UI off entirely.
	webRoot?: "app" | "home" | "disable"

	// Self-service account signup. Off by default — provisioned users are the
	// point of this module.
	enableSignup: bool | *false

	// Whether the web UI offers a login form at all.
	enableLogin: bool | *true

	// Storage: one volume holds everything ntfy persists — the message cache
	// database, the auth database, and attachments if enabled. All three
	// paths are derived from this mountPath in components.cue.
	storage: {
		data: #storageVolume & {
			mountPath: *"/var/lib/ntfy" | string
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
		repository: "binwiederhier/ntfy"
		tag:        "v2.27.0"
		digest:     "sha256:f2419f405127afa868f10985c1a41449e673477cee1eb19994339a5ae8b592e7"
	}
	port:        80
	listenPort:  80
	baseUrl:     "https://ntfy.example.com"
	behindProxy: true
	timezone:    "Europe/Stockholm"
	auth: {
		defaultAccess: "deny-all"
		// The k8s-ref branch of the #Secret disjunction: references a
		// pre-existing Secret, the shape SOPS-managed environments use.
		users: {
			$secretName: "ntfy"
			$dataKey:    "auth-users"
			secretName:  "ntfy"
			remoteKey:   "auth-users"
		}
		tokens: {
			$secretName: "ntfy"
			$dataKey:    "auth-tokens"
			secretName:  "ntfy"
			remoteKey:   "auth-tokens"
		}
		access: [
			{user: "emil", topic: "*", permission: "rw"},
			{user: "alerts", topic: "nas1-*", permission: "wo"},
		]
	}
	unifiedPush: true
	cache: duration: "12h"
	attachments: {
		totalSizeLimit: "5G"
		fileSizeLimit:  "15M"
		expiryDuration: "3h"
	}
	upstreamBaseUrl: "https://ntfy.sh"
	webRoot:         "app"
	enableSignup:    false
	enableLogin:     true
	serviceType:     "ClusterIP"
	resources: {
		requests: {
			cpu:    "50m"
			memory: "64Mi"
		}
		limits: {
			cpu:    "1000m"
			memory: "512Mi"
		}
	}
	httpRoute: {
		hostnames: ["ntfy.example.com"]
		gatewayRef: {
			name:      "gateway-gateway"
			namespace: "istio-ingress"
		}
	}
	storage: {
		data: {
			mountPath:    "/var/lib/ntfy"
			type:         "pvc"
			size:         "5Gi"
			storageClass: "local-path"
		}
	}
}
