// Components defines the Seerr workload.
// Single stateful component with a persistent config volume, a web Service,
// health checks, and an optional Gateway HTTPRoute. Seerr stores all settings
// in a SQLite database on the config volume.
package seerr

import (
	bp "opmodel.dev/catalogs/opm/blueprints/workload"
	tr "opmodel.dev/catalogs/opm/traits"
)

// #components contains component definitions.
// Components reference #config which gets resolved to concrete values at build time.
#components: {

	/////////////////////////////////////////////////////////////////
	//// Seerr - Stateful Media Request Manager
	/////////////////////////////////////////////////////////////////

	seerr: {
		bp.#StatefulWorkload
		tr.#Expose
		tr.#SecurityContext

		// Conditional ingress
		if #config.httpRoute != _|_ {
			tr.#HttpRoute
		}

		metadata: name: "seerr"

		_volumes: spec.statefulWorkload.volumes

		spec: {
			// fsGroup ensures volume files are group-accessible by Seerr (UID 1000).
			// runAsUser/runAsGroup are intentionally omitted so the init container
			// can run as root for chown; the Seerr image runs as UID 1000 internally.
			securityContext: {
				fsGroup: 1000
			}

			statefulWorkload: {
				// Single replica — Seerr does not support horizontal scaling.
				scaling: count: 1
				restartPolicy: "Always"
				updateStrategy: {
					type:          "RollingUpdate"
					rollingUpdate: {}
				}

				// Fix ownership on every start so /app/config is writable by UID 1000.
				initContainers: [{
					name: "fix-permissions"
					image: {
						repository: "busybox"
						tag:        "1.37"
						digest:     ""
					}
					command: ["/bin/sh", "-c", "chown -R 1000:1000 \(#config.storage.config.mountPath)"]
					volumeMounts: config: _volumes.config & {
						mountPath: #config.storage.config.mountPath
					}
				}]

				container: {
					name:  "seerr"
					image: #config.image
					ports: http: {
						name:       "http"
						targetPort: #config.port
					}
					env: {
						TZ: {
							name:  "TZ"
							value: #config.timezone
						}
						PORT: {
							name:  "PORT"
							value: "\(#config.port)"
						}
						if #config.logLevel != _|_ {
							LOG_LEVEL: {
								name:  "LOG_LEVEL"
								value: #config.logLevel
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
					volumeMounts: config: _volumes.config & {
						mountPath: #config.storage.config.mountPath
					}
				}

				// Config volume — holds SQLite database and settings.json.
				// accessMode/storageClass/readOnly carry no catalog defaults, so
				// every field must be set concretely.
				volumes: config: {
					name:     "config"
					readOnly: false
					if #config.storage.config.type == "pvc" {
						persistentClaim: {
							size:       #config.storage.config.size
							accessMode: "ReadWriteOnce"
							if #config.storage.config.storageClass != _|_ {
								storageClass: #config.storage.config.storageClass
							}
							if #config.storage.config.storageClass == _|_ {
								storageClass: "standard"
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

			// Expose the web UI as a Service.
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
