// Package jellystat defines the Jellystat statistics dashboard module.
//
// Jellystat collects playback history and library statistics from a Jellyfin
// (or Emby) server and serves them as a web dashboard. Unlike the other media
// modules in this directory it is NOT self-contained: it requires PostgreSQL,
// and stores everything except its filesystem backups there.
//
// - module.cue:     metadata and config schema
// - components.cue: component definitions (catalog_opm blueprints/traits)
//
// The database can either be run by this module (`database.mode: "bundled"`,
// the default — a PostgreSQL StatefulSet alongside the app, mirroring the
// upstream docker-compose) or supplied externally (`database.mode: "external"`).
package jellystat

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
	name:        "jellystat"
	modulePath:  "opmodel.dev/modules/jellystat@v2"
	version:     "2.0.0"
	description: "Jellystat - playback statistics and monitoring dashboard for Jellyfin/Emby, backed by PostgreSQL"
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
		repository: string | *"cyfershepard/jellystat"
		tag:        string | *"1.1.11"
		digest:     string | *"sha256:c4e2dfa8bddf8d5ac3a675d7202f71a54dcfe3540cc186899d9201e0fe701fa5"
	}

	// Service port. Jellystat's own listener is hardcoded upstream
	// (backend/server.js: `const PORT = 3000`) and there is no env var to move
	// it, so only the Service-side port is configurable — the container always
	// listens on 3000.
	servicePort: int & >0 & <=65535 | *3000

	// Container timezone (TZ database format)
	timezone: string | *"Europe/Stockholm"

	// Address the app binds to inside the container (JS_LISTEN_IP).
	listenIp: string | *"0.0.0.0"

	// Optional subpath to serve the UI under (JS_BASE_URL), e.g. "/jellystat".
	// Must start with "/" and must not end with one — the probe paths below are
	// built by appending to it, and upstream normalises the slashes itself.
	baseUrl?: string & =~"^/[^ ]*[^/ ]$"

	// Key used to sign Jellystat's authentication JWTs. Required.
	// Generate with: openssl rand -hex 32
	jwtSecret: res.#Secret & {
		$secretName:  "jellystat"
		$dataKey:     "jwt-secret"
		$description: "Key used to sign Jellystat's authentication JWTs"
	}

	// PostgreSQL connection. Jellystat cannot run without one.
	database: {
		// "bundled" renders a PostgreSQL StatefulSet in this module and points
		// the app at it. "external" uses `host` and renders no database.
		mode: *"bundled" | "external"

		// Database Jellystat uses (POSTGRES_DB). Jellystat CREATEs this itself
		// on first start — see the bootstrap note on `user` below.
		name: string | *"jfstat"

		// Role Jellystat authenticates as.
		//
		// Bootstrap detail worth knowing before changing this: Jellystat's
		// create_database.js connects with no database named, so node-pg falls
		// back to a database matching the ROLE NAME, and only then issues
		// `CREATE DATABASE <name>`. The bundled PostgreSQL therefore leaves
		// POSTGRES_DB unset so the official image creates a database named
		// after the user — exactly what upstream's compose file does. In
		// external mode the server must likewise already have a database named
		// after this role, or first start fails to bootstrap.
		user: string | *"jellystat"

		password: res.#Secret & {
			$secretName:  "jellystat"
			$dataKey:     "postgres-password"
			$description: "Password for the Jellystat PostgreSQL role"
		}

		port: int & >0 & <=65535 | *5432

		ssl: {
			// POSTGRES_SSL_ENABLED
			enabled: bool | *false
			// POSTGRES_SSL_REJECT_UNAUTHORIZED — verify the server certificate.
			rejectUnauthorized: bool | *true
		}

		// Hostname of the PostgreSQL server. Required when mode == "external";
		// ignored when mode == "bundled" (the bundled Service name is used).
		host?: string

		// Settings for the bundled PostgreSQL. Inert when mode == "external".
		bundled: {
			// Service name for the bundled database, and the hostname the app
			// connects to. Rendered verbatim rather than instance-prefixed,
			// because a module cannot know its own instance name at build time
			// and the app needs a concrete POSTGRES_IP. Two instances of this
			// module in one namespace must therefore override it.
			serviceName: string | *"jellystat-db"

			// PostgreSQL 18 puts PGDATA at /var/lib/postgresql/18/docker and
			// declares /var/lib/postgresql as its volume, so the PVC mounts at
			// the parent and initdb creates the version subdirectory. That also
			// sidesteps the classic lost+found-in-PGDATA problem.
			image: res.#Image & {
				repository: string | *"postgres"
				tag:        string | *"18.1"
				digest:     string | *"sha256:1090bc3a8ccfb0b55f78a494d76f8d603434f7e4553543d6e807bc7bd6bbd17f"
			}

			storage: #storageVolume & {
				mountPath: *"/var/lib/postgresql" | string
				type:      *"pvc" | "emptyDir" | "nfs"
				size:      string | *"10Gi"
			}

			resources?: res.#ResourceRequirementsSchema
		}
	}

	// Media-server behaviour toggles.
	server: {
		// Target an Emby server instead of Jellyfin (IS_EMBY_API).
		isEmbyApi: bool | *false
		// Use the Jellyfin websocket API for live session tracking
		// (JF_USE_WEBSOCKETS).
		useWebsockets: bool | *true
		// Reject self-signed certificates when calling the media server
		// (REJECT_SELF_SIGNED_CERTIFICATES). Set false for an internal CA.
		rejectSelfSignedCertificates: bool | *true
		// Hours after which a resumed session counts as a new watch event
		// (NEW_WATCH_EVENT_THRESHOLD_HOURS).
		newWatchEventThresholdHours?: int & >=0
	}

	// Optional MaxMind GeoLite2 credentials for geolocating sessions.
	geolite?: {
		accountId: res.#Secret & {
			$secretName:  "jellystat"
			$dataKey:     "geolite-account-id"
			$description: "MaxMind GeoLite2 account ID"
		}
		licenseKey: res.#Secret & {
			$secretName:  "jellystat"
			$dataKey:     "geolite-license-key"
			$description: "MaxMind GeoLite2 license key"
		}
	}

	// Storage definitions — backup holds Jellystat's own export/backup files.
	// All other state lives in PostgreSQL.
	storage: {
		backup: #storageVolume & {
			mountPath: *"/app/backend/backup-data" | string
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
		repository: "cyfershepard/jellystat"
		tag:        "1.1.11"
		digest:     "sha256:c4e2dfa8bddf8d5ac3a675d7202f71a54dcfe3540cc186899d9201e0fe701fa5"
	}
	servicePort: 3000
	timezone:    "Europe/Stockholm"
	listenIp:    "0.0.0.0"
	baseUrl:     "/jellystat"
	// The k8s-ref branch of the #Secret disjunction: references a
	// pre-existing Secret, the shape the SOPS-managed environments use.
	jwtSecret: {
		$secretName: "jellystat"
		$dataKey:    "jwt-secret"
		secretName:  "jellystat"
		remoteKey:   "jwt-secret"
	}
	database: {
		mode: "bundled"
		name: "jfstat"
		user: "jellystat"
		password: {
			$secretName: "jellystat"
			$dataKey:    "postgres-password"
			secretName:  "jellystat"
			remoteKey:   "postgres-password"
		}
		port: 5432
		ssl: {
			enabled:            false
			rejectUnauthorized: true
		}
		host: "postgres.example.com"
		bundled: {
			serviceName: "jellystat-db"
			image: {
				repository: "postgres"
				tag:        "18.1"
				digest:     "sha256:1090bc3a8ccfb0b55f78a494d76f8d603434f7e4553543d6e807bc7bd6bbd17f"
			}
			storage: {
				mountPath:    "/var/lib/postgresql"
				type:         "pvc"
				size:         "10Gi"
				storageClass: "local-path"
			}
			resources: {
				requests: {
					cpu:    "100m"
					memory: "256Mi"
				}
				limits: {
					cpu:    "2000m"
					memory: "2Gi"
				}
			}
		}
	}
	server: {
		isEmbyApi:                    false
		useWebsockets:                true
		rejectSelfSignedCertificates: true
		newWatchEventThresholdHours:  4
	}
	geolite: {
		accountId: {
			$secretName: "jellystat"
			$dataKey:    "geolite-account-id"
			secretName:  "jellystat"
			remoteKey:   "geolite-account-id"
		}
		licenseKey: {
			$secretName: "jellystat"
			$dataKey:    "geolite-license-key"
			secretName:  "jellystat"
			remoteKey:   "geolite-license-key"
		}
	}
	storage: {
		backup: {
			mountPath:    "/app/backend/backup-data"
			type:         "pvc"
			size:         "5Gi"
			storageClass: "local-path"
		}
	}
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
		hostnames: ["jellystat.example.com"]
		gatewayRef: {
			name:      "gateway-gateway"
			namespace: "istio-ingress"
		}
	}
}
