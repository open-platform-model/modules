// Components defines a standalone mc-router workload.
//
//   - One `router` component (mc-router Deployment + Service) in Kubernetes
//     service-discovery mode (IN_KUBE_CLUSTER). Backends are discovered from
//     Service annotations — there are NO static --mapping args.
//   - One `rbac` component granting the router its Service-watch (and StatefulSet
//     scale, for auto-scale) permissions. Namespaced by default; cluster-scoped
//     only when router.watchAllNamespaces is true.
package mc_router

import (
	resources_workload "opmodel.dev/opm/v1alpha1/resources/workload@v1"
	resources_security "opmodel.dev/opm/v1alpha1/resources/security@v1"
	traits_workload "opmodel.dev/opm/v1alpha1/traits/workload@v1"
	traits_network "opmodel.dev/opm/v1alpha1/traits/network@v1"
	traits_security "opmodel.dev/opm/v1alpha1/traits/security@v1"
)

// #components contains component definitions.
#components: {
	let _routerName = "\(#config.releaseName)-router"

	// ── mc-router ─────────────────────────────────────────────────────────────
	// Service-discovery router. Watches annotated Services (scoped by KUBE_NAMESPACE
	// unless watchAllNamespaces) and routes by hostname. No static mappings.
	router: {
		resources_workload.#Container
		traits_workload.#Scaling
		traits_workload.#RestartPolicy
		traits_workload.#UpdateStrategy
		traits_network.#Expose
		traits_security.#WorkloadIdentity

		metadata: labels: "core.opmodel.dev/workload-type": "stateless"

		spec: {
			scaling: count: 1

			restartPolicy: "Always"

			updateStrategy: type: "Recreate"

			workloadIdentity: {
				name:           _routerName
				automountToken: true
			}

			container: {
				name:  _routerName
				image: #config.router.image

				ports: {
					minecraft: {
						targetPort: #config.router.port
						protocol:   "TCP"
					}
					if #config.router.api.enabled {
						api: {
							targetPort: #config.router.api.port
							protocol:   "TCP"
						}
					}
				}

				env: {
					PORT: {
						name:  "PORT"
						value: "\(#config.router.port)"
					}
					CONNECTION_RATE_LIMIT: {
						name:  "CONNECTION_RATE_LIMIT"
						value: "\(#config.router.connectionRateLimit)"
					}
					DEBUG: {
						name:  "DEBUG"
						value: "\(#config.router.debug)"
					}

					// === Kubernetes service discovery ===
					// Watch Services and read mc-router.itzg.me/* annotations.
					IN_KUBE_CLUSTER: {
						name:  "IN_KUBE_CLUSTER"
						value: "true"
					}
					// Restrict the watch to a single namespace unless widened. Omitting
					// KUBE_NAMESPACE makes mc-router watch all namespaces.
					if !#config.router.watchAllNamespaces {
						KUBE_NAMESPACE: {
							name:  "KUBE_NAMESPACE"
							value: #config.router.watchNamespace
						}
					}

					if #config.router.simplifySrv {
						SIMPLIFY_SRV: {
							name:  "SIMPLIFY_SRV"
							value: "true"
						}
					}
					if #config.router.useProxyProtocol {
						USE_PROXY_PROTOCOL: {
							name:  "USE_PROXY_PROTOCOL"
							value: "true"
						}
					}
					if #config.router.defaultServer != _|_ {
						DEFAULT: {
							name:  "DEFAULT"
							value: "\(#config.router.defaultServer.host):\(#config.router.defaultServer.port)"
						}
					}
					if #config.router.autoScale != _|_ {
						if #config.router.autoScale.up != _|_ {
							AUTO_SCALE_UP: {
								name:  "AUTO_SCALE_UP"
								value: "\(#config.router.autoScale.up.enabled)"
							}
						}
						if #config.router.autoScale.down != _|_ {
							AUTO_SCALE_DOWN: {
								name:  "AUTO_SCALE_DOWN"
								value: "\(#config.router.autoScale.down.enabled)"
							}
							if #config.router.autoScale.down.after != _|_ {
								AUTO_SCALE_DOWN_AFTER: {
									name:  "AUTO_SCALE_DOWN_AFTER"
									value: #config.router.autoScale.down.after
								}
							}
						}
					}
					if #config.router.metrics != _|_ {
						METRICS_BACKEND: {
							name:  "METRICS_BACKEND"
							value: #config.router.metrics.backend
						}
					}
					if #config.router.api.enabled {
						API_BINDING: {
							name:  "API_BINDING"
							value: ":\(#config.router.api.port)"
						}
					}
				}

				if #config.router.resources != _|_ {
					resources: #config.router.resources
				}
			}

			expose: {
				ports: {
					minecraft: {
						targetPort:  #config.router.port
						protocol:    "TCP"
						exposedPort: #config.router.port
					}
					if #config.router.api.enabled {
						api: {
							targetPort:  #config.router.api.port
							protocol:    "TCP"
							exposedPort: #config.router.api.port
						}
					}
				}
				type: #config.router.serviceType
			}
		}
	}

	// ── RBAC ──────────────────────────────────────────────────────────────────
	// Grants mc-router permission to watch/list Services (service discovery) and
	// manage StatefulSets (auto-scale wake/sleep). Namespaced by default; only
	// cluster-scoped when discovery is widened to all namespaces.
	rbac: {
		resources_security.#Role

		spec: role: {
			name: _routerName
			if #config.router.watchAllNamespaces {
				scope: "cluster"
			}
			if !#config.router.watchAllNamespaces {
				scope: "namespace"
			}

			rules: [
				{
					apiGroups: [""]
					resources: ["services"]
					verbs: ["watch", "list"]
				},
				{
					apiGroups: ["apps"]
					resources: ["statefulsets", "statefulsets/scale"]
					verbs: ["watch", "list", "get", "update", "patch"]
				},
			]

			subjects: [{
				name: _routerName
			}]
		}
	}
}
