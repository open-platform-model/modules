// Components defines the web-app workload: a single stateless container behind
// a Service. The StatelessWorkload blueprint stamps workload-type=stateless,
// which selects the deployment-transformer; the Expose trait selects the
// service-transformer.
package web_app

import (
	bp "opmodel.dev/catalogs/opm/blueprints/workload"
	tr "opmodel.dev/catalogs/opm/traits"
)

#components: {
	web: {
		bp.#StatelessWorkload
		tr.#Expose

		metadata: name: "web"

		spec: {
			statelessWorkload: {
				container: {
					name:  "web"
					image: #config.image
					ports: http: {
						name:       "http"
						targetPort: #config.port
					}
				}
				scaling: count: #config.replicas
				restartPolicy: "Always"
				updateStrategy: {
					type: "RollingUpdate"
					rollingUpdate: {}
				}
			}

			// Expose the container port as a Service.
			expose: {
				ports: http: statelessWorkload.container.ports.http & {
					exposedPort: #config.port
				}
				type: #config.serviceType
			}
		}
	}
}
