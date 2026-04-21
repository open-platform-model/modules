// MongoDB Community CRD definitions.
// Simplified schema using x-kubernetes-preserve-unknown-fields — field-level
// validation is provided authoring-side by the catalog/mongodb_operator timoni types.
// Names, scope, short names, and subresources are taken verbatim from the upstream CRD.
package mongodb_operator

#crd_mongodbcommunity: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: name: "mongodbcommunity.mongodbcommunity.mongodb.com"
	spec: {
		group: "mongodbcommunity.mongodb.com"
		names: {
			kind:     "MongoDBCommunity"
			listKind: "MongoDBCommunityList"
			plural:   "mongodbcommunity"
			singular: "mongodbcommunity"
			shortNames: ["mdbc"]
		}
		scope: "Namespaced"
		versions: [{
			name: "v1"
			additionalPrinterColumns: [
				{jsonPath: ".status.phase", name: "Phase", type: "string"},
				{jsonPath: ".status.version", name: "Version", type: "string"},
			]
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

// Stub CRDs for resource types the unified operator tries to watch but this
// module doesn't actively manage (OpsManager, Enterprise MongoDB, Search, etc).
// The MongoDB Kubernetes operator (v1.8+, unified repo) starts informers for
// all known kinds at boot regardless of the `-watch-resource` flag; without the
// CRDs installed the informers fail to sync and reconciliation stalls.
// The CRDs below are minimal stubs (preserve-unknown-fields) — the operator
// won't create or modify these resources, it just needs the kinds registered.
#_stubCRDSpec: {
	_in: {
		kind:     string
		plural:   string
		singular: string
		group:    string
		scope:    "Namespaced" | "Cluster"
	}

	group: _in.group
	scope: _in.scope
	names: {
		kind:     _in.kind
		plural:   _in.plural
		singular: _in.singular
		listKind: "\(_in.kind)List"
	}
	versions: [{
		name: "v1"
		schema: openAPIV3Schema: {
			type:                                   "object"
			"x-kubernetes-preserve-unknown-fields": true
		}
		served:  true
		storage: true
		subresources: status: {}
	}]
}

_stubs: {
	"mongodb.mongodb.com": {
		kind:     "MongoDB"
		plural:   "mongodb"
		singular: "mongodb"
		group:    "mongodb.com"
		scope:    "Namespaced"
	}
	"opsmanagers.mongodb.com": {
		kind:     "MongoDBOpsManager"
		plural:   "opsmanagers"
		singular: "opsmanager"
		group:    "mongodb.com"
		scope:    "Namespaced"
	}
	"mongodbusers.mongodb.com": {
		kind:     "MongoDBUser"
		plural:   "mongodbusers"
		singular: "mongodbuser"
		group:    "mongodb.com"
		scope:    "Namespaced"
	}
	"mongodbmulticluster.mongodb.com": {
		kind:     "MongoDBMultiCluster"
		plural:   "mongodbmulticluster"
		singular: "mongodbmulticluster"
		group:    "mongodb.com"
		scope:    "Namespaced"
	}
	"mongodbsearch.mongodb.com": {
		kind:     "MongoDBSearch"
		plural:   "mongodbsearch"
		singular: "mongodbsearch"
		group:    "mongodb.com"
		scope:    "Namespaced"
	}
	"clustermongodbroles.mongodb.com": {
		kind:     "ClusterMongoDBRole"
		plural:   "clustermongodbroles"
		singular: "clustermongodbrole"
		group:    "mongodb.com"
		scope:    "Cluster"
	}
}

// #crds maps CRD name → definition for the components.cue CRD install loop.
#crds: {
	"mongodbcommunity.mongodbcommunity.mongodb.com": #crd_mongodbcommunity

	for crdName, s in _stubs {
		(crdName): {
			apiVersion: "apiextensions.k8s.io/v1"
			kind:       "CustomResourceDefinition"
			metadata: name: crdName
			spec: #_stubCRDSpec & {_in: s}
		}
	}
}
