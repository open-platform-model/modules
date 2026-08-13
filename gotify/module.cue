// Package gotify defines the Gotify notification server module.
// A single-container stateful application (Go) that receives messages over a
// REST API and streams them to clients over WebSocket:
// - module.cue:     metadata and config schema
// - components.cue: component definitions (catalog_opm blueprints/traits)
//
// Configuration is delivered entirely through GOTIFY_* environment variables.
// Gotify reads env before any config file and every option has an env
// equivalent, so this module renders no ConfigMap at all — unlike ntfy, which
// needs a server.yml because its image ships none.
//
// IMPORTANT — the declarative surface stops at the server. Applications (the
// senders that hold a token) and clients are created through the web UI or
// the REST API and live in the database; there is no config-file equivalent
// of ntfy's auth-users. This module owns the server settings and the
// bootstrap admin account, and nothing beyond that. Getting a token for an
// alerting system is a manual step, by design of the upstream.
//
// OPM v2 line: path major v2 (the v1 train publishes this registry path at
// major v1 — cross-train major separation), core@v2 identity reshape
// (complete modulePath with major, identity/ package, derived fqn), and the
// version-segment catalog imports (resources/v1beta1 etc.).
package gotify

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
	name:        "gotify"
	modulePath:  "opmodel.dev/modules/gotify@v2"
	version:     "2.0.0"
	description: "Gotify - self-hosted push notification server with REST API and WebSocket streaming"
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
	// Container image. Docker Hub tags are unprefixed semver ("3.0.0").
	image: res.#Image & {
		repository: string | *"gotify/server"
		tag:        string | *"3.0.0"
		digest:     string | *"sha256:d75e89e0e28389c00c2556afe01282a37ee9756b0285799aa25214243aebd5e5"
	}

	// Kubernetes Service port.
	port: int & >0 & <=65535 | *80

	// Port the server listens on inside the container (GOTIFY_SERVER_PORT).
	// The image already sets this to 80 and runs as root, so the default
	// binds fine.
	listenPort: int & >0 & <=65535 | *80

	// Container timezone (TZ database format).
	timezone: string | *"Europe/Stockholm"

	// Server log level.
	logLevel: "debug" | "info" | "warn" | "error" | *"info"

	// The bootstrap admin account. Applied ONLY when the database is first
	// created — changing the password here later has no effect on an existing
	// database, where it must be changed through the UI. The upstream default
	// password is literally "admin", so supplying a Secret is not optional in
	// any deployment reachable from outside the cluster.
	//
	// The v2 #Secret is a disjunction: the instance either supplies `value`
	// (a literal — the transformer creates the Kubernetes Secret) or
	// `secretName` + `remoteKey` (a reference to a pre-existing Secret; OPM
	// emits no resource and only wires the secretKeyRef).
	defaultUser: {
		name: string | *"admin"
		password: res.#Secret & {
			$secretName:  string | *"gotify"
			$dataKey:     string | *"admin-password"
			$description: "Gotify bootstrap admin password (applied only at database creation)"
		}
	}

	// Database backend. "sqlite3" keeps everything on the data volume and is
	// right for essentially every self-hosted deployment; the external
	// dialects exist for shared-database estates.
	//
	// For sqlite3 the connection path is derived from storage.data.mountPath,
	// so the database always follows the volume. For mysql/postgres the
	// connection string carries credentials and therefore arrives as a
	// Secret.
	database: {
		dialect: "sqlite3" | "mysql" | "postgres" | *"sqlite3"

		// Required when dialect != "sqlite3". Full DSN, e.g.
		// "host=db port=5432 user=gotify dbname=gotify password=..."
		connection?: res.#Secret & {
			$secretName:  string | *"gotify"
			$dataKey:     string | *"database-connection"
			$description: "Gotify external database connection string (DSN)"
		}
	}

	// Allow self-service account registration. Off by default.
	registration: bool | *false

	// bcrypt cost for stored passwords. Higher is slower to crack and slower
	// to log in with.
	passStrength: int & >=4 & <=31 | *10

	// Seconds between WebSocket keepalive pings. Raise the ingress idle
	// timeout to match if streams are being cut; lower this if they are.
	streamPingPeriodSeconds: int & >0 | *45

	// Mark session cookies Secure. Correct whenever the server is reached
	// over HTTPS, which is every ingress-fronted deployment.
	secureCookie: bool | *true

	// Escape hatch for GOTIFY_* options this schema does not model — OIDC
	// (GOTIFY_OIDC_*), CORS, trusted proxies, and the list-valued settings
	// whose env encoding is not verified here. Keys are used verbatim as
	// environment variable names.
	extraEnv?: [string]: string

	// Storage: one volume holds the SQLite database, uploaded application
	// images, and plugins. The image's working directory is /app and its
	// defaults are relative to it, so /app/data is the natural mountPath.
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
		repository: "gotify/server"
		tag:        "3.0.0"
		digest:     "sha256:d75e89e0e28389c00c2556afe01282a37ee9756b0285799aa25214243aebd5e5"
	}
	port:       80
	listenPort: 80
	timezone:   "Europe/Stockholm"
	logLevel:   "info"
	defaultUser: {
		name: "admin"
		// The k8s-ref branch of the #Secret disjunction: references a
		// pre-existing Secret, the shape SOPS-managed environments use.
		password: {
			$secretName: "gotify"
			$dataKey:    "admin-password"
			secretName:  "gotify"
			remoteKey:   "admin-password"
		}
	}
	database: {
		dialect: "postgres"
		connection: {
			$secretName: "gotify"
			$dataKey:    "database-connection"
			secretName:  "gotify"
			remoteKey:   "database-connection"
		}
	}
	registration:            false
	passStrength:            10
	streamPingPeriodSeconds: 45
	secureCookie:            true
	extraEnv: {
		GOTIFY_SERVER_TRUSTEDPROXIES: "10.0.0.0/8"
	}
	serviceType: "ClusterIP"
	resources: {
		requests: {
			cpu:    "50m"
			memory: "64Mi"
		}
		limits: {
			cpu:    "1000m"
			memory: "256Mi"
		}
	}
	httpRoute: {
		hostnames: ["gotify.example.com"]
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
