// Components for the Seafile module.
//
//   seafile   — Seahub web UI + fileserver (StatefulSet) on :80, /shared PVC.
//               Init container blocks startup until MariaDB accepts connections.
//   mariadb   — MariaDB database (StatefulSet), /var/lib/mysql PVC.
//   memcached — Memcached cache (Deployment), in-memory only.
//
// The Seafile server reaches MariaDB at "<release>-mariadb" (DB_HOST). The DB
// root password is shared between MariaDB and Seafile via the auto-created
// "seafile-secret" Kubernetes Secret.
package seafile

import (
	resources_workload "opmodel.dev/opm/v1alpha1/resources/workload@v1"
	resources_storage "opmodel.dev/opm/v1alpha1/resources/storage@v1"
	traits_workload "opmodel.dev/opm/v1alpha1/traits/workload@v1"
	traits_network "opmodel.dev/opm/v1alpha1/traits/network@v1"
)

#components: {

	/////////////////////////////////////////////////////////////////
	//// Seafile — Seahub web UI + fileserver
	/////////////////////////////////////////////////////////////////

	seafile: {
		resources_workload.#Container
		resources_storage.#Volumes
		traits_workload.#InitContainers
		traits_workload.#Scaling
		traits_workload.#RestartPolicy
		traits_workload.#UpdateStrategy
		traits_network.#Expose

		// Conditional ingress.
		if #config.httpRoute != _|_ {
			traits_network.#HttpRoute
		}

		metadata: {
			name: "seafile"
			labels: "core.opmodel.dev/workload-type": "stateful"
		}

		spec: {
			scaling: count: 1
			restartPolicy: "Always"
			// Recreate — the /shared PVC is ReadWriteOnce; two pods cannot mount it.
			updateStrategy: type: "Recreate"

			// Block startup until MariaDB accepts TCP connections. Seafile's
			// first-boot DB initialisation fails fast if MariaDB is not ready.
			initContainers: [{
				name:  "wait-for-mariadb"
				image: #config.initImage
				command: [
					"/bin/sh", "-c",
					"until nc -z \(#config.releaseName)-mariadb \(#config.dbPort); do echo 'waiting for mariadb...'; sleep 2; done",
				]
			}]

			container: {
				name:  "seafile"
				image: #config.image

				ports: http: targetPort: #config.port

				env: {
					DB_HOST: {
						name:  "DB_HOST"
						value: "\(#config.releaseName)-mariadb"
					}
					DB_ROOT_PASSWD: {
						name: "DB_ROOT_PASSWD"
						from: #config.dbRootPassword
					}
					TIME_ZONE: {
						name:  "TIME_ZONE"
						value: #config.timezone
					}
					SEAFILE_ADMIN_EMAIL: {
						name:  "SEAFILE_ADMIN_EMAIL"
						value: #config.adminEmail
					}
					SEAFILE_ADMIN_PASSWORD: {
						name: "SEAFILE_ADMIN_PASSWORD"
						from: #config.adminPassword
					}
					SEAFILE_SERVER_HOSTNAME: {
						name:  "SEAFILE_SERVER_HOSTNAME"
						value: #config.seafileServerHostname
					}
					// TLS is terminated upstream (gateway). Do not let the image
					// attempt its own Let's Encrypt provisioning.
					SEAFILE_SERVER_LETSENCRYPT: {
						name:  "SEAFILE_SERVER_LETSENCRYPT"
						value: "false"
					}
				}

				// Seafile's first boot (DB schema creation) is slow; give it a
				// generous startup window before liveness can kill the pod.
				readinessProbe: {
					httpGet: {
						path: "/"
						port: #config.port
					}
					initialDelaySeconds: 60
					periodSeconds:       15
					timeoutSeconds:      5
					failureThreshold:    40
				}
				livenessProbe: {
					httpGet: {
						path: "/"
						port: #config.port
					}
					initialDelaySeconds: 300
					periodSeconds:       30
					timeoutSeconds:      5
					failureThreshold:    6
				}

				if #config.resources != _|_ {
					resources: #config.resources
				}

				volumeMounts: data: volumes.data & {
					mountPath: #config.storage.data.mountPath
				}
			}

			// /shared — Seafile libraries, file blocks, and generated config.
			volumes: data: {
				name: "data"
				if #config.storage.data.type == "pvc" {
					persistentClaim: {
						size: #config.storage.data.size
						if #config.storage.data.storageClass != _|_ {
							storageClass: #config.storage.data.storageClass
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

			// Expose the web UI as a Service.
			expose: {
				ports: http: container.ports.http & {
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

	/////////////////////////////////////////////////////////////////
	//// MariaDB — relational store for Seafile
	/////////////////////////////////////////////////////////////////

	mariadb: {
		resources_workload.#Container
		resources_storage.#Volumes
		traits_workload.#Scaling
		traits_workload.#RestartPolicy
		traits_workload.#UpdateStrategy
		traits_network.#Expose

		metadata: {
			name: "mariadb"
			labels: "core.opmodel.dev/workload-type": "stateful"
		}

		spec: {
			scaling: count: 1
			restartPolicy: "Always"
			// Recreate — /var/lib/mysql is ReadWriteOnce.
			updateStrategy: type: "Recreate"

			container: {
				name:  "mariadb"
				image: #config.mariadbImage

				ports: db: targetPort: #config.dbPort

				env: {
					MARIADB_ROOT_PASSWORD: {
						name: "MARIADB_ROOT_PASSWORD"
						from: #config.dbRootPassword
					}
					// Auto-run mariadb-upgrade after an image version bump.
					MARIADB_AUTO_UPGRADE: {
						name:  "MARIADB_AUTO_UPGRADE"
						value: "true"
					}
				}

				readinessProbe: {
					tcpSocket: port: #config.dbPort
					initialDelaySeconds: 10
					periodSeconds:       10
					timeoutSeconds:      3
					failureThreshold:    6
				}
				livenessProbe: {
					tcpSocket: port: #config.dbPort
					initialDelaySeconds: 30
					periodSeconds:       20
					timeoutSeconds:      3
					failureThreshold:    6
				}

				if #config.mariadbResources != _|_ {
					resources: #config.mariadbResources
				}

				volumeMounts: db: volumes.db & {
					mountPath: #config.storage.database.mountPath
				}
			}

			volumes: db: {
				name: "db"
				if #config.storage.database.type == "pvc" {
					persistentClaim: {
						size: #config.storage.database.size
						if #config.storage.database.storageClass != _|_ {
							storageClass: #config.storage.database.storageClass
						}
					}
				}
				if #config.storage.database.type == "emptyDir" {
					emptyDir: {}
				}
				if #config.storage.database.type == "nfs" {
					nfs: {
						server: #config.storage.database.server
						path:   #config.storage.database.path
					}
				}
			}

			expose: {
				ports: db: container.ports.db & {
					exposedPort: #config.dbPort
				}
				type: "ClusterIP"
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Memcached — Seahub session/metadata cache
	/////////////////////////////////////////////////////////////////

	memcached: {
		resources_workload.#Container
		traits_workload.#Scaling
		traits_workload.#RestartPolicy
		traits_workload.#UpdateStrategy
		traits_network.#Expose

		metadata: {
			name: "memcached"
			labels: "core.opmodel.dev/workload-type": "stateless"
		}

		spec: {
			scaling: count: 1
			restartPolicy: "Always"
			updateStrategy: type: "RollingUpdate"

			container: {
				name:  "memcached"
				image: #config.memcachedImage
				args: ["-m", "\(#config.cacheMemoryLimit)"]

				ports: cache: targetPort: #config.cachePort

				readinessProbe: {
					tcpSocket: port: #config.cachePort
					initialDelaySeconds: 5
					periodSeconds:       10
					timeoutSeconds:      3
					failureThreshold:    3
				}
			}

			expose: {
				ports: cache: container.ports.cache & {
					exposedPort: #config.cachePort
				}
				type: "ClusterIP"
			}
		}
	}
}
