package gateway

import (
	gw_resources "opmodel.dev/gateway_api/v1alpha1/resources/network@v1"
)

#components: {
	gateway: {
		gw_resources.#GatewayComponent
		spec: gateway: {
			gatewayClassName: #config.gatewayClassName
			listeners:        #config.listeners
			if #config.issuerRef != _|_ {issuerRef: #config.issuerRef}
			if #config.infrastructure != _|_ {infrastructure: #config.infrastructure}
		}
	}
}
