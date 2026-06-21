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
	traits_init "opmodel.dev/opm/v1alpha1/traits/workload@v1"
	k8up_backup "opmodel.dev/k8up/v1alpha1/resources/backup@v1"
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
		traits_init.#InitContainers
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

			// fsGroup ensures volume files are group-accessible by Seerr (UID 1000).
			// runAsUser/runAsGroup are intentionally omitted so the init container
			// can run as root for chown; the Seerr image runs as UID 1000 internally.
			securityContext: {
				fsGroup: 1000
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
				command: ["/bin/sh", "-c", "chown -R 1000:1000 /app/config"]
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

	/////////////////////////////////////////////////////////////////
	//// K8up Backup — Schedule + PreBackupPod (SQLite only)
	/////////////////////////////////////////////////////////////////

	if #config.backup != _|_ {
		"backup-schedule": {
			k8up_backup.#Schedule

			metadata: name: "backup"

			spec: schedule: spec: {
				backend: {
					repoPasswordSecretRef: #config.backup.repoPassword
					s3: {
						endpoint:                 #config.backup.s3.endpoint
						bucket:                   #config.backup.s3.bucket
						accessKeyIDSecretRef:     #config.backup.s3.accessKeyID
						secretAccessKeySecretRef: #config.backup.s3.secretAccessKey
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

	// PreBackupPod for SQLite WAL checkpoint — only when NOT using PostgreSQL.
	// When postgres is configured, the database lives externally and doesn't need a file-level checkpoint.
	if #config.backup != _|_ if #config.postgres == _|_ {
		"pre-backup-checkpoint": {
			k8up_backup.#PreBackupPod

			metadata: name: "sqlite-checkpoint"

			spec: preBackupPod: spec: {
				backupCommand: "/bin/sh -c 'sqlite3 /app/config/db/db.sqlite3 \"PRAGMA wal_checkpoint(TRUNCATE);\"'"
				pod: spec: {
					containers: [{
						name:  "sqlite-checkpoint"
						image: "alpine:3.19"
						command: ["/bin/sh", "-c", "apk add --no-cache sqlite && sleep infinity"]
						volumeMounts: [{
							name:      "config"
							mountPath: "/app/config"
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
