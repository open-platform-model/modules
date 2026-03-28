// Components defines the Garage workload.
// Single stateless component configured via a TOML ConfigMap.
package garage

import (
	resources_config "opmodel.dev/opm/v1alpha1/resources/config@v1"
	resources_workload "opmodel.dev/opm/v1alpha1/resources/workload@v1"
	resources_storage "opmodel.dev/opm/v1alpha1/resources/storage@v1"
	traits_workload "opmodel.dev/opm/v1alpha1/traits/workload@v1"
	traits_network "opmodel.dev/opm/v1alpha1/traits/network@v1"
)

// #components contains component definitions.
// Components reference #config which gets resolved to concrete values at build time.
#components: {

	/////////////////////////////////////////////////////////////////
	//// Garage - Lightweight S3-Compatible Storage Server
	/////////////////////////////////////////////////////////////////

	server: {
		resources_workload.#Container
		resources_storage.#Volumes
		resources_config.#ConfigMaps
		traits_workload.#Scaling
		traits_network.#Expose

		metadata: name: "garage"
		metadata: labels: "core.opmodel.dev/workload-type": "stateless"

		_volumes: spec.volumes

		spec: {
			// Single replica — Garage single-node does not support horizontal scaling
			scaling: count: 1

			container: {
				name:  "garage"
				image: #config.image
				ports: {
					s3: {
						name:       "s3"
						targetPort: #config.s3Port
					}
					admin: {
						name:       "admin"
						targetPort: #config.adminPort
					}
					rpc: {
						name:       "rpc"
						targetPort: #config.rpcPort
					}
				}
				resources: #config.resources
				volumeMounts: {
					// Garage config file — mounted as a single file via subPath
					"garage-config": _volumes["garage-config"] & {
						mountPath: "/etc/garage.toml"
						subPath:   "garage.toml"
						readOnly:  true
					}
					// Metadata directory — emptyDir or PVC depending on storage.type
					meta: _volumes.meta & {
						mountPath: "/var/lib/garage/meta"
					}
					// Data directory — emptyDir or PVC depending on storage.type
					data: _volumes.data & {
						mountPath: "/var/lib/garage/data"
					}
				}
			}

			// Expose S3 and admin ports; RPC is cluster-internal only
			expose: {
				ports: {
					s3: container.ports.s3 & {
						exposedPort: #config.s3Port
					}
					admin: container.ports.admin & {
						exposedPort: #config.adminPort
					}
				}
				type: #config.serviceType
			}

			// garage.toml rendered from #config values via string interpolation
			configMaps: {
				"garage-config": {
					immutable: false
					data: {
						"garage.toml": """
							metadata_dir = "/var/lib/garage/meta"
							data_dir = "/var/lib/garage/data"
							db_engine = "sqlite"
							replication_factor = 1

							rpc_bind_addr = "[::]:3901"
							rpc_public_addr = "127.0.0.1:3901"
							rpc_secret = "\(#config.rpcSecret)"

							[s3_api]
							s3_region = "\(#config.region)"
							api_bind_addr = "[::]:3900"
							root_domain = ".s3.garage.localhost"

							[admin]
							api_bind_addr = "[::]:3903"
							admin_token = "\(#config.adminToken)"
							"""
					}
				}
			}

			volumes: {
				// ConfigMap volume for garage.toml
				"garage-config": {
					name:      "garage-config"
					configMap: spec.configMaps["garage-config"]
				}
				// Metadata volume — switches between emptyDir and PVC
				meta: {
					name: "meta"
					if #config.storage.type == "emptyDir" {
						emptyDir: {}
					}
					if #config.storage.type == "pvc" {
						persistentClaim: {
							size: #config.storage.size
							if #config.storage.storageClass != "" {
								storageClass: #config.storage.storageClass
							}
						}
					}
				}
				// Data volume — switches between emptyDir and PVC
				data: {
					name: "data"
					if #config.storage.type == "emptyDir" {
						emptyDir: {}
					}
					if #config.storage.type == "pvc" {
						persistentClaim: {
							size: #config.storage.size
							if #config.storage.storageClass != "" {
								storageClass: #config.storage.storageClass
							}
						}
					}
				}
			}
		}
	}
}
