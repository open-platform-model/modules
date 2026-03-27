package gateway

import (
	"list"

	gw_resources "opmodel.dev/gateway_api/v1alpha1/resources/network@v1"
	cm_security "opmodel.dev/cert_manager/v1alpha1/resources/security@v1"
)

// _httpListeners builds HTTP listeners from entrypoints (one per hostname).
// Uses list.FlattenN to produce a deterministic, flat list from nested for-loops.
_httpListeners: list.FlattenN([
	if #config.gateway.entrypoints != _|_ {
		for epName, ep in #config.gateway.entrypoints {
			[for i, h in ep.hostnames {
				{
					name:     "\(epName)-http-\(i)"
					port:     80
					protocol: "HTTP"
					hostname: h
					if ep.allowedRoutes != _|_ {
						allowedRoutes: ep.allowedRoutes
					}
					if ep.allowedRoutes == _|_ {
						allowedRoutes: namespaces: from: "All"
					}
				}
			}]
		}
	},
], 1)

// _httpsListeners builds HTTPS listeners from TLS-enabled entrypoints (one per hostname).
_httpsListeners: list.FlattenN([
	if #config.gateway.entrypoints != _|_ {
		for epName, ep in #config.gateway.entrypoints if ep.tls {
			[for i, h in ep.hostnames {
				{
					name:     "\(epName)-https-\(i)"
					port:     443
					protocol: "HTTPS"
					hostname: h
					tls: {
						mode: "Terminate"
						certificateRefs: [{name: "gateway-\(epName)-tls"}]
					}
					if ep.allowedRoutes != _|_ {
						allowedRoutes: ep.allowedRoutes
					}
					if ep.allowedRoutes == _|_ {
						allowedRoutes: namespaces: from: "All"
					}
				}
			}]
		}
	},
], 1)

// _allListeners merges entrypoint-generated listeners with any raw listeners.
_allListeners: list.Concat([
	_httpListeners,
	_httpsListeners,
	if #config.gateway.listeners != _|_ {#config.gateway.listeners},
	if #config.gateway.listeners == _|_ {[]},
])

// _httpParentRefs collects one parentRef per entrypoint HTTP listener for the redirect route.
// Uses list.FlattenN to avoid nested-for unification conflicts in CUE list comprehensions.
_httpParentRefs: list.FlattenN([
	if #config.gateway.entrypoints != _|_ {
		for epName, ep in #config.gateway.entrypoints {
			[for i, _ in ep.hostnames {
				{name: "gateway-gateway", sectionName: "\(epName)-http-\(i)"}
			}]
		}
	},
], 1)

// _explicitParentRefs supports the raw listeners path when parentRef is set manually.
_explicitParentRefs: [
	if #config.httpRedirect.parentRef != _|_ {
		{
			name: #config.httpRedirect.parentRef.name
			if #config.httpRedirect.parentRef.namespace != _|_ {
				namespace: #config.httpRedirect.parentRef.namespace
			}
			sectionName: "http"
		}
	},
]

#components: {
	"gateway": {
		gw_resources.#Gateway
		spec: gateway: {
			// Annotation injection: only when using raw listeners (no entrypoints) with issuerRef.
			if #config.gateway.entrypoints == _|_ if #config.gateway.issuerRef != _|_ {
				metadata: annotations: {
					if #config.gateway.issuerRef.kind == "ClusterIssuer" {
						"cert-manager.io/cluster-issuer": #config.gateway.issuerRef.name
					}
					if #config.gateway.issuerRef.kind == "Issuer" {
						"cert-manager.io/issuer": #config.gateway.issuerRef.name
					}
				}
			}
			spec: {
				gatewayClassName: #config.gateway.gatewayClassName
				listeners:        _allListeners
				if #config.gateway.infrastructure != _|_ {infrastructure: #config.gateway.infrastructure}
			}
		}
	}

	// Certificate CRs — one per TLS-enabled entrypoint.
	if #config.gateway.entrypoints != _|_ {
		for name, ep in #config.gateway.entrypoints if ep.tls {
			"cert-\(name)": {
				cm_security.#Certificate
				spec: certificate: {
					secretName: "gateway-\(name)-tls"
					dnsNames:   ep.hostnames
					issuerRef:  #config.gateway.issuerRef
				}
			}
		}
	}

	// HTTP→HTTPS redirect — targets all entrypoint HTTP listeners.
	if #config.httpRedirect.enabled {
		"https-redirect": {
			gw_resources.#HttpRoute
			metadata: name: "https-redirect"
			spec: httpRoute: {
				metadata: name: "http-to-https-redirect"
				spec: {
					parentRefs: list.Concat([_httpParentRefs, _explicitParentRefs])
					rules: [{
						filters: [{
							type: "RequestRedirect"
							requestRedirect: {
								scheme:     "https"
								statusCode: 301
							}
						}]
					}]
				}
			}
		}
	}
}
