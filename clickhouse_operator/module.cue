// Package clickhouse_operator deploys the Altinity ClickHouse operator.
//
// Installs the controller Deployment with the `clickhouse-operator` and
// `metrics-exporter` containers, a ServiceAccount, and the ClusterRole
// required to manage ClickHouseInstallation, ClickHouseInstallationTemplate,
// ClickHouseKeeperInstallation, and ClickHouseOperatorConfiguration CRDs.
package clickhouse_operator

import (
	m "opmodel.dev/core/v1alpha1/module@v1"
	schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)

m.#Module

metadata: {
	modulePath:       "opmodel.dev/modules"
	name:             "clickhouse-operator"
	version:          "0.1.0"
	description:      "Altinity ClickHouse operator — controller + 4 CRDs (CHI, CHIT, CHK, CHOP)"
	defaultNamespace: "clickhouse-system"
	labels: {
		"app.kubernetes.io/component": "database-operator"
	}
}

#config: {
	// Main operator image.
	image: schemas.#Image & {
		repository: string | *"altinity/clickhouse-operator"
		tag:        string | *"0.26.3"
		digest:     string | *""
	}

	// Metrics exporter sidecar image (ships alongside the operator).
	metricsImage: schemas.#Image & {
		repository: string | *"altinity/metrics-exporter"
		tag:        string | *"0.26.3"
		digest:     string | *""
	}

	// Controller replicas.
	replicas: int & >=1 | *1

	// Metrics HTTP port exposed by the metrics-exporter sidecar.
	metricsPort: int & >0 & <=65535 | *8888

	// Resource requests/limits for the main operator container.
	resources?: schemas.#ResourceRequirementsSchema

	// Resource requests/limits for the metrics-exporter sidecar.
	metricsResources?: schemas.#ResourceRequirementsSchema

	// Comma-separated list (or single regexp) passed to the operator via
	// WATCH_NAMESPACES env. Default ".*" watches every namespace; override
	// to a narrower list (e.g. "clickstack,team-a") to scope the operator.
	watchNamespaces: string | *".*"
}

debugValues: {
	image: {
		repository: "altinity/clickhouse-operator"
		tag:        "0.26.3"
		digest:     ""
	}
	metricsImage: {
		repository: "altinity/metrics-exporter"
		tag:        "0.26.3"
		digest:     ""
	}
	replicas:    1
	metricsPort: 8888
	resources: {
		requests: {cpu: "100m", memory: "128Mi"}
		limits: {cpu: "500m", memory: "512Mi"}
	}
	metricsResources: {
		requests: {cpu: "50m", memory: "64Mi"}
		limits: {cpu: "200m", memory: "256Mi"}
	}
	watchNamespaces: ".*"
}
