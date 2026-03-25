package gateway

import (
	m "opmodel.dev/core/v1alpha1/module@v1"
	schemas "opmodel.dev/gateway_api/v1alpha1/schemas@v1"
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
	gatewayClassName: string | *"istio"
	listeners: [schemas.#ListenerSchema, ...schemas.#ListenerSchema]
	issuerRef?:      schemas.#GatewaySchema.issuerRef
	infrastructure?: schemas.#GatewaySchema.infrastructure
}

debugValues: {
	gatewayClassName: "istio"
	listeners: [
		{
			name:     "http"
			port:     80
			protocol: "HTTP"
		},
		{
			name:     "https"
			port:     443
			protocol: "HTTPS"
			hostname: "example.com"
			tls: {
				mode: "Terminate"
				certificateRef: {name: "example-tls", namespace: "istio-ingress"}
			}
		},
	]
	issuerRef: {name: "letsencrypt-prod", kind: "ClusterIssuer"}
}
