// Package mongodb_operator deploys the MongoDB Community operator.
//
// The operator ships as part of the unified `mongodb/mongodb-kubernetes` repo;
// the `mongodb-community-operator/` subdirectory hosts the community-only
// codepath while the top-level `config/` directory ships the unified
// controller that watches MongoDBCommunity CRs via the `-watch-resource=mongodbcommunity` flag.
//
// This module installs the unified controller Deployment and scopes it to
// the MongoDBCommunity CRD only — suitable for consumers like ClickStack
// that need a replica-set metadata store without Ops Manager.
package mongodb_operator

import (
	m "opmodel.dev/core/v1alpha1/module@v1"
	schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)

m.#Module

metadata: {
	modulePath:       "opmodel.dev/modules"
	name:             "mongodb-operator"
	version:          "0.1.0"
	description:      "MongoDB Community operator — installs the controller and MongoDBCommunity CRD"
	defaultNamespace: "mongodb-system"
	labels: {
		"app.kubernetes.io/component": "database-operator"
	}
}

#config: {
	// Controller image — the unified operator from mongodb/mongodb-kubernetes.
	image: schemas.#Image & {
		repository: string | *"quay.io/mongodb/mongodb-kubernetes"
		tag:        string | *"1.8.0"
		digest:     string | *""
	}

	// Companion images (agent, init) exposed as env vars to the controller.
	// Bumping these independently of the controller image is rare; defaults track the
	// upstream chart for the same operator release.
	agentImage: schemas.#Image & {
		repository: string | *"quay.io/mongodb/mongodb-agent"
		tag:        string | *"108.0.12.8846-1"
		digest:     string | *""
	}
	versionUpgradeHookImage: schemas.#Image & {
		repository: string | *"quay.io/mongodb/mongodb-kubernetes-operator-version-upgrade-post-start-hook"
		tag:        string | *"1.0.10"
		digest:     string | *""
	}
	readinessProbeImage: schemas.#Image & {
		repository: string | *"quay.io/mongodb/mongodb-kubernetes-readinessprobe"
		tag:        string | *"1.0.24"
		digest:     string | *""
	}
	mongodbImage: string | *"mongodb-community-server"
	mongodbRepo:  string | *"quay.io/mongodb"

	// Controller replicas (leader election handles failover).
	replicas: int & >=1 | *1

	// Namespace scope. Empty string watches all namespaces.
	watchNamespace: string | *""

	// Resource requests and limits.
	resources?: schemas.#ResourceRequirementsSchema
}

debugValues: {
	image: {
		repository: "quay.io/mongodb/mongodb-kubernetes"
		tag:        "1.8.0"
		digest:     ""
	}
	agentImage: {
		repository: "quay.io/mongodb/mongodb-agent"
		tag:        "108.0.12.8846-1"
		digest:     ""
	}
	versionUpgradeHookImage: {
		repository: "quay.io/mongodb/mongodb-kubernetes-operator-version-upgrade-post-start-hook"
		tag:        "1.0.10"
		digest:     ""
	}
	readinessProbeImage: {
		repository: "quay.io/mongodb/mongodb-kubernetes-readinessprobe"
		tag:        "1.0.24"
		digest:     ""
	}
	mongodbImage:   "mongodb-community-server"
	mongodbRepo:    "quay.io/mongodb"
	replicas:       1
	watchNamespace: ""
	resources: {
		requests: {cpu: "500m", memory: "200Mi"}
		limits: {cpu: "1100m", memory: "1Gi"}
	}
}
