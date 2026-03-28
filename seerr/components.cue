// Components defines the Seerr workload.
// Single stateful component with persistent config volume and health checks.
// Seerr stores all settings in its database (SQLite or PostgreSQL);
// service integrations (Radarr, Sonarr, Jellyfin) are configured via the web UI after deploy.
package seerr

import (
	resources_workload "opmodel.dev/opm/v1alpha1/resources/workload@v1"
	resources_storage "opmodel.dev/opm/v1alpha1/resources/storage@v1"
	traits_workload "opmodel.dev/opm/v1alpha1/traits/workload@v1"
	traits_network "opmodel.dev/opm/v1alpha1/traits/network@v1"
	traits_security "opmodel.dev/opm/v1alpha1/traits/security@v1"
)

// #components contains component definitions.
// Components reference #config which gets resolved to concrete values at build time.
#components: {

	/////////////////////////////////////////////////////////////////
	//// Seerr - Stateful Media Request Manager
	/////////////////////////////////////////////////////////////////

	seerr: {
		resources_workload.#Container
		resources_storage.#Volumes
		traits_workload.#Scaling
		traits_workload.#RestartPolicy
		traits_network.#Expose
		traits_security.#SecurityContext

		// Conditional ingress
		if #config.httpRoute != _|_ {
			traits_network.#HttpRoute
		}

		metadata: name: "seerr"
		metadata: labels: "core.opmodel.dev/workload-type": "stateful"

		_volumes: spec.volumes

		spec: {
			// Single replica — Seerr does not support horizontal scaling
			scaling: count: 1

			restartPolicy: "Always"

			// Run as non-root user (Seerr default: 1000:1000)
			securityContext: {
				runAsUser:  1000
				runAsGroup: 1000
				fsGroup:    1000
			}

			container: {
				name:  "seerr"
				image: #config.image
				ports: http: {
					name:       "http"
					targetPort: #config.port
				}
				env: {
					// Core environment variables
					TZ: {
						name:  "TZ"
						value: #config.timezone
					}
					PORT: {
						name:  "PORT"
						value: "\(#config.port)"
					}

					// Optional log level
					if #config.logLevel != _|_ {
						LOG_LEVEL: {
							name:  "LOG_LEVEL"
							value: #config.logLevel
						}
					}

					// Optional API key from secret
					if #config.apiKey != _|_ {
						API_KEY: {
							name: "API_KEY"
							from: #config.apiKey
						}
					}

					// PostgreSQL database configuration (when postgres is set)
					if #config.postgres != _|_ {
						DB_TYPE: {
							name:  "DB_TYPE"
							value: "postgres"
						}
						DB_HOST: {
							name:  "DB_HOST"
							value: #config.postgres.host
						}
						DB_PORT: {
							name:  "DB_PORT"
							value: "\(#config.postgres.port)"
						}
						DB_USER: {
							name:  "DB_USER"
							value: #config.postgres.user
						}
						DB_PASS: {
							name: "DB_PASS"
							from: #config.postgres.password
						}
						DB_NAME: {
							name:  "DB_NAME"
							value: #config.postgres.name
						}
						if #config.postgres.useSSL {
							DB_USE_SSL: {
								name:  "DB_USE_SSL"
								value: "true"
							}
						}
					}
				}
				livenessProbe: {
					httpGet: {
						path: "/api/v1/status"
						port: #config.port
					}
					initialDelaySeconds: 30
					periodSeconds:       10
					timeoutSeconds:      5
					failureThreshold:    3
				}
				readinessProbe: {
					httpGet: {
						path: "/api/v1/status"
						port: #config.port
					}
					initialDelaySeconds: 10
					periodSeconds:       10
					timeoutSeconds:      3
					failureThreshold:    3
				}
				if #config.resources != _|_ {
					resources: #config.resources
				}
				volumeMounts: {
					config: _volumes.config & {
						mountPath: #config.storage.config.mountPath
					}
				}
			}

			// Expose the web UI
			expose: {
				ports: http: container.ports.http & {
					exposedPort: #config.port
				}
				type: #config.serviceType
			}

			// Optional HTTPRoute
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

			// Config volume — holds SQLite database and settings.json
			volumes: {
				config: {
					name: "config"
					if #config.storage.config.type == "pvc" {
						persistentClaim: {
							size: #config.storage.config.size
							if #config.storage.config.storageClass != _|_ {
								storageClass: #config.storage.config.storageClass
							}
						}
					}
					if #config.storage.config.type == "emptyDir" {
						emptyDir: {}
					}
					if #config.storage.config.type == "nfs" {
						nfs: {
							server: #config.storage.config.server
							path:   #config.storage.config.path
						}
					}
				}
			}
		}
	}
}
