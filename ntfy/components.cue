// Components defines the ntfy workload.
// Single stateful component: server.yml is rendered from #config into a
// ConfigMap and subPath-mounted read-only at /etc/ntfy/server.yml, one PVC
// holds the message cache, the auth database and attachments, the web
// Service fronts both the HTTP API and the web app, and an optional
// HTTPRoute provides ingress. Env vars carry only credential material — the
// provisioned users and tokens — so none of it lands in the ConfigMap.
package ntfy

import (
	"encoding/yaml"
	"list"

	bp "opmodel.dev/catalogs/opm/blueprints/workload"
	res "opmodel.dev/catalogs/opm/resources"
	tr "opmodel.dev/catalogs/opm/traits"
)

// #components contains component definitions.
// Components reference #config which gets resolved to concrete values at build time.
#components: {

	/////////////////////////////////////////////////////////////////
	//// ntfy - Stateful Push Notification Server
	/////////////////////////////////////////////////////////////////

	ntfy: {
		bp.#StatefulWorkload
		tr.#Expose
		res.#ConfigMaps

		// Conditional ingress
		if #config.httpRoute != _|_ {
			tr.#HttpRoute
		}

		metadata: name: "ntfy"

		_volumes: spec.statefulWorkload.volumes

		// Every persistent path derives from the single data mount, so moving
		// the mountPath moves the cache, the auth database and attachments
		// together rather than stranding one of them on the container's
		// ephemeral filesystem.
		_dataDir: #config.storage.data.mountPath

		// ACL rows, flattened to ntfy's "<user>:<topic>:<permission>" wire
		// form. The UnifiedPush grant is appended rather than merged into
		// #config.auth.access so enabling it never silently rewrites an
		// operator-authored entry.
		_accessEntries: [
			for e in #config.auth.access {"\(e.user):\(e.topic):\(e.permission)"},
		]
		_upEntries: [
			if #config.unifiedPush {"*:up*:wo"},
		]
		_allAccess: list.Concat([_accessEntries, _upEntries])

		// The complete server.yml. Dashed keys are ntfy's own option names.
		// auth-users and auth-tokens are deliberately absent — they arrive
		// via NTFY_AUTH_USERS / NTFY_AUTH_TOKENS (env overrides file in
		// ntfy's config stack), keeping bcrypt hashes and tokens out of a
		// ConfigMap.
		_serverYml: {
			"base-url":     #config.baseUrl
			"listen-http":  ":\(#config.listenPort)"
			"behind-proxy": #config.behindProxy

			// Message cache and auth database, both SQLite, both on the PVC.
			// Without cache-file ntfy keeps messages in memory only and a pod
			// restart loses every message a phone had not yet picked up.
			"cache-file":     "\(_dataDir)/cache.db"
			"cache-duration": #config.cache.duration

			// Setting auth-file is what enables authentication at all.
			"auth-file":           "\(_dataDir)/user.db"
			"auth-default-access": #config.auth.defaultAccess

			"enable-signup": #config.enableSignup
			"enable-login":  #config.enableLogin

			if len(_allAccess) > 0 {
				"auth-access": _allAccess
			}

			// An unset attachment-cache-dir is what disables attachments, so
			// the whole block is written together or not at all.
			if #config.attachments != _|_ {
				"attachment-cache-dir":        "\(_dataDir)/attachments"
				"attachment-total-size-limit": #config.attachments.totalSizeLimit
				"attachment-file-size-limit":  #config.attachments.fileSizeLimit
				"attachment-expiry-duration":  #config.attachments.expiryDuration
			}

			if #config.upstreamBaseUrl != _|_ {
				"upstream-base-url": #config.upstreamBaseUrl
			}

			if #config.webRoot != _|_ {
				"web-root": #config.webRoot
			}
		}

		spec: {
			statefulWorkload: {
				// Single replica — two pods would write the same SQLite cache
				// and auth databases on one ReadWriteOnce volume.
				scaling: count: 1
				restartPolicy: "Always"
				// Recreate, not RollingUpdate: the old pod must release the
				// SQLite files and the RWO volume before the new one starts.
				updateStrategy: type: "Recreate"

				container: {
					name:  "ntfy"
					image: #config.image

					// REQUIRED. The image's entrypoint is the bare `ntfy`
					// binary with no CMD, so without an explicit subcommand
					// the container prints usage and exits 1.
					args: ["serve"]

					ports: http: {
						name:       "http"
						targetPort: #config.listenPort
					}

					env: {
						TZ: {
							name:  "TZ"
							value: #config.timezone
						}
						// Provisioned users. Env wins over the config file,
						// and this is the only place credential material is
						// allowed to travel.
						NTFY_AUTH_USERS: {
							name: "NTFY_AUTH_USERS"
							from: #config.auth.users
						}
						if #config.auth.tokens != _|_ {
							NTFY_AUTH_TOKENS: {
								name: "NTFY_AUTH_TOKENS"
								from: #config.auth.tokens
							}
						}
					}

					// Answered by the server itself with no auth required, so
					// probes stay green regardless of the ACL configuration.
					// A Go binary plus SQLite migrations starts in seconds.
					livenessProbe: {
						httpGet: {
							path: "/v1/health"
							port: #config.listenPort
						}
						initialDelaySeconds: 10
						periodSeconds:       10
						timeoutSeconds:      5
						failureThreshold:    3
					}
					readinessProbe: {
						httpGet: {
							path: "/v1/health"
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

					volumeMounts: {
						data: _volumes.data & {
							mountPath: _dataDir
						}
						// The rendered config, mounted as a single file at the
						// path ntfy reads by default. Built fresh rather than
						// unified from _volumes so readOnly can be true
						// without conflicting with the volume's readOnly:
						// false. Read-only is safe here: unlike the media
						// apps, ntfy never rewrites its own server.yml.
						"ntfy-config": {
							name:      "ntfy-config"
							configMap: spec.configMaps["ntfy-config"]
							mountPath: "/etc/ntfy/server.yml"
							subPath:   "server.yml"
							readOnly:  true
						}
					}
				}

				// Data volume — cache.db, user.db, and attachments.
				// accessMode/storageClass/readOnly carry no catalog defaults,
				// so every field must be set concretely.
				volumes: {
					data: {
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

					"ntfy-config": {
						name:      "ntfy-config"
						readOnly:  false
						configMap: spec.configMaps["ntfy-config"]
					}
				}
			}

			// The rendered server config. Mutable: a config change lands in
			// the live ConfigMap, but subPath mounts never update in-place and
			// ntfy only reads the file at startup — roll the pod
			// (kubectl rollout restart) to apply changes.
			configMaps: {
				"ntfy-config": {
					immutable: false
					data: {
						"server.yml": "\(yaml.Marshal(_serverYml))"
					}
				}
			}

			// Expose the HTTP API and web app as a Service.
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
