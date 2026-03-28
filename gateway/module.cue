package gateway

import (
	"list"
	"strings"
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
			allowedRoutes?: {
				// Kinds specifies the groups and kinds of Routes that are allowed
				// to bind
				// to this Gateway Listener. When unspecified or empty, the kinds
				// of Routes
				// selected are determined using the Listener protocol.
				//
				// A RouteGroupKind MUST correspond to kinds of Routes that are
				// compatible
				// with the application protocol specified in the Listener's
				// Protocol field.
				// If an implementation does not support or recognize this
				// resource type, it
				// MUST set the "ResolvedRefs" condition to False for this
				// Listener with the
				// "InvalidRouteKinds" reason.
				//
				// Support: Core
				kinds?: list.MaxItems(8) & [...{
					// Group is the group of the Route.
					group?: strings.MaxRunes(253) & {
						=~"^$|^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$"
					}

					// Kind is the kind of the Route.
					kind!: strings.MaxRunes(63) & strings.MinRunes(1) & {
						=~"^[a-zA-Z]([-a-zA-Z0-9]*[a-zA-Z0-9])?$"
					}
				}]

				// Namespaces indicates namespaces from which Routes may be
				// attached to this
				// Listener. This is restricted to the namespace of this Gateway
				// by default.
				//
				// Support: Core
				namespaces?: {
					// From indicates where Routes will be selected for this Gateway.
					// Possible
					// values are:
					//
					// * All: Routes in all namespaces may be used by this Gateway.
					// * Selector: Routes in namespaces selected by the selector may
					// be used by
					// this Gateway.
					// * Same: Only Routes in the same namespace may be used by this
					// Gateway.
					//
					// Support: Core
					from?: "All" | "Selector" | "Same"

					// Selector must be specified when From is set to "Selector". In
					// that case,
					// only Routes in Namespaces matching this Selector will be
					// selected by this
					// Gateway. This field is ignored for other values of "From".
					//
					// Support: Core
					selector?: {
						// matchExpressions is a list of label selector requirements. The
						// requirements are ANDed.
						matchExpressions?: [...{
							// key is the label key that the selector applies to.
							key!: string

							// operator represents a key's relationship to a set of values.
							// Valid operators are In, NotIn, Exists and DoesNotExist.
							operator!: string

							// values is an array of string values. If the operator is In or
							// NotIn,
							// the values array must be non-empty. If the operator is Exists
							// or DoesNotExist,
							// the values array must be empty. This array is replaced during a
							// strategic
							// merge patch.
							values?: [...string]
						}]

						// matchLabels is a map of {key,value} pairs. A single {key,value}
						// in the matchLabels
						// map is equivalent to an element of matchExpressions, whose key
						// field is "key", the
						// operator is "In", and the values array contains only "value".
						// The requirements are ANDed.
						matchLabels?: {
							[string]: string
						}
					}
				}
			}
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
			hostnames: ["example.com", "*.example.com"]
		}
		issuerRef: {name: "letsencrypt-prod", kind: "ClusterIssuer"}
	}
	httpRedirect: {
		enabled: true
	}
}
