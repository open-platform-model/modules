package zot_registry_ttl

import (
	"encoding/json"
	resources_workload "opmodel.dev/opm/v1alpha1/resources/workload@v1"
	resources_storage "opmodel.dev/opm/v1alpha1/resources/storage@v1"
	resources_config "opmodel.dev/opm/v1alpha1/resources/config@v1"
	traits_workload "opmodel.dev/opm/v1alpha1/traits/workload@v1"
	traits_network "opmodel.dev/opm/v1alpha1/traits/network@v1"
	traits_security "opmodel.dev/opm/v1alpha1/traits/security@v1"
)

#components: {
	registry: {
		resources_workload.#Container
		resources_storage.#Volumes
		resources_config.#ConfigMaps
		traits_workload.#Scaling
		traits_workload.#RestartPolicy
		traits_workload.#UpdateStrategy
		traits_workload.#GracefulShutdown
		traits_network.#Expose
		traits_security.#SecurityContext
		traits_security.#WorkloadIdentity

		// Conditional ingress
		if #config.httpRoute != _|_ {
			traits_network.#HttpRoute
		}

		metadata: {
			name: "registry"
			labels: {
				"core.opmodel.dev/workload-type": "stateful"
			}
		}

		// Build Zot config.json from CUE -- no auth, anonymous push/pull, TTL retention
		let _zotConfig = {
			distSpecVersion: "1.1.0"

			storage: {
				rootDirectory: #config.storage.rootDir
				gc:            true
				gcDelay:       #config.storage.gc.delay
				gcInterval:    #config.storage.gc.interval

				retention: {
					dryRun: false
					delay:  #config.ttl.delay

					// Per-prefix policies followed by a catch-all using defaultTTL
				policies: [
						for p in #config.ttl.policies {
							repositories:    p.repositories
							deleteReferrers: true
							deleteUntagged:  true
							keepTags: [{
								pushedWithin: p.pushedWithin
								pulledWithin: p.pulledWithin
							}]
						},
						{
							repositories:    ["**"]
							deleteReferrers: true
							deleteUntagged:  true
							keepTags: [{
								pushedWithin: #config.ttl.defaultTTL
								pulledWithin: #config.ttl.defaultTTL
							}]
						},
					]
				}
			}

			http: {
				address: #config.http.address
				port:    "\(#config.http.port)" // Zot expects string

				// Anonymous push/pull -- no authentication required
				accessControl: {
					repositories: {
						"**": {
							anonymousPolicy: ["read", "create", "update", "delete"]
						}
					}
				}
			}

			log: {
				level: #config.log.level
			}
		}

		spec: {
			// Container spec
			container: {
				name: "zot"
				image: {
					// Full image only -- retention policies are unavailable in zot-minimal
					repository: "ghcr.io/project-zot/zot"
					tag:        #config.image.tag
					digest:     #config.image.digest
					pullPolicy: #config.image.pullPolicy
				}

				ports: {
					api: {
						name:       "api"
						targetPort: #config.http.port
						protocol:   "TCP"
					}
				}

				env: {}

				volumeMounts: {
					data: {
						name:      "data"
						mountPath: #config.storage.rootDir
					}
					"zot-config": {
						name:      "zot-config"
						mountPath: "/etc/zot"
						readOnly:  true
					}
				}

				resources: #config.resources

				// Health probes
				startupProbe: {
					httpGet: {
						path: "/startupz"
						port: #config.http.port
					}
					initialDelaySeconds: 5
					periodSeconds:       10
					failureThreshold:    3
				}

				livenessProbe: {
					httpGet: {
						path: "/livez"
						port: #config.http.port
					}
					initialDelaySeconds: 10
					periodSeconds:       10
					failureThreshold:    3
				}

				readinessProbe: {
					httpGet: {
						path: "/readyz"
						port: #config.http.port
					}
					initialDelaySeconds: 5
					periodSeconds:       5
					failureThreshold:    3
				}
			}

			// Volumes
			volumes: {
				data: {
					name: "data"
					if #config.storage.type == "pvc" {
						persistentClaim: {
							size:         #config.storage.size
							accessMode:   "ReadWriteOnce"
							storageClass: #config.storage.storageClass
						}
					}
					if #config.storage.type == "emptyDir" {
						emptyDir: {
							medium: "node"
						}
					}
				}

				"zot-config": {
					name:      "zot-config"
					configMap: configMaps["zot-config"]
				}
			}

			// ConfigMap with generated config.json
			configMaps: {
				"zot-config": {
					name: "zot-config"
					data: {
						"config.json": json.Marshal(_zotConfig)
					}
				}
			}

			// Workload traits
			scaling: {
				count: #config.replicas
			}

			restartPolicy: "Always"

			updateStrategy: {
				// Recreate for single-replica ephemeral workloads to avoid split-brain
				if #config.replicas == 1 {
					type: "Recreate"
				}
				if #config.replicas > 1 {
					type: "RollingUpdate"
					rollingUpdate: {
						maxUnavailable: 1
					}
				}
			}

			gracefulShutdown: {
				terminationGracePeriodSeconds: 30
			}

			// Network exposure
			expose: {
				type: "ClusterIP"
				ports: {
					api: container.ports.api
				}
			}

			// Optional HTTPRoute
			if #config.httpRoute != _|_ {
				httpRoute: {
					hostnames: #config.httpRoute.hostnames
					rules: [{
						matches: [{
							path: {
								type:  "Prefix"
								value: "/"
							}
						}]
						backendPort: #config.http.port
					}]
					if #config.httpRoute.tls != _|_ {
						tls: {
							mode: "Terminate"
							certificateRefs: [{
								kind: "Secret"
								name: #config.httpRoute.tls.secretName
							}]
						}
					}
					if #config.httpRoute.gatewayRef != _|_ {
						parentRefs: [{
							name:      #config.httpRoute.gatewayRef.name
							namespace: #config.httpRoute.gatewayRef.namespace
						}]
					}
				}
			}

			// Security context
			securityContext: #config.security

			// Workload identity
			workloadIdentity: {
				name:           "zot-registry-ttl"
				automountToken: false
			}
		}
	}
}
