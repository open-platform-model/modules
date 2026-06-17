// Vendored Piraeus CRDs (group piraeus.io) — pinned to piraeus-operator v2.10.7.
//
// Trimmed to names/scope/version with `x-kubernetes-preserve-unknown-fields:
// true` (the full upstream OpenAPI schemas are ~2,200 lines). Structural spec
// validation is enforced at runtime by the operator's ValidatingWebhook
// configuration (vlinstorcluster.kb.io et al.), so a permissive CRD schema is
// safe here — same approach as modules/k8up.
//
// To refresh on upgrade: pull the release manifest.yaml, re-extract the four
// CustomResourceDefinition metadata blocks (group/names/scope/version remain
// stable across v2.x), bump the version note above.
package linstor

#piraeus_io_linstorclusters: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: name: "linstorclusters.piraeus.io"
	spec: {
		group: "piraeus.io"
		names: {
			kind:     "LinstorCluster"
			listKind: "LinstorClusterList"
			plural:   "linstorclusters"
			singular: "linstorcluster"
		}
		scope: "Cluster"
		versions: [{
			name:    "v1"
			served:  true
			storage: true
			subresources: status: {}
			schema: openAPIV3Schema: {
				type:                                   "object"
				"x-kubernetes-preserve-unknown-fields": true
			}
		}]
	}
}

#piraeus_io_linstornodeconnections: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: name: "linstornodeconnections.piraeus.io"
	spec: {
		group: "piraeus.io"
		names: {
			kind:     "LinstorNodeConnection"
			listKind: "LinstorNodeConnectionList"
			plural:   "linstornodeconnections"
			singular: "linstornodeconnection"
		}
		scope: "Cluster"
		versions: [{
			name:    "v1"
			served:  true
			storage: true
			subresources: status: {}
			schema: openAPIV3Schema: {
				type:                                   "object"
				"x-kubernetes-preserve-unknown-fields": true
			}
		}]
	}
}

#piraeus_io_linstorsatelliteconfigurations: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: name: "linstorsatelliteconfigurations.piraeus.io"
	spec: {
		group: "piraeus.io"
		names: {
			kind:     "LinstorSatelliteConfiguration"
			listKind: "LinstorSatelliteConfigurationList"
			plural:   "linstorsatelliteconfigurations"
			singular: "linstorsatelliteconfiguration"
		}
		scope: "Cluster"
		versions: [{
			name:    "v1"
			served:  true
			storage: true
			subresources: status: {}
			schema: openAPIV3Schema: {
				type:                                   "object"
				"x-kubernetes-preserve-unknown-fields": true
			}
		}]
	}
}

#piraeus_io_linstorsatellites: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: name: "linstorsatellites.piraeus.io"
	spec: {
		group: "piraeus.io"
		names: {
			kind:     "LinstorSatellite"
			listKind: "LinstorSatelliteList"
			plural:   "linstorsatellites"
			singular: "linstorsatellite"
		}
		scope: "Cluster"
		versions: [{
			name:    "v1"
			served:  true
			storage: true
			subresources: status: {}
			schema: openAPIV3Schema: {
				type:                                   "object"
				"x-kubernetes-preserve-unknown-fields": true
			}
		}]
	}
}
