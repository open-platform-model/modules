// Package northbyte_web defines the module for the public NorthByte website
// (northbyte.gg / mc.larnet.eu) — a single stateless nginx container serving a
// baked-in static Hugo site, exposed via the Gateway API.
//
// System A module (opm/v1alpha1 + core/v1alpha1, cue v0.16) — the line the whole
// deployed fleet uses. Patterned on seerr_v016 / zot_registry_ttl (single
// container + Expose + optional HttpRoute), minus storage/backup. The site image
// is built and published from the separate northbyte.gg repo.
package northbyte_web

import (
	m "opmodel.dev/core/v1alpha1/module@v1"
	schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)

m.#Module

metadata: {
	modulePath:       "opmodel.dev/modules"
	name:             "northbyte-web"
	version:          "0.1.0"
	description:      "NorthByte public website — static Hugo site served by nginx behind the Gateway API"
	defaultNamespace: "northbyte"
}

#config: {
	// Container image holding the built static site (nginx + baked Hugo output).
	image: schemas.#Image & {
		repository: string | *"ghcr.io/emil-jacero/northbyte-web"
		tag:        string | *"v0.1.0"
		digest:     string | *""
	}

	// Replica count.
	replicas: int & >=1 | *1

	// Container/Service port (nginx listens on 80).
	port: int & >0 & <=65535 | *80

	// Kubernetes Service type.
	serviceType: "ClusterIP" | "NodePort" | "LoadBalancer" | *"ClusterIP"

	// Optional Gateway API HTTPRoute for public ingress.
	httpRoute?: {
		hostnames: [...string]
		gatewayRef?: {
			name:      string
			namespace: string
		}
	}

	// Container resource requests and limits.
	resources?: schemas.#ResourceRequirementsSchema
}

debugValues: {
	image: {
		repository: "ghcr.io/emil-jacero/northbyte-web"
		tag:        "v0.1.0"
		digest:     ""
	}
	replicas:    1
	port:        80
	serviceType: "ClusterIP"
	httpRoute: {
		hostnames: ["northbyte.gg", "www.northbyte.gg", "mc.larnet.eu"]
		gatewayRef: {
			name:      "gateway-gateway"
			namespace: "istio-ingress"
		}
	}
	resources: {
		requests: {
			cpu:    "10m"
			memory: "32Mi"
		}
		limits: {
			cpu:    "200m"
			memory: "64Mi"
		}
	}
}
