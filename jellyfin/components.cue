// Components defines the Jellyfin workload.
// Single stateful component with persistent config, optional media mounts,
// a web Service, health checks, and optional Serilog logging / GPU / HTTPRoute.
package jellyfin

import (
	"encoding/json"

	bp "opmodel.dev/catalogs/opm/blueprints/workload"
	res "opmodel.dev/catalogs/opm/resources"
	tr "opmodel.dev/catalogs/opm/traits"
)

// #components contains component definitions.
// Components reference #config which gets resolved to concrete values at build time.
#components: {

	/////////////////////////////////////////////////////////////////
	//// Jellyfin - Stateful Media Server
	/////////////////////////////////////////////////////////////////

	jellyfin: {
		// StatefulWorkload composes the Container + Volumes resources and the
		// scaling / restart / init-container traits, and stamps the
		// workload-type=stateful label that selects the StatefulSet transformer.
		bp.#StatefulWorkload
		tr.#Expose
		tr.#SecurityContext
		res.#ConfigMaps

		// HTTPRoute trait only when ingress is requested.
		if #config.httpRoute != _|_ {
			tr.#HttpRoute
		}

		metadata: name: "jellyfin"

		// Bind the rendered volume set so volumeMounts can reuse each source.
		_volumes: spec.statefulWorkload.volumes

		// All storage entries flattened into one named map for uniform rendering.
		// config is always present; media entries are optional.
		_allVolumes: {
			config: #config.storage.config
			if #config.storage.media != _|_ {
				for name, v in #config.storage.media {
					(name): v
				}
			}
		}

		spec: {
			statefulWorkload: {
				// Single replica - Jellyfin does not support horizontal scaling.
				scaling: count: 1
				restartPolicy: "Always"
				updateStrategy: {
					type: "RollingUpdate"
					rollingUpdate: {}
				}

				// Fix file ownership on every start so /config is writable by
				// the LinuxServer.io PUID/PGID regardless of how the PVC was
				// provisioned.
				initContainers: [{
					name: "fix-permissions"
					image: {
						repository: "busybox"
						tag:        "1.37"
						digest:     ""
					}
					command: ["/bin/sh", "-c", "chown -R \(#config.puid):\(#config.pgid) \(#config.storage.config.mountPath)"]
					volumeMounts: config: _volumes.config & {
						mountPath: #config.storage.config.mountPath
					}
				}]

				container: {
					name:  "jellyfin"
					image: #config.image
					ports: http: {
						name:       "http"
						targetPort: 8096
					}
					env: {
						PUID: {
							name:  "PUID"
							value: "\(#config.puid)"
						}
						PGID: {
							name:  "PGID"
							value: "\(#config.pgid)"
						}
						TZ: {
							name:  "TZ"
							value: #config.timezone
						}
						JELLYFIN_DATA_DIR: {
							name:  "JELLYFIN_DATA_DIR"
							value: #config.storage.config.mountPath
						}
						if #config.publishedServerUrl != _|_ {
							JELLYFIN_PublishedServerUrl: {
								name:  "JELLYFIN_PublishedServerUrl"
								value: #config.publishedServerUrl
							}
						}
					}
					livenessProbe: {
						httpGet: {
							path: "/health"
							port: 8096
						}
						initialDelaySeconds: 30
						periodSeconds:       10
						timeoutSeconds:      5
						failureThreshold:    3
					}
					readinessProbe: {
						httpGet: {
							path: "/health"
							port: 8096
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
						for vName, v in _allVolumes {
							(vName): _volumes[vName] & {
								mountPath: v.mountPath
							}
						}

						// Serilog logging config — mounted as a single file via subPath.
						// Built fresh (not unified from _volumes) so readOnly can be
						// true without conflicting with the volume's readOnly: false.
						if #config.logging != _|_ {
							"jellyfin-logging": {
								name:      "jellyfin-logging"
								configMap: spec.configMaps["jellyfin-logging"]
								mountPath: "/config/logging.json"
								subPath:   "logging.json"
								readOnly:  true
							}
						}
					}
				}

				// All volumes rendered from _allVolumes via a type-switch.
				// accessMode/storageClass/readOnly carry no catalog defaults, so
				// every field must be set concretely — the release must finalize
				// to a fully concrete value before transformers run.
				volumes: {
					for name, v in _allVolumes {
						(name): {
							"name":   name
							readOnly: false
							if v.type == "pvc" {
								persistentClaim: {
									size:       v.size
									accessMode: "ReadWriteOnce"
									if v.storageClass != _|_ {
										storageClass: v.storageClass
									}
									if v.storageClass == _|_ {
										storageClass: "standard"
									}
								}
							}
							if v.type == "emptyDir" {
								emptyDir: {}
							}
							if v.type == "nfs" {
								nfs: {
									server: v.server
									path:   v.path
								}
							}
						}
					}

					// Logging ConfigMap volume — only when logging is configured.
					if #config.logging != _|_ {
						"jellyfin-logging": {
							name:      "jellyfin-logging"
							readOnly:  false
							configMap: spec.configMaps["jellyfin-logging"]
						}
					}
				}
			}

			// Intel GPU — add render group supplemental GIDs for DRI device access.
			if #config.resources != _|_ if #config.resources.gpu != _|_ {
				securityContext: supplementalGroups: [44, 109]
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

			// Serilog logging config injected as a ConfigMap — only when configured.
			if #config.logging != _|_ {
				configMaps: {
					"jellyfin-logging": {
						immutable: false
						data: {
							"logging.json": "\(json.Marshal({
								Serilog: {
									MinimumLevel: {
										Default: #config.logging.defaultLevel
										if #config.logging.overrides != _|_ {
											Override: #config.logging.overrides
										}
									}
								}
							}))"
						}
					}
				}
			}
		}
	}
}
