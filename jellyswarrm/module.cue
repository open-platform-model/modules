// Package jellyswarrm defines the Jellyswarrm proxy module.
// A single-container stateful application (Rust) that merges multiple
// Jellyfin servers into one virtual Jellyfin endpoint:
// - module.cue:     metadata and config schema
// - components.cue: component definitions (catalog_opm blueprints/traits)
//
// Configuration is delivered as a CUE-rendered jellyswarrm.toml mounted
// read-only over the data volume — NOT via environment variables. Verified
// against 0.3.0 (2026-08-11): the app's config loader splits env keys on
// every underscore, so every multi-word JELLYSWARRM_* variable
// (PUBLIC_ADDRESS, SERVER_NAME, PRECONFIGURED_SERVERS, SESSION_KEY, ...)
// is silently ignored; only single-word ones (USERNAME, PASSWORD, PORT,
// HOST, TIMEOUT) work, and env values cannot carry lists at all. The TOML
// file is the only complete declarative interface. See DEPLOYMENT_NOTES.md.
//
// OPM v2 line: path major v2 (the v1 train publishes this registry path at
// major v1 — cross-train major separation), core@v2 identity reshape
// (complete modulePath with major, identity/ package, derived fqn), and the
// version-segment catalog imports (resources/v1beta1 etc.).
package jellyswarrm

import (
	id "opmodel.dev/modules/jellyswarrm/identity"
	m "opmodel.dev/core@v2"
	res "opmodel.dev/catalogs/opm/resources/v1beta1"
)

// Module definition
m.#Module

// Module metadata — modulePath is the COMPLETE CUE module path including the
// major, byte-identical to cue.mod's module field and identity/identity.cue;
// fqn/registryPath/uuid derive from it (enhancement 0010).
metadata: {
	name:        "jellyswarrm"
	modulePath:  id.ModulePath
	version:     id.Version
	description: "Jellyswarrm reverse proxy - combine multiple Jellyfin servers into one virtual Jellyfin endpoint"
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

// #backendServer is one upstream Jellyfin server, rendered into the TOML's
// [[preconfigured_servers]] and upserted into Jellyswarrm's SQLite database
// on EVERY pod start, keyed by trailing-slash-normalized URL. Changing
// priority/mode/display-name for an existing URL propagates on the next
// restart; REMOVING an entry does not delete the server from the database —
// removal stays a UI operation (no pruning in the app).
#backendServer: {
	// Base URL of the upstream Jellyfin server. This is the identity key in
	// Jellyswarrm's database — changing it registers a NEW server rather
	// than moving the old one.
	url: string & =~"^https?://"

	// Higher priority wins when merging results across servers.
	priority: int | *100

	// How media reaches the client. "Proxy" streams through Jellyswarrm;
	// "Redirect" hands the client the upstream server's own URL, so it only
	// works when clients can reach that URL directly. In-cluster backends
	// behind ClusterIP Services therefore need "Proxy" — which is also the
	// application default in 0.3.0 (the upstream docs still say Redirect;
	// that is outdated).
	mediaStreamingMode: *"Proxy" | "Redirect"
}

// Schema only - constraints for users.
#config: {
	// Container image. GHCR tags are unprefixed semver ("0.3.0", not
	// "v0.3.0" — the release tags carry the v, the image tags do not).
	image: res.#Image & {
		repository: string | *"ghcr.io/llukas22/jellyswarrm"
		tag:        string | *"0.3.0"
		digest:     string | *"sha256:1d61193d34035dee9acf6b5d9388721867dff74fc64ec0f2c7a87b7ff075b9f5"
	}

	// Kubernetes Service port. The container itself always listens on 3000:
	// pinning the app port removes the kubelet service-link hazard — the
	// Service named "jellyswarrm" makes kubelet inject JELLYSWARRM_PORT=
	// tcp://<ip>:<port> into the pod (their issue #53), and the app's
	// fallback parser turns any such garbage into the default 3000. With
	// the app fixed at 3000, that worst case is a no-op.
	port: int & >0 & <=65535 | *3000

	// Stable server identity, 32 hex chars. REQUIRED with no default on
	// purpose: the app only persists a generated ID when it creates the
	// config file itself, and this module mounts the config read-only — an
	// unpinned server_id would regenerate on every pod start, churning the
	// identity Jellyfin clients key their server list on.
	// Generate once with: openssl rand -hex 16
	serverId: string & =~"^[0-9a-f]{32}$"

	// Address clients use to reach the proxy (scheme + host, e.g.
	// "https://swarm.example.com"). REQUIRED: the app default is
	// localhost:3000, which breaks playback URLs for any real client, and
	// the JELLYSWARRM_PUBLIC_ADDRESS env override does not work (see
	// package comment).
	publicAddress: string & =~"^https?://"

	// Display name clients see for the virtual server.
	serverName: string | *"Jellyswarrm Proxy"

	// Management UI admin account. The username is plain config (rendered
	// into the TOML); the password is injected via the JELLYSWARRM_PASSWORD
	// env var — one of the few that actually works — so it never lands in
	// the ConfigMap. Env overrides the TOML, so the app's built-in default
	// password is unreachable as long as the Secret exists.
	// The v2 #Secret is a disjunction: the instance either supplies `value`
	// (a literal — the transformer creates the Kubernetes Secret) or
	// `secretName` + `remoteKey` (a reference to a pre-existing Secret; OPM
	// emits no resource and only wires the secretKeyRef).
	username: string | *"admin"
	password: res.#Secret & {
		$secretName:  string | *"jellyswarrm"
		$dataKey:     string | *"admin-password"
		$description: "Jellyswarrm management UI admin password"
	}

	// Upstream Jellyfin servers, keyed by display name. May be empty —
	// servers can also be added at runtime via the management UI (those
	// live in SQLite and coexist with these; see #backendServer for the
	// update/no-prune semantics).
	servers: [Name=string]: #backendServer

	// Append the origin server's name to media titles in merged listings.
	includeServerNameInMedia: bool | *true

	// Merge equally-named libraries from different servers into one virtual
	// library (0.3.0 feature). The UI toggle for this writes to the config
	// file and therefore fails against this module's read-only mount — set
	// it here instead.
	mergeLibraries: bool | *true

	// Auto-create local proxy users when an upstream login succeeds.
	autoCreateUsersOnLogin: bool | *true

	// Default streaming mode for servers added via the UI (preconfigured
	// servers carry their own per-server mode).
	mediaStreamingMode: *"Proxy" | "Redirect"

	// Upstream request timeout in seconds.
	timeout: int & >0 | *20

	// Seconds between background health checks of upstream servers.
	serverBackgroundCheckIntervalSecs: int & >0 | *30

	// Optional URL prefix for all routes (reverse-proxy sub-path setups).
	// Path segment without slashes, e.g. "jellyswarrm".
	urlPrefix?: string & =~"^[^/]+$"

	// Path segment of the management UI (application default: "ui").
	uiRoute?: string & =~"^[^/]+$"

	// Path the liveness/readiness probes GET. The default is answered
	// locally by the proxy itself (verified 200 on 0.3.0 with zero backends
	// configured and no auth) — it does not depend on any upstream server.
	// Written WITHOUT the urlPrefix: when urlPrefix is set, components.cue
	// prepends it automatically (all routes move under the prefix).
	healthPath: string | *"/System/Info/Public"

	// Storage: data holds the SQLite database (server registry, user
	// mappings, sessions). The CUE-rendered jellyswarrm.toml is subPath-
	// mounted over <mountPath>/jellyswarrm.toml, so the config file the app
	// sees is never the PVC's copy.
	storage: {
		data: #storageVolume & {
			mountPath: *"/app/data" | string
			type:      *"pvc" | "emptyDir" | "nfs"
			size:      string | *"2Gi"
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
		repository: "ghcr.io/llukas22/jellyswarrm"
		tag:        "0.3.0"
		digest:     "sha256:1d61193d34035dee9acf6b5d9388721867dff74fc64ec0f2c7a87b7ff075b9f5"
	}
	port:          3000
	serverId:      "0123456789abcdef0123456789abcdef"
	publicAddress: "https://swarm.example.com"
	serverName:    "Jellyswarrm Proxy"
	username:      "admin"
	// The k8s-ref branch of the #Secret disjunction: references a
	// pre-existing Secret, the shape the SOPS-managed environments use.
	password: {
		$secretName: "jellyswarrm"
		$dataKey:    "admin-password"
		secretName:  "jellyswarrm"
		remoteKey:   "admin-password"
	}
	servers: {
		"Living Room": {
			url:      "http://jellyfin.media.svc.cluster.local:8096"
			priority: 100
		}
		"Remote": {
			url:                "https://jellyfin.friend.example.com"
			priority:           90
			mediaStreamingMode: "Proxy"
		}
	}
	includeServerNameInMedia:          true
	mergeLibraries:                    true
	autoCreateUsersOnLogin:            true
	mediaStreamingMode:                "Proxy"
	timeout:                           20
	serverBackgroundCheckIntervalSecs: 30
	urlPrefix:                         "jellyswarrm"
	uiRoute:                           "ui"
	healthPath:                        "/System/Info/Public"
	serviceType:                       "ClusterIP"
	resources: {
		requests: {
			cpu:    "50m"
			memory: "128Mi"
		}
		limits: {
			cpu:    "1000m"
			memory: "512Mi"
		}
	}
	httpRoute: {
		hostnames: ["swarm.example.com"]
		gatewayRef: {
			name:      "gateway-gateway"
			namespace: "istio-ingress"
		}
	}
	storage: {
		data: {
			mountPath:    "/app/data"
			type:         "pvc"
			size:         "2Gi"
			storageClass: "local-path"
		}
	}
}
