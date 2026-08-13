// Components defines the Apprise API workload.
// Single stateless component: the config Secret is projected read-only into
// /config, one file per Apprise {KEY}, and everything else is APPRISE_*
// environment. No PVC and no ConfigMap — a config file is credential-bearing
// (so it must be a Secret) and nothing else the server writes is worth
// keeping across a restart.
package apprise

import (
	bp "opmodel.dev/catalogs/opm/blueprints/v1beta1"
	res "opmodel.dev/catalogs/opm/resources/v1beta1"
	tr "opmodel.dev/catalogs/opm/traits/v1beta1"
)

// #components contains component definitions.
// Components reference #config which gets resolved to concrete values at build time.
#components: {

	/////////////////////////////////////////////////////////////////
	//// Apprise API - Stateless Notification Router
	/////////////////////////////////////////////////////////////////

	apprise: {
		bp.#StatelessWorkload
		tr.#Expose

		// The config Secret is only mounted in stateful mode; stateless
		// deployments carry no volumes at all.
		if #config.mode == "stateful" {
			res.#Volumes
		}

		// Conditional ingress
		if #config.httpRoute != _|_ {
			tr.#HttpRoute
		}

		metadata: name: "apprise"

		// Apprise reads yes/no, not true/false. Indexing a lookup table by
		// the interpolated bool keeps that conversion in one place.
		_yesNo: {
			"true":  "yes"
			"false": "no"
		}

		// A config {KEY} is the file "<KEY>.yml" (YAML) or "<KEY>.cfg"
		// (TEXT) — the extension is what tells Apprise how to parse it, so
		// it is derived from configFormat rather than assumed.
		_ext: {
			yaml: "yml"
			text: "cfg"
		}[#config.configFormat]

		// The image declares /config as a volume and defaults
		// APPRISE_CONFIG_DIR to it.
		_configDir: "/config"

		// Conditional struct-valued spec fields, HOISTED to component level
		// rather than guarded inside the spec block — the in-spec form trips
		// the CUE v0.17 closedness regression on the v2 catalog's closed
		// blueprint spec (catalog CLAUDE.md authoring pitfall; see
		// docs/cue-guard-closedness-workaround.md there). Do not inline these.
		//
		// Upstream ignores the deny list whenever an allow list is present, so
		// only one of the two is ever emitted — writing both would imply they
		// compose.
		if #config.allowServices != _|_ {
			spec: statelessWorkload: container: env: APPRISE_ALLOW_SERVICES: {
				name:  "APPRISE_ALLOW_SERVICES"
				value: #config.allowServices
			}
		}
		if #config.allowServices == _|_ {
			spec: statelessWorkload: container: env: APPRISE_DENY_SERVICES: {
				name:  "APPRISE_DENY_SERVICES"
				value: #config.denyServices
			}
		}
		if #config.baseUrl != _|_ {
			spec: statelessWorkload: container: env: APPRISE_BASE_URL: {
				name:  "APPRISE_BASE_URL"
				value: #config.baseUrl
			}
		}
		if #config.webhookUrl != _|_ {
			spec: statelessWorkload: container: env: APPRISE_WEBHOOK_URL: {
				name:  "APPRISE_WEBHOOK_URL"
				value: #config.webhookUrl
			}
		}

		// Credential-bearing, so it arrives from a Secret rather than the
		// manifest.
		if #config.mode == "stateless" if #config.statelessUrls != _|_ {
			spec: statelessWorkload: container: env: APPRISE_STATELESS_URLS: {
				name: "APPRISE_STATELESS_URLS"
				from: #config.statelessUrls
			}
		}
		if #config.resources != _|_ {
			spec: statelessWorkload: container: resources: #config.resources
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
			statelessWorkload: {
				// Safe to scale: every replica mounts the same read-only
				// config Secret and holds no local state.
				scaling: count: #config.replicas
				restartPolicy: "Always"
				updateStrategy: {
					type: "RollingUpdate"
					rollingUpdate: {}
				}

				container: {
					name:  "apprise"
					image: #config.image

					// No args — the image's CMD already starts supervisord,
					// which runs nginx and gunicorn together.

					ports: http: {
						name:       "http"
						targetPort: #config.listenPort
					}

					env: {
						// APPRISE_ALLOW_SERVICES / APPRISE_DENY_SERVICES,
						// APPRISE_BASE_URL, APPRISE_WEBHOOK_URL and
						// APPRISE_STATELESS_URLS are conditionally set from
						// component level — see the hoisted guards above the
						// spec block.
						TZ: {
							name:  "TZ"
							value: #config.timezone
						}
						// The container starts as root and drops to these.
						PUID: {
							name:  "PUID"
							value: "\(#config.puid)"
						}
						PGID: {
							name:  "PGID"
							value: "\(#config.pgid)"
						}
						HTTP_PORT: {
							name:  "HTTP_PORT"
							value: "\(#config.listenPort)"
						}
						LOG_LEVEL: {
							name:  "LOG_LEVEL"
							value: #config.logLevel
						}
						STRICT_MODE: {
							name:  "STRICT_MODE"
							value: _yesNo["\(#config.strictMode)"]
						}

						// "simple" maps a {KEY} straight to a file in the
						// config directory, which is what lets a mounted
						// Secret BE the configuration. "disabled" turns the
						// stateful store off for stateless deployments.
						APPRISE_STATEFUL_MODE: {
							name: "APPRISE_STATEFUL_MODE"
							if #config.mode == "stateful" {
								value: "simple"
							}
							if #config.mode == "stateless" {
								value: "disabled"
							}
						}
						// Blocks the API from mutating the store. Also what
						// keeps GET /status at 200 despite an unwritable
						// config directory (verified on v1.5.1).
						APPRISE_CONFIG_LOCK: {
							name:  "APPRISE_CONFIG_LOCK"
							value: _yesNo["\(#config.configLock)"]
						}
						// The persistent store would default to
						// <config>/store, which is inside the read-only
						// Secret mount. Memory mode keeps Apprise off disk
						// entirely; the store is only a URL cache.
						APPRISE_STORAGE_MODE: {
							name:  "APPRISE_STORAGE_MODE"
							value: "memory"
						}
						APPRISE_DEFAULT_CONFIG_ID: {
							name:  "APPRISE_DEFAULT_CONFIG_ID"
							value: #config.defaultConfigId
						}
						APPRISE_ADMIN: {
							name:  "APPRISE_ADMIN"
							value: _yesNo["\(#config.admin)"]
						}
						APPRISE_API_ONLY: {
							name:  "APPRISE_API_ONLY"
							value: _yesNo["\(#config.apiOnly)"]
						}
						APPRISE_RECURSION_MAX: {
							name:  "APPRISE_RECURSION_MAX"
							value: "\(#config.recursionMax)"
						}
						APPRISE_WORKER_COUNT: {
							name:  "APPRISE_WORKER_COUNT"
							value: "\(#config.workers.count)"
						}
						APPRISE_WORKER_TIMEOUT: {
							name:  "APPRISE_WORKER_TIMEOUT"
							value: "\(#config.workers.timeoutSeconds)"
						}

						// Zero makes the server drop attachments even when a
						// caller supplies one.
						APPRISE_ATTACH_SIZE: {
							name: "APPRISE_ATTACH_SIZE"
							if #config.attachments.enabled {
								value: "\(#config.attachments.maxSizeMb)"
							}
							if #config.attachments.enabled == false {
								value: "0"
							}
						}
					}

					// 200 when healthy, 417 when Apprise cannot write where
					// it needs to. Verified on v1.5.1 that a read-only
					// config directory plus configLock still reports 200
					// with details ["OK"] — the probe fails for real
					// problems, not for the mount being read-only.
					livenessProbe: {
						httpGet: {
							path: "/status"
							port: #config.listenPort
						}
						initialDelaySeconds: 15
						periodSeconds:       10
						timeoutSeconds:      5
						failureThreshold:    3
					}
					readinessProbe: {
						httpGet: {
							path: "/status"
							port: #config.listenPort
						}
						initialDelaySeconds: 10
						periodSeconds:       10
						timeoutSeconds:      5
						failureThreshold:    3
					}

					// resources is conditionally set from component level — see
					// the hoisted guards above the spec block.

					if #config.mode == "stateful" {
						volumeMounts: config: spec.volumes.config & {
							mountPath: _configDir
						}
					}
				}
			}

			// The config Secret, projected one file per Apprise {KEY}.
			// secretRef (not secret) because the Secret is provisioned out
			// of band — SOPS-managed — and must be addressed by its exact
			// cluster name rather than an instance-scoped one.
			if #config.mode == "stateful" {
				volumes: config: {
					name:     "config"
					readOnly: true
					secretRef: {
						name: #config.configSecret.name
						items: [
							for k in #config.configSecret.keys {
								key:  k
								path: "\(k).\(_ext)"
							},
						]
						defaultMode: 420
					}
				}
			}

			// Expose the API (and the web UI unless apiOnly) as a Service.
			expose: {
				ports: http: statelessWorkload.container.ports.http & {
					exposedPort: #config.port
				}
				type: #config.serviceType
			}

			// The optional HTTPRoute is written from the hoisted guards above
			// the spec block.
		}
	}
}
