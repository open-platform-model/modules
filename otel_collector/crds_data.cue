// OpenTelemetry operator CRD definitions.
// Simplified schema using x-kubernetes-preserve-unknown-fields — authoring-side
// validation is provided by catalog/otel_collector timoni-generated types.
package otel_collector

#crd_opentelemetrycollectors: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: name: "opentelemetrycollectors.opentelemetry.io"
	spec: {
		group: "opentelemetry.io"
		names: {
			kind:     "OpenTelemetryCollector"
			listKind: "OpenTelemetryCollectorList"
			plural:   "opentelemetrycollectors"
			singular: "opentelemetrycollector"
			shortNames: ["otelcol", "otelcols"]
		}
		scope: "Namespaced"
		versions: [
			{
				name: "v1alpha1"
				additionalPrinterColumns: [
					{jsonPath: ".status.scale.statusReplicas", name: "Status", type: "string"},
					{jsonPath: ".status.version", name: "Version", type: "string"},
				]
				schema: openAPIV3Schema: {
					type:                                   "object"
					"x-kubernetes-preserve-unknown-fields": true
				}
				served:  true
				storage: false
				subresources: {
					status: {}
					scale: {
						specReplicasPath:   ".spec.replicas"
						statusReplicasPath: ".status.scale.replicas"
					}
				}
			},
			{
				name: "v1beta1"
				additionalPrinterColumns: [
					{jsonPath: ".status.scale.statusReplicas", name: "Status", type: "string"},
					{jsonPath: ".status.version", name: "Version", type: "string"},
				]
				schema: openAPIV3Schema: {
					type:                                   "object"
					"x-kubernetes-preserve-unknown-fields": true
				}
				served:  true
				storage: true
				subresources: {
					status: {}
					scale: {
						specReplicasPath:   ".spec.replicas"
						statusReplicasPath: ".status.scale.replicas"
					}
				}
			},
		]
	}
}

#crd_instrumentations: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: name: "instrumentations.opentelemetry.io"
	spec: {
		group: "opentelemetry.io"
		names: {
			kind:     "Instrumentation"
			listKind: "InstrumentationList"
			plural:   "instrumentations"
			singular: "instrumentation"
			shortNames: ["otelinst", "otelinsts"]
		}
		scope: "Namespaced"
		versions: [{
			name: "v1alpha1"
			schema: openAPIV3Schema: {
				type:                                   "object"
				"x-kubernetes-preserve-unknown-fields": true
			}
			served:  true
			storage: true
		}]
	}
}

#crd_opampbridges: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: name: "opampbridges.opentelemetry.io"
	spec: {
		group: "opentelemetry.io"
		names: {
			kind:     "OpAMPBridge"
			listKind: "OpAMPBridgeList"
			plural:   "opampbridges"
			singular: "opampbridge"
		}
		scope: "Namespaced"
		versions: [{
			name: "v1alpha1"
			schema: openAPIV3Schema: {
				type:                                   "object"
				"x-kubernetes-preserve-unknown-fields": true
			}
			served:  true
			storage: true
			subresources: status: {}
		}]
	}
}

#crds: {
	"opentelemetrycollectors.opentelemetry.io": #crd_opentelemetrycollectors
	"instrumentations.opentelemetry.io":        #crd_instrumentations
	"opampbridges.opentelemetry.io":            #crd_opampbridges
}
