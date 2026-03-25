// Components defines the Jellyfin workload.
// Single stateful component with persistent config, media mounts, and health checks.
package jellyfin

import (
	"encoding/json"

	resources_config "opmodel.dev/opm/v1alpha1/resources/config@v1"
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
	//// Jellyfin - Stateful Media Server
	/////////////////////////////////////////////////////////////////

	jellyfin: {
		resources_workload.#Container
		resources_storage.#Volumes
		resources_config.#ConfigMaps
		traits_workload.#Scaling
		traits_workload.#RestartPolicy
		traits_network.#Expose
		traits_security.#SecurityContext

		metadata: name: "jellyfin"
		metadata: labels: "core.opmodel.dev/workload-type": "stateful"

		_volumes: spec.volumes

		// All storage entries flattened into a single named map for uniform rendering.
		// config is always present; backup and media entries are optional.
		_allVolumes: {
			config: #config.storage.config
			if #config.storage.backup != _|_ {
				backup: #config.storage.backup
			}
			if #config.storage.media != _|_ {
				for name, v in #config.storage.media {
					(name): v
				}
			}
		}

		spec: {
			// Single replica - Jellyfin does not support horizontal scaling
			scaling: count: 1

			restartPolicy: "Always"

			// Intel GPU — add render group supplemental GIDs for DRI device access
			if #config.resources != _|_ if #config.resources.gpu != _|_ {
				securityContext: supplementalGroups: [44, 109]
			}

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

					// Serilog logging config — mounted as a single file via subPath
					if #config.logging != _|_ {
						"jellyfin-logging": _volumes["jellyfin-logging"] & {
							mountPath: "/config/logging.json"
							subPath:   "logging.json"
							readOnly:  true
						}
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

			// Serilog logging config injected as a ConfigMap — only when logging is configured
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

			// All volumes rendered from _allVolumes using a unified type-switch
			volumes: {
				for name, v in _allVolumes {
					(name): {
						"name": name
						if v.type == "pvc" {
							persistentClaim: {
								size: v.size
								if v.storageClass != _|_ {
									storageClass: v.storageClass
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

				// Logging ConfigMap volume — only present when logging is configured
				if #config.logging != _|_ {
					"jellyfin-logging": {
						name:      "jellyfin-logging"
						configMap: spec.configMaps["jellyfin-logging"]
					}
				}
			}
		}
	}
}
