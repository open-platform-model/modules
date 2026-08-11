// Components defines the Seerr workload.
// Single stateful component with a persistent config volume, a web Service,
// health checks, and an optional Gateway HTTPRoute. Seerr stores all settings
// in a SQLite database on the config volume.
package seerr

import (
	bp "opmodel.dev/catalogs/opm/blueprints/v1beta1"
	tr "opmodel.dev/catalogs/opm/traits/v1beta1"
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

		// Conditional struct-valued spec fields, HOISTED to component level
		// rather than guarded inside the spec block — the in-spec form trips
		// the CUE v0.17 closedness regression on the v2 catalog's closed
		// blueprint spec (catalog CLAUDE.md authoring pitfall; see
		// docs/cue-guard-closedness-workaround.md there). Do not inline these.
		if #config.logLevel != _|_ {
			spec: statefulWorkload: container: env: LOG_LEVEL: {
				name:  "LOG_LEVEL"
				value: #config.logLevel
			}
		}
		if #config.resources != _|_ {
			spec: statefulWorkload: container: resources: #config.resources
		}
		if #config.httpRoute != _|_ {
			spec: httpRoute: {
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
			}
		}
		if #config.httpRoute != _|_ if #config.httpRoute.gatewayRef != _|_ {
			spec: httpRoute: gatewayRef: #config.httpRoute.gatewayRef
		}

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
					type: "RollingUpdate"
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
						// LOG_LEVEL is conditionally set from component level — see
						// the hoisted guards above the spec block.
					}
					// Seerr's /api/v1/status handler blocks on an upstream
					// api.github.com version check; when the cluster has no egress
					// to GitHub that lookup stalls ~5s, so the probes are tolerant
					// (10s timeout, 5 failures) to avoid killing a healthy app.
					livenessProbe: {
						httpGet: {
							path: "/api/v1/status"
							port: #config.port
						}
						initialDelaySeconds: 60
						periodSeconds:       10
						timeoutSeconds:      10
						failureThreshold:    5
					}
					readinessProbe: {
						httpGet: {
							path: "/api/v1/status"
							port: #config.port
						}
						initialDelaySeconds: 30
						periodSeconds:       10
						timeoutSeconds:      10
						failureThreshold:    5
					}
					// resources is conditionally set from component level — see
					// the hoisted guards above the spec block.
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

			// The optional HTTPRoute is written from the hoisted guards above
			// the spec block.
		}
	}
}
