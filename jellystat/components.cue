// Components defines the Jellystat workload.
//
// Three components:
//   - opm-secrets: the module's Secret. Named exactly "opm-secrets" on
//     purpose — the secret transformer renders that component's secrets as
//     {instance}-{secretName}, which is the only shape a container's
//     `env.from` secretKeyRef resolves to. Any other component name would
//     render {instance}-{component}-{secretName} and the env refs would point
//     at an object that does not exist.
//   - jellystat: the app itself, with a backup volume and the web Service.
//   - postgres: the bundled database, rendered only when
//     database.mode == "bundled".
package jellystat

import (
	bp "opmodel.dev/catalogs/opm/blueprints/workload"
	res "opmodel.dev/catalogs/opm/resources"
	tr "opmodel.dev/catalogs/opm/traits"
)

// Jellystat's listener is hardcoded upstream; see #config.servicePort.
_containerPort: 3000

// Hostname the app dials for PostgreSQL. The list-index form is deliberate:
// the obvious `#config.database.host | *bundled.serviceName` spelling means the
// opposite in CUE — a default arm beats a concrete one, so the external host
// would be silently discarded.
_dbHost: [
	if #config.database.mode == "external" {#config.database.host},
	#config.database.bundled.serviceName,
][0]

// Upstream's own healthcheck endpoint, shifted under JS_BASE_URL when set —
// with a base path the app mounts every route beneath it, so the unprefixed
// path would 404 and the probes would kill a healthy pod.
_healthPath: [
	if #config.baseUrl != _|_ {"\(#config.baseUrl)/auth/isConfigured"},
	"/auth/isConfigured",
][0]

// #components contains component definitions.
// Components reference #config which gets resolved to concrete values at build time.
#components: {

	/////////////////////////////////////////////////////////////////
	//// Secrets - JWT key, database password, optional GeoLite creds
	/////////////////////////////////////////////////////////////////

	"opm-secrets": {
		res.#Secrets

		metadata: name: "opm-secrets"

		// #AutoSecrets walks #config, collects every field carrying the $opm
		// discriminator and groups it by $secretName/$dataKey. Entries supplied
		// as #SecretK8sRef are skipped by the transformer, so pointing any of
		// them at a pre-existing cluster Secret emits nothing here.
		spec: secrets: {
			for _secretName, _data in (res.#AutoSecrets & {#in: #config}).out {
				(_secretName): {
					name: _secretName
					data: _data
				}
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Jellystat - Stateful Dashboard
	/////////////////////////////////////////////////////////////////

	jellystat: {
		bp.#StatefulWorkload
		tr.#Expose

		// Conditional ingress
		if #config.httpRoute != _|_ {
			tr.#HttpRoute
		}

		metadata: name: "jellystat"

		_volumes: spec.statefulWorkload.volumes

		spec: {
			statefulWorkload: {
				// Single replica — the app assumes exclusive ownership of its
				// sync jobs and backup directory.
				scaling: count: 1
				restartPolicy: "Always"
				updateStrategy: {
					type: "RollingUpdate"
					rollingUpdate: {}
				}

				// Block startup until PostgreSQL accepts connections. Without
				// it the app crash-loops through backoff on a cold start,
				// because it runs CREATE DATABASE and its migrations before
				// serving anything. Runs in external mode too — an external
				// server can be just as unready at rollout time.
				initContainers: [{
					name: "wait-for-db"
					image: {
						repository: "busybox"
						tag:        "1.37"
						digest:     ""
					}
					command: ["/bin/sh", "-c",
						"until nc -z \(_dbHost) \(#config.database.port); do echo 'waiting for postgres'; sleep 2; done",
					]
				}]

				container: {
					name:  "jellystat"
					image: #config.image
					ports: http: {
						name:       "http"
						targetPort: _containerPort
					}
					env: {
						TZ: {
							name:  "TZ"
							value: #config.timezone
						}
						JS_LISTEN_IP: {
							name:  "JS_LISTEN_IP"
							value: #config.listenIp
						}
						if #config.baseUrl != _|_ {
							JS_BASE_URL: {
								name:  "JS_BASE_URL"
								value: #config.baseUrl
							}
						}

						// Database wiring.
						POSTGRES_IP: {
							name:  "POSTGRES_IP"
							value: _dbHost
						}
						POSTGRES_PORT: {
							name:  "POSTGRES_PORT"
							value: "\(#config.database.port)"
						}
						POSTGRES_DB: {
							name:  "POSTGRES_DB"
							value: #config.database.name
						}
						POSTGRES_USER: {
							name:  "POSTGRES_USER"
							value: #config.database.user
						}
						POSTGRES_PASSWORD: {
							name: "POSTGRES_PASSWORD"
							from: #config.database.password
						}
						POSTGRES_SSL_ENABLED: {
							name:  "POSTGRES_SSL_ENABLED"
							value: "\(#config.database.ssl.enabled)"
						}
						POSTGRES_SSL_REJECT_UNAUTHORIZED: {
							name:  "POSTGRES_SSL_REJECT_UNAUTHORIZED"
							value: "\(#config.database.ssl.rejectUnauthorized)"
						}

						JWT_SECRET: {
							name: "JWT_SECRET"
							from: #config.jwtSecret
						}

						// Media-server behaviour.
						IS_EMBY_API: {
							name:  "IS_EMBY_API"
							value: "\(#config.server.isEmbyApi)"
						}
						JF_USE_WEBSOCKETS: {
							name:  "JF_USE_WEBSOCKETS"
							value: "\(#config.server.useWebsockets)"
						}
						REJECT_SELF_SIGNED_CERTIFICATES: {
							name:  "REJECT_SELF_SIGNED_CERTIFICATES"
							value: "\(#config.server.rejectSelfSignedCertificates)"
						}
						if #config.server.newWatchEventThresholdHours != _|_ {
							NEW_WATCH_EVENT_THRESHOLD_HOURS: {
								name:  "NEW_WATCH_EVENT_THRESHOLD_HOURS"
								value: "\(#config.server.newWatchEventThresholdHours)"
							}
						}

						if #config.geolite != _|_ {
							JS_GEOLITE_ACCOUNT_ID: {
								name: "JS_GEOLITE_ACCOUNT_ID"
								from: #config.geolite.accountId
							}
							JS_GEOLITE_LICENSE_KEY: {
								name: "JS_GEOLITE_LICENSE_KEY"
								from: #config.geolite.licenseKey
							}
						}
					}

					// First start runs CREATE DATABASE plus the full migration
					// chain, so startup is measured in tens of seconds — hence
					// the long initial delay and tolerant failure thresholds.
					livenessProbe: {
						httpGet: {
							path: _healthPath
							port: _containerPort
						}
						initialDelaySeconds: 90
						periodSeconds:       10
						timeoutSeconds:      5
						failureThreshold:    5
					}
					readinessProbe: {
						httpGet: {
							path: _healthPath
							port: _containerPort
						}
						initialDelaySeconds: 30
						periodSeconds:       10
						timeoutSeconds:      5
						failureThreshold:    5
					}
					if #config.resources != _|_ {
						resources: #config.resources
					}
					volumeMounts: backup: _volumes.backup & {
						mountPath: #config.storage.backup.mountPath
					}
				}

				// Backup volume — Jellystat's exported backup files. Everything
				// else lives in PostgreSQL.
				// accessMode/storageClass/readOnly carry no catalog defaults, so
				// every field must be set concretely.
				volumes: backup: {
					name:     "backup"
					readOnly: false
					if #config.storage.backup.type == "pvc" {
						persistentClaim: {
							size:       #config.storage.backup.size
							accessMode: "ReadWriteOnce"
							if #config.storage.backup.storageClass != _|_ {
								storageClass: #config.storage.backup.storageClass
							}
							if #config.storage.backup.storageClass == _|_ {
								storageClass: "standard"
							}
						}
					}
					if #config.storage.backup.type == "emptyDir" {
						emptyDir: {}
					}
					if #config.storage.backup.type == "nfs" {
						nfs: {
							server: #config.storage.backup.server
							path:   #config.storage.backup.path
						}
					}
				}
			}

			// Expose the web UI as a Service.
			expose: {
				ports: http: statefulWorkload.container.ports.http & {
					exposedPort: #config.servicePort
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
								type: "PathPrefix"
								value: [
									if #config.baseUrl != _|_ {#config.baseUrl},
									"/",
								][0]
							}
						}]
						backendPort: #config.servicePort
					}]
					if #config.httpRoute.gatewayRef != _|_ {
						gatewayRef: #config.httpRoute.gatewayRef
					}
				}
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// PostgreSQL - Bundled Database (mode == "bundled")
	/////////////////////////////////////////////////////////////////

	if #config.database.mode == "bundled" {
		postgres: {
			bp.#StatefulWorkload
			tr.#Expose
			tr.#SecurityContext

			metadata: name: "postgres"

			_volumes: spec.statefulWorkload.volumes

			spec: {
				// Run as the image's own postgres user (999) rather than
				// letting the entrypoint start as root and drop privileges.
				// fsGroup makes the fresh PVC group-writable so initdb can
				// create the PGDATA subdirectory under it.
				securityContext: {
					runAsUser:  999
					runAsGroup: 999
					fsGroup:    999
				}

				statefulWorkload: {
					scaling: count: 1
					restartPolicy: "Always"
					// Recreate, not RollingUpdate: two postgres pods must never
					// hold the same PGDATA at once.
					updateStrategy: type: "Recreate"

					container: {
						name:  "postgres"
						image: #config.database.bundled.image
						ports: postgres: {
							name:       "postgres"
							targetPort: 5432
						}
						env: {
							POSTGRES_USER: {
								name:  "POSTGRES_USER"
								value: #config.database.user
							}
							POSTGRES_PASSWORD: {
								name: "POSTGRES_PASSWORD"
								from: #config.database.password
							}
							// POSTGRES_DB is deliberately NOT set. The official
							// image then creates a database named after
							// POSTGRES_USER, which is the database Jellystat's
							// bootstrap connects to before it can issue
							// `CREATE DATABASE jfstat`. Setting it here would
							// break first start. Upstream's compose omits it
							// for the same reason.
							TZ: {
								name:  "TZ"
								value: #config.timezone
							}
						}
						livenessProbe: {
							exec: command: ["pg_isready", "-U", #config.database.user]
							initialDelaySeconds: 30
							periodSeconds:       10
							timeoutSeconds:      5
							failureThreshold:    6
						}
						readinessProbe: {
							exec: command: ["pg_isready", "-U", #config.database.user]
							initialDelaySeconds: 10
							periodSeconds:       10
							timeoutSeconds:      5
							failureThreshold:    6
						}
						if #config.database.bundled.resources != _|_ {
							resources: #config.database.bundled.resources
						}
						volumeMounts: data: _volumes.data & {
							mountPath: #config.database.bundled.storage.mountPath
						}
					}

					volumes: data: {
						name:     "data"
						readOnly: false
						if #config.database.bundled.storage.type == "pvc" {
							persistentClaim: {
								size:       #config.database.bundled.storage.size
								accessMode: "ReadWriteOnce"
								if #config.database.bundled.storage.storageClass != _|_ {
									storageClass: #config.database.bundled.storage.storageClass
								}
								if #config.database.bundled.storage.storageClass == _|_ {
									storageClass: "standard"
								}
							}
						}
						if #config.database.bundled.storage.type == "emptyDir" {
							emptyDir: {}
						}
						if #config.database.bundled.storage.type == "nfs" {
							nfs: {
								server: #config.database.bundled.storage.server
								path:   #config.database.bundled.storage.path
							}
						}
					}
				}

				// Exact Service name — this is the hostname the app is
				// configured with, and a module cannot compute its own
				// instance prefix at build time. Also becomes the
				// StatefulSet's governing serviceName.
				expose: {
					name: #config.database.bundled.serviceName
					ports: postgres: statefulWorkload.container.ports.postgres & {
						exposedPort: #config.database.port
					}
					type: "ClusterIP"
				}
			}
		}
	}
}
