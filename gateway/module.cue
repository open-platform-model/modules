package gateway

import (
	m "opmodel.dev/core/v1alpha1/module@v1"
)

m.#Module

metadata: {
	modulePath:       "opmodel.dev/modules"
	name:             "gateway"
	version:          "0.1.0"
	description:      "Gateway API Gateway — deploys a configurable Kubernetes Gateway backed by Istio"
	defaultNamespace: "istio-ingress"
	labels: {"app.kubernetes.io/component": "ingress"}
}

#config: {
	gateway: {
		gatewayClassName: string

		// Simple path — declare domains and TLS intent.
		// Each entrypoint generates listeners + optional Certificate CR.
		entrypoints?: [Name=string]: {
			hostnames: [...string]
			tls: bool | *true
			allowedRoutes?: {...}
		}

		// Advanced path — raw Gateway API listeners, merged alongside entrypoint-generated ones.
		listeners?: [...]

		addresses?: [...]
		infrastructure?: {...}

		// Shared issuer for all entrypoint-generated Certificate CRs.
		// Also used for annotation injection when entrypoints is absent.
		issuerRef?: {name: string, kind: string}
	}
	httpRedirect: {
		enabled: bool | *true
		parentRef?: {
			name:       string
			namespace?: string
		}
	}
}

debugValues: {
	gateway: {
		gatewayClassName: "istio"
		entrypoints: web: {
			hostnames: ["example.com"]
		}
		issuerRef: {name: "letsencrypt-prod", kind: "ClusterIssuer"}
	}
	httpRedirect: {
		enabled: true
	}
}
