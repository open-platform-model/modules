// Components defines the Jellyswarrm workload.
// Single stateful component: the full application config is rendered from
// #config into a TOML ConfigMap and subPath-mounted read-only over
// <data>/jellyswarrm.toml, a PVC holds the SQLite database, the web Service
// fronts the Jellyfin-compatible API, and an optional HTTPRoute provides
// ingress. Env vars carry only what the TOML must not (the admin password)
// and what guards against kubelet noise (the port pin).
package jellyswarrm

import (
	"encoding/toml"

	bp "opmodel.dev/catalogs/opm/blueprints/v1beta1"
	res "opmodel.dev/catalogs/opm/resources/v1beta1"
	tr "opmodel.dev/catalogs/opm/traits/v1beta1"
)

// #components contains component definitions.
// Components reference #config which gets resolved to concrete values at build time.
#components: {

	/////////////////////////////////////////////////////////////////
	//// Jellyswarrm - Stateful Jellyfin Aggregation Proxy
	/////////////////////////////////////////////////////////////////

	jellyswarrm: {
		bp.#StatefulWorkload
		tr.#Expose
		res.#ConfigMaps

		// Conditional ingress
		if #config.httpRoute != _|_ {
			tr.#HttpRoute
		}

		metadata: name: "jellyswarrm"

		_volumes: spec.statefulWorkload.volumes

		// Probe path, prefix-aware: url_prefix moves EVERY route under the
		// prefix (verified on 0.3.0 — the listener logs
		// "Starting reverse proxy on http://0.0.0.0:3000/<prefix>"), so an
		// unprefixed probe would 404 a healthy pod into a restart loop.
		_probePath: string
		if #config.urlPrefix != _|_ {
			_probePath: "/\(#config.urlPrefix)\(#config.healthPath)"
		}
		if #config.urlPrefix == _|_ {
			_probePath: #config.healthPath
		}

		// The complete jellyswarrm.toml, built here and marshalled below.
		// snake_case keys are the app's serde field names. The password is
		// deliberately absent — it arrives via the JELLYSWARRM_PASSWORD env
		// var (env overrides file in the app's config stack), so no secret
		// material lands in the ConfigMap. session_key is also absent and
		// therefore regenerates on every start: management-UI sessions reset
		// on pod restart. Accepted — the alternative is secret material in a
		// ConfigMap, since the env override for it is broken upstream.
		_tomlConfig: {
			server_id:      #config.serverId
			public_address: #config.publicAddress
			server_name:    #config.serverName
			// The app's listen port is pinned to 3000 by design — see the
			// schema comment on #config.port.
			port:                                  3000
			include_server_name_in_media:          #config.includeServerNameInMedia
			username:                              #config.username
			timeout:                               #config.timeout
			media_streaming_mode:                  #config.mediaStreamingMode
			server_background_check_interval_secs: #config.serverBackgroundCheckIntervalSecs
			auto_create_users_on_login:            #config.autoCreateUsersOnLogin
			merge_libraries:                       #config.mergeLibraries
			if #config.uiRoute != _|_ {
				ui_route: #config.uiRoute
			}
			if #config.urlPrefix != _|_ {
				url_prefix: #config.urlPrefix
			}

			// Rendered as [[preconfigured_servers]] array-of-tables; the app
			// upserts these into SQLite (keyed by URL) on every start.
			// The loop binding is serverName, not name — `name: name` would
			// be a self-reference in CUE, never the loop variable.
			preconfigured_servers: [
				for serverName, s in #config.servers {
					name:                 serverName
					url:                  s.url
					priority:             s.priority
					media_streaming_mode: s.mediaStreamingMode
				},
			]
		}

		// Conditional struct-valued spec fields, HOISTED to component level
		// rather than guarded inside the spec block — the in-spec form trips
		// the CUE v0.17 closedness regression on the v2 catalog's closed
		// blueprint spec (catalog CLAUDE.md authoring pitfall; see
		// docs/cue-guard-closedness-workaround.md there). Do not inline these.
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
			statefulWorkload: {
				// Single replica — SQLite database, must not scale out.
				scaling: count: 1
				restartPolicy: "Always"
				updateStrategy: {
					type: "RollingUpdate"
					rollingUpdate: {}
				}

				container: {
					name:  "jellyswarrm"
					image: #config.image
					ports: http: {
						name: "http"
						// Literal 3000, not #config.port: that field is the
						// SERVICE port (see exposedPort below); the container
						// always listens on 3000.
						targetPort: 3000
					}
					env: {
						// One of the few env vars the app parses correctly
						// (single word). Overrides the TOML, keeping the
						// built-in default password unreachable.
						JELLYSWARRM_PASSWORD: {
							name: "JELLYSWARRM_PASSWORD"
							from: #config.password
						}
						// Pin against kubelet service links: the Service named
						// "jellyswarrm" injects JELLYSWARRM_PORT=tcp://... into
						// the pod, and explicit container env wins over those.
						JELLYSWARRM_PORT: {
							name:  "JELLYSWARRM_PORT"
							value: "3000"
						}
						// Read directly via std::env (not the fragile config
						// stack), so it works regardless of word count. Keeps
						// config + database on the mounted volume even when
						// the instance moves mountPath.
						JELLYSWARRM_DATA_DIR: {
							name:  "JELLYSWARRM_DATA_DIR"
							value: #config.storage.data.mountPath
						}
					}
					// Answered locally by the proxy (verified on 0.3.0: 200
					// with no backends and no auth), so probe health never
					// depends on upstream Jellyfin servers. Startup is fast —
					// a Rust binary plus SQLite migrations.
					livenessProbe: {
						httpGet: {
							path: _probePath
							port: 3000
						}
						initialDelaySeconds: 10
						periodSeconds:       10
						timeoutSeconds:      5
						failureThreshold:    3
					}
					readinessProbe: {
						httpGet: {
							path: _probePath
							port: 3000
						}
						initialDelaySeconds: 5
						periodSeconds:       10
						timeoutSeconds:      5
						failureThreshold:    3
					}
					// resources is conditionally set from component level — see
					// the hoisted guards above the spec block.
					volumeMounts: {
						data: _volumes.data & {
							mountPath: #config.storage.data.mountPath
						}
						// The rendered config, mounted as a single file OVER
						// the data volume's jellyswarrm.toml path. Built fresh
						// (not unified from _volumes) so readOnly can be true
						// without conflicting with the volume's readOnly:
						// false. Read-only is load-bearing: the app rewrites
						// its config file from the management UI (settings and
						// library-merge saves), and those writes must fail
						// rather than diverge from CUE — config is CUE-owned.
						"jellyswarrm-config": {
							name:      "jellyswarrm-config"
							configMap: spec.configMaps["jellyswarrm-config"]
							mountPath: "\(#config.storage.data.mountPath)/jellyswarrm.toml"
							subPath:   "jellyswarrm.toml"
							readOnly:  true
						}
					}
				}

				// Data volume — SQLite database and WAL files.
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

					"jellyswarrm-config": {
						name:      "jellyswarrm-config"
						readOnly:  false
						configMap: spec.configMaps["jellyswarrm-config"]
					}
				}
			}

			// The rendered application config. Mutable: a config change lands
			// in the live ConfigMap, but subPath mounts never update in-place
			// and the app only reads the file at startup — roll the pod
			// (kubectl rollout restart) to apply changes.
			configMaps: {
				"jellyswarrm-config": {
					immutable: false
					data: {
						"jellyswarrm.toml": "\(toml.Marshal(_tomlConfig))"
					}
				}
			}

			// Expose the Jellyfin-compatible API (and management UI) as a Service.
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
