// Components defines the northbyte-web workload: a single stateless nginx
// container serving the baked-in static site, exposed as a Service, with an
// optional Gateway HTTPRoute binding the public hostname(s).
//
// System A (opm/v1alpha1). Flat trait composition, workload-type=stateless ->
// Deployment. HttpRoute form mirrors seerr_v016 (gatewayRef + backendPort).
package northbyte_web

import (
	resources_workload "opmodel.dev/opm/v1alpha1/resources/workload@v1"
	traits_workload "opmodel.dev/opm/v1alpha1/traits/workload@v1"
	traits_network "opmodel.dev/opm/v1alpha1/traits/network@v1"
)

#components: {
	web: {
		resources_workload.#Container
		traits_workload.#Scaling
		traits_workload.#RestartPolicy
		traits_workload.#UpdateStrategy
		traits_network.#Expose

		// Conditional public ingress.
		if #config.httpRoute != _|_ {
			traits_network.#HttpRoute
		}

		metadata: {
			name: "web"
			labels: "core.opmodel.dev/workload-type": "stateless"
		}

		spec: {
			container: {
				name:  "web"
				image: #config.image
				ports: http: {
					name:       "http"
					targetPort: #config.port
				}

				// nginx serves the site root with 200; use it as the health signal.
				readinessProbe: {
					httpGet: {
						path: "/"
						port: #config.port
					}
					initialDelaySeconds: 3
					periodSeconds:       10
					timeoutSeconds:      3
					failureThreshold:    3
				}
				livenessProbe: {
					httpGet: {
						path: "/"
						port: #config.port
					}
					initialDelaySeconds: 5
					periodSeconds:       20
					timeoutSeconds:      3
					failureThreshold:    3
				}

				if #config.resources != _|_ {
					resources: #config.resources
				}
			}

			scaling: count: #config.replicas
			restartPolicy: "Always"
			updateStrategy: {
				type: "RollingUpdate"
				rollingUpdate: maxUnavailable: 1
			}

			// Expose the container port as a Service.
			expose: {
				type: #config.serviceType
				ports: http: container.ports.http & {
					exposedPort: #config.port
				}
			}

			// Optional HTTPRoute — binds the public hostname(s) at the gateway.
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
