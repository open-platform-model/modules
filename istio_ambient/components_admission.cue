package istio_ambient

import (
	exp "opmodel.dev/catalogs/opm_experimental/resources"
)

/////////////////////////////////////////////////////////////////
//// Admission configuration
////
//// Three webhook configurations and, behind a flag, a CEL admission policy.
////
//// None of them carry a caBundle, deliberately — the C1 schema has no field
//// for one. istiod patches all three at runtime, finding them by exact name,
//// which is why the names are never prefixed.
////
//// failurePolicy differs by object and both values are load-bearing:
////   - the two validators are `Ignore`, so a control plane that is down
////     cannot block writes to unrelated Istio config;
////   - the injector is `Fail`, so a pod that should have been injected is
////     never silently admitted without its sidecar.
/////////////////////////////////////////////////////////////////

#components: {
	"validating-webhooks": {
		exp.#ValidatingWebhooks

		spec: validatingWebhooks: {
			"istiod-default-validator": {
				labels: {
					app:            "istiod"
					istio:          "istiod"
					"istio.io/rev": "default"
				}
				webhooks: [
					{
						name: "validation.istio.io"
						clientConfig: {
							service: {
								name:      "istiod"
								namespace: "istio-system"
								path:      "/validate"
							}
						}
						rules: [
							{
								operations: [
									"CREATE",
									"UPDATE",
								]
								apiGroups: [
									"security.istio.io",
									"networking.istio.io",
									"telemetry.istio.io",
									"extensions.istio.io",
								]
								apiVersions: [
									"*",
								]
								resources: [
									"*",
								]
							},
						]
						failurePolicy: "Ignore"
						sideEffects:   "None"
						admissionReviewVersions: [
							"v1",
						]
					},
				]
			}
			"istio-validator-\(#config.namespace.name)": {
				labels: {
					app:            "istiod"
					istio:          "istiod"
					"istio.io/rev": "default"
				}
				webhooks: [
					{
						name: "rev.validation.istio.io"
						clientConfig: {
							service: {
								name:      "istiod"
								namespace: "istio-system"
								path:      "/validate"
							}
						}
						rules: [
							{
								operations: [
									"CREATE",
									"UPDATE",
								]
								apiGroups: [
									"security.istio.io",
									"networking.istio.io",
									"telemetry.istio.io",
									"extensions.istio.io",
								]
								apiVersions: [
									"*",
								]
								resources: [
									"*",
								]
							},
						]
						failurePolicy: "Ignore"
						sideEffects:   "None"
						admissionReviewVersions: [
							"v1",
						]
						objectSelector: {
							matchExpressions: [
								{
									key:      "istio.io/rev"
									operator: "In"
									values: [
										"default",
									]
								},
							]
						}
					},
				]
			}
		}
	}

	"injector-webhook": {
		exp.#MutatingWebhooks

		spec: mutatingWebhooks: {
			"istio-sidecar-injector": {
				labels: {
					"istio.io/rev": "default"
					app:            "sidecar-injector"
				}
				webhooks: [
					{
						name: "rev.namespace.sidecar-injector.istio.io"
						clientConfig: {
							service: {
								name:      "istiod"
								namespace: "istio-system"
								path:      "/inject"
								port:      443
							}
						}
						sideEffects: "None"
						rules: [
							{
								operations: [
									"CREATE",
								]
								apiGroups: [
									"",
								]
								apiVersions: [
									"v1",
								]
								resources: [
									"pods",
								]
							},
						]
						failurePolicy: "Fail"
						admissionReviewVersions: [
							"v1",
						]
						namespaceSelector: {
							matchExpressions: [
								{
									key:      "istio.io/rev"
									operator: "In"
									values: [
										"default",
									]
								},
								{
									key:      "istio-injection"
									operator: "DoesNotExist"
								},
							]
						}
						objectSelector: {
							matchExpressions: [
								{
									key:      "sidecar.istio.io/inject"
									operator: "NotIn"
									values: [
										"false",
									]
								},
							]
						}
					},
					{
						name: "rev.object.sidecar-injector.istio.io"
						clientConfig: {
							service: {
								name:      "istiod"
								namespace: "istio-system"
								path:      "/inject"
								port:      443
							}
						}
						sideEffects: "None"
						rules: [
							{
								operations: [
									"CREATE",
								]
								apiGroups: [
									"",
								]
								apiVersions: [
									"v1",
								]
								resources: [
									"pods",
								]
							},
						]
						failurePolicy: "Fail"
						admissionReviewVersions: [
							"v1",
						]
						namespaceSelector: {
							matchExpressions: [
								{
									key:      "istio.io/rev"
									operator: "DoesNotExist"
								},
								{
									key:      "istio-injection"
									operator: "DoesNotExist"
								},
							]
						}
						objectSelector: {
							matchExpressions: [
								{
									key:      "sidecar.istio.io/inject"
									operator: "NotIn"
									values: [
										"false",
									]
								},
								{
									key:      "istio.io/rev"
									operator: "In"
									values: [
										"default",
									]
								},
							]
						}
					},
					{
						name: "namespace.sidecar-injector.istio.io"
						clientConfig: {
							service: {
								name:      "istiod"
								namespace: "istio-system"
								path:      "/inject"
								port:      443
							}
						}
						sideEffects: "None"
						rules: [
							{
								operations: [
									"CREATE",
								]
								apiGroups: [
									"",
								]
								apiVersions: [
									"v1",
								]
								resources: [
									"pods",
								]
							},
						]
						failurePolicy: "Fail"
						admissionReviewVersions: [
							"v1",
						]
						namespaceSelector: {
							matchExpressions: [
								{
									key:      "istio-injection"
									operator: "In"
									values: [
										"enabled",
									]
								},
							]
						}
						objectSelector: {
							matchExpressions: [
								{
									key:      "sidecar.istio.io/inject"
									operator: "NotIn"
									values: [
										"false",
									]
								},
							]
						}
					},
					{
						name: "object.sidecar-injector.istio.io"
						clientConfig: {
							service: {
								name:      "istiod"
								namespace: "istio-system"
								path:      "/inject"
								port:      443
							}
						}
						sideEffects: "None"
						rules: [
							{
								operations: [
									"CREATE",
								]
								apiGroups: [
									"",
								]
								apiVersions: [
									"v1",
								]
								resources: [
									"pods",
								]
							},
						]
						failurePolicy: "Fail"
						admissionReviewVersions: [
							"v1",
						]
						namespaceSelector: {
							matchExpressions: [
								{
									key:      "istio-injection"
									operator: "DoesNotExist"
								},
								{
									key:      "istio.io/rev"
									operator: "DoesNotExist"
								},
							]
						}
						objectSelector: {
							matchExpressions: [
								{
									key:      "sidecar.istio.io/inject"
									operator: "In"
									values: [
										"true",
									]
								},
								{
									key:      "istio.io/rev"
									operator: "DoesNotExist"
								},
							]
						}
					},
				]
			}
		}
	}
}
