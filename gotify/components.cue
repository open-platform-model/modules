// Components defines the Gotify workload.
// Single stateful component: configuration is entirely GOTIFY_* environment
// variables (no ConfigMap — Gotify reads env for every option), one PVC holds
// the SQLite database, uploaded images and plugins, the web Service fronts
// both the REST API and the WebSocket stream, and an optional HTTPRoute
// provides ingress.
package gotify

import (
	bp "opmodel.dev/catalogs/opm/blueprints/workload"
	tr "opmodel.dev/catalogs/opm/traits"
)

// #components contains component definitions.
// Components reference #config which gets resolved to concrete values at build time.
#components: {

	/////////////////////////////////////////////////////////////////
	//// Gotify - Stateful Push Notification Server
	/////////////////////////////////////////////////////////////////

	gotify: {
		bp.#StatefulWorkload
		tr.#Expose

		// Conditional ingress
		if #config.httpRoute != _|_ {
			tr.#HttpRoute
		}

		metadata: name: "gotify"

		_volumes: spec.statefulWorkload.volumes

		// Every persistent path derives from the single data mount. Gotify's
		// own defaults are relative to its /app working directory; writing
		// them absolutely keeps the database, images and plugins together
		// wherever the volume is mounted.
		_dataDir: #config.storage.data.mountPath

		spec: {
			statefulWorkload: {
				// Single replica — the default SQLite database sits on a
				// ReadWriteOnce volume and must not be opened twice.
				scaling: count: 1
				restartPolicy: "Always"
				// Recreate, not RollingUpdate: the old pod must release the
				// SQLite file and the RWO volume before the new one starts.
				updateStrategy: type: "Recreate"

				container: {
					name:  "gotify"
					image: #config.image

					// The image's entrypoint already carries `serve` as its
					// CMD, so no args override is needed here.

					ports: http: {
						name:       "http"
						targetPort: #config.listenPort
					}

					env: {
						TZ: {
							name:  "TZ"
							value: #config.timezone
						}
						GOTIFY_SERVER_PORT: {
							name:  "GOTIFY_SERVER_PORT"
							value: "\(#config.listenPort)"
						}
						GOTIFY_LOGLEVEL: {
							name:  "GOTIFY_LOGLEVEL"
							value: #config.logLevel
						}
						GOTIFY_SERVER_SECURECOOKIE: {
							name:  "GOTIFY_SERVER_SECURECOOKIE"
							value: "\(#config.secureCookie)"
						}
						GOTIFY_SERVER_STREAM_PINGPERIODSECONDS: {
							name:  "GOTIFY_SERVER_STREAM_PINGPERIODSECONDS"
							value: "\(#config.streamPingPeriodSeconds)"
						}
						GOTIFY_REGISTRATION: {
							name:  "GOTIFY_REGISTRATION"
							value: "\(#config.registration)"
						}
						GOTIFY_PASSSTRENGTH: {
							name:  "GOTIFY_PASSSTRENGTH"
							value: "\(#config.passStrength)"
						}

						// Bootstrap admin. Only consulted when the database is
						// created; on an existing volume these are inert.
						GOTIFY_DEFAULTUSER_NAME: {
							name:  "GOTIFY_DEFAULTUSER_NAME"
							value: #config.defaultUser.name
						}
						GOTIFY_DEFAULTUSER_PASS: {
							name: "GOTIFY_DEFAULTUSER_PASS"
							from: #config.defaultUser.password
						}

						// Storage paths, written absolutely so they follow the
						// volume rather than Gotify's /app-relative defaults.
						GOTIFY_UPLOADEDIMAGESDIR: {
							name:  "GOTIFY_UPLOADEDIMAGESDIR"
							value: "\(_dataDir)/images"
						}
						GOTIFY_PLUGINSDIR: {
							name:  "GOTIFY_PLUGINSDIR"
							value: "\(_dataDir)/plugins"
						}

						GOTIFY_DATABASE_DIALECT: {
							name:  "GOTIFY_DATABASE_DIALECT"
							value: #config.database.dialect
						}
						// SQLite: a plain path on the data volume. External
						// dialects: a DSN carrying credentials, so it arrives
						// from a Secret instead.
						if #config.database.dialect == "sqlite3" {
							GOTIFY_DATABASE_CONNECTION: {
								name:  "GOTIFY_DATABASE_CONNECTION"
								value: "\(_dataDir)/gotify.db"
							}
						}
						if #config.database.dialect != "sqlite3" {
							GOTIFY_DATABASE_CONNECTION: {
								name: "GOTIFY_DATABASE_CONNECTION"
								from: #config.database.connection
							}
						}

						// Escape hatch — OIDC, CORS, trusted proxies, and any
						// other GOTIFY_* option this schema does not model.
						if #config.extraEnv != _|_ {
							for k, v in #config.extraEnv {
								(k): {
									name:  k
									value: v
								}
							}
						}
					}

					// Public and unauthenticated, and it returns 500 when the
					// database handle is unhealthy — so it fails the pod for
					// the right reason rather than only checking that the HTTP
					// listener is up.
					livenessProbe: {
						httpGet: {
							path: "/health"
							port: #config.listenPort
						}
						initialDelaySeconds: 10
						periodSeconds:       10
						timeoutSeconds:      5
						failureThreshold:    3
					}
					readinessProbe: {
						httpGet: {
							path: "/health"
							port: #config.listenPort
						}
						initialDelaySeconds: 5
						periodSeconds:       10
						timeoutSeconds:      5
						failureThreshold:    3
					}

					if #config.resources != _|_ {
						resources: #config.resources
					}

					volumeMounts: data: _volumes.data & {
						mountPath: _dataDir
					}
				}

				// Data volume — SQLite database, uploaded application images,
				// and plugins. accessMode/storageClass/readOnly carry no
				// catalog defaults, so every field must be set concretely.
				volumes: data: {
					name:     "data"
					readOnly: false
					if #config.storage.data.type == "pvc" {
						persistentClaim: {
							size:       #config.storage.data.size
							accessMode: "ReadWriteOnce"
							if #config.storage.data.storageClass != _|_ {
								storageClass: #config.storage.data.storageClass
							}
							if #config.storage.data.storageClass == _|_ {
								storageClass: "standard"
							}
						}
					}
					if #config.storage.data.type == "emptyDir" {
						emptyDir: {}
					}
					if #config.storage.data.type == "nfs" {
						nfs: {
							server: #config.storage.data.server
							path:   #config.storage.data.path
						}
					}
				}
			}

			// Expose the REST API and the WebSocket stream as a Service.
			expose: {
				ports: http: statefulWorkload.container.ports.http & {
					exposedPort: #config.port
				}
				type: #config.serviceType
			}

			// Optional HTTPRoute.
			if #config.httpRoute != _|_ {
				httpRoute: {
					hostnames: #config.httpRoute.hostnames
					rules: [{
						matches: [{
							path: {
								type:  "PathPrefix"
								value: "/"
							}
						}]
						backendPort: #config.port
					}]
					if #config.httpRoute.gatewayRef != _|_ {
						gatewayRef: #config.httpRoute.gatewayRef
					}
				}
			}
		}
	}
}
