// Components defines the Jellyfin workload.
// Single stateful component with persistent config, media mounts, and health checks.
// When backup is configured, adds K8up Schedule and PreBackupPod components.
package jellyfin

import (
	"encoding/json"

	resources_config "opmodel.dev/opm/v1alpha1/resources/config@v1"
	resources_workload "opmodel.dev/opm/v1alpha1/resources/workload@v1"
	resources_storage "opmodel.dev/opm/v1alpha1/resources/storage@v1"
	traits_workload "opmodel.dev/opm/v1alpha1/traits/workload@v1"
	traits_network "opmodel.dev/opm/v1alpha1/traits/network@v1"
	traits_security "opmodel.dev/opm/v1alpha1/traits/security@v1"
	traits_init "opmodel.dev/opm/v1alpha1/traits/workload@v1"
	k8up_backup "opmodel.dev/k8up/v1alpha1/resources/backup@v1"
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
		traits_init.#InitContainers
		traits_network.#Expose
		traits_security.#SecurityContext

		// Conditional ingress
		if #config.httpRoute != _|_ {
			traits_network.#HttpRoute
		}

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

			// Fix file ownership after a K8up restore (restic restores with backup-time UID).
			// Runs on every start so permissions are always correct.
			initContainers: [{
				name: "fix-permissions"
				image: {
					repository: "busybox"
					tag:        "1.37"
					digest:     ""
				}
				command: ["/bin/sh", "-c", "chown -R \(#config.puid):\(#config.pgid) /config"]
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

	/////////////////////////////////////////////////////////////////
	//// K8up Backup Schedule — recurring backup, check, and prune
	////
	//// Only created when #config.backup is set.
	//// Backs up the config PVC to S3 via restic.
	/////////////////////////////////////////////////////////////////

	if #config.backup != _|_ {
		"backup-schedule": {
			k8up_backup.#Schedule

			metadata: name: "backup"

			spec: schedule: spec: {
				backend: {
					repoPasswordSecretRef: #config.backup.repoPasswordSecretRef
					s3: {
						endpoint:                 #config.backup.s3.endpoint
						bucket:                   #config.backup.s3.bucket
						accessKeyIDSecretRef:     #config.backup.s3.accessKeyIDSecretRef
						secretAccessKeySecretRef: #config.backup.s3.secretAccessKeySecretRef
					}
				}
				backup: {
					schedule:                   #config.backup.schedule
					failedJobsHistoryLimit:     3
					successfulJobsHistoryLimit: 3
				}
				check: schedule: #config.backup.checkSchedule
				prune: {
					schedule:  #config.backup.pruneSchedule
					retention: #config.backup.retention
				}
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// K8up PreBackupPod — SQLite WAL checkpoint before backup
	////
	//// Only created when #config.backup is set.
	//// Runs PRAGMA wal_checkpoint(TRUNCATE) on both Jellyfin SQLite
	//// databases to ensure backup consistency.
	/////////////////////////////////////////////////////////////////

	if #config.backup != _|_ {
		"pre-backup-checkpoint": {
			k8up_backup.#PreBackupPod

			metadata: name: "sqlite-checkpoint"

			spec: preBackupPod: spec: {
				backupCommand: "/bin/sh -c 'sqlite3 /config/data/library.db \"PRAGMA wal_checkpoint(TRUNCATE);\" && sqlite3 /config/data/jellyfin.db \"PRAGMA wal_checkpoint(TRUNCATE);\"'"
				pod: spec: {
					containers: [{
						name:  "sqlite-checkpoint"
						image: "alpine:3.19"
						command: ["/bin/sh", "-c", "apk add --no-cache sqlite && sleep infinity"]
						volumeMounts: [{
							name:      "config"
							mountPath: "/config"
						}]
					}]
					volumes: [{
						name: "config"
						persistentVolumeClaim: claimName: #config.backup.configPvcName
					}]
				}
			}
		}
	}
}
