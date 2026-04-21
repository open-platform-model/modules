// Package clickstack composes ClickHouse ClickStack — the HyperDX observability UI
// backed by a ClickHouse cluster (telemetry storage), a MongoDB replica set
// (HyperDX metadata), and an OpenTelemetry Collector (ingestion).
//
// Prerequisites — these operators must be installed in the cluster before this
// module can reconcile the custom resources it emits:
//   - modules/mongodb_operator
//   - modules/clickhouse_operator
//   - modules/otel_collector
//   - modules/cert_manager (transitive requirement of otel_collector)
//
// This module deploys:
//   - HyperDX (Deployment, stateless) — UI at :3000, API at :8000, OpAMP at :4320
//   - MongoDBCommunity CR — replica set for HyperDX metadata
//   - ClickHouseInstallation CR — analytics database
//   - ClickHouseKeeperInstallation CR — coordination layer
//   - OpenTelemetryCollector CR — OTLP ingestion on :4317 (gRPC) + :4318 (HTTP)
//
// PVCs created by MongoDB and ClickHouse operators are retained on module
// uninstall — clean up manually if you want to reclaim storage.
package clickstack

import (
	m "opmodel.dev/core/v1alpha1/module@v1"
	schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)

m.#Module

metadata: {
	modulePath:       "opmodel.dev/modules"
	name:             "clickstack"
	version:          "0.1.0"
	description:      "ClickHouse ClickStack — HyperDX observability UI + ClickHouse + MongoDB + OTEL collector"
	defaultNamespace: "clickstack"
	labels: {
		"app.kubernetes.io/component": "observability"
	}
}

#config: {
	// ModuleRelease name — MUST match metadata.name in the release.cue. Used
	// internally to construct cross-component DNS names (operators emit
	// Services prefixed with the CR name, which is itself prefixed with the
	// release name). CUE cannot introspect the release name, so the user sets
	// it here.
	releaseName: string | *"clickstack"

	// HyperDX UI/API image.
	image: schemas.#Image & {
		repository: string | *"docker.hyperdx.io/hyperdx/hyperdx"
		tag:        string | *"2.23.0"
		digest:     string | *""
	}

	// Init image used by the MongoDB readiness check init container.
	initImage: schemas.#Image & {
		repository: string | *"busybox"
		tag:        string | *"1.37"
		digest:     string | *""
	}

	// HyperDX ports.
	ports: {
		app:   int & >0 & <=65535 | *3000
		api:   int & >0 & <=65535 | *8000
		opamp: int & >0 & <=65535 | *4320
	}

	// Public URL used by HyperDX for frontend absolute links (no trailing slash).
	frontendUrl: string | *"http://localhost:3000"

	// MongoDB replica set configuration.
	mongodb: {
		members: int & >=1 | *3
		version: string | *"6.0.5"
		// Storage request per member.
		storageSize: string | *"10Gi"
	}

	// ClickHouse cluster configuration.
	clickhouse: {
		// Number of shards; typically 1 for single-region deployments.
		shards: int & >=1 | *1
		// Replicas per shard.
		replicas: int & >=1 | *1
		// Data volume size per replica.
		storageSize: string | *"100Gi"
		// Native TCP port (ClickHouse server).
		nativePort: int | *9000
		// HTTP port.
		httpPort: int | *8123
	}

	// ClickHouse Keeper quorum for cluster coordination.
	keeper: {
		replicas:    int & >=1 | *3
		storageSize: string | *"5Gi"
	}

	// OpenTelemetry Collector — a single Deployment-mode collector accepts
	// OTLP gRPC (4317) and HTTP (4318) and forwards to ClickHouse.
	otel: {
		image: schemas.#Image & {
			repository: string | *"otel/opentelemetry-collector-contrib"
			tag:        string | *"0.112.0"
			digest:     string | *""
		}
		replicas: int & >=1 | *1
	}

	// HyperDX resource requirements.
	hyperdxResources?: schemas.#ResourceRequirementsSchema

	// Secrets — all password/API-key references resolve to a single Kubernetes Secret
	// (OPM auto-creates it) with four keys.
	mongodbPassword: schemas.#Secret & {
		$secretName:  "clickstack-secret"
		$dataKey:     "MONGODB_PASSWORD"
		$description: "MongoDB password for the hyperdx user"
	}
	clickhousePassword: schemas.#Secret & {
		$secretName:  "clickstack-secret"
		$dataKey:     "CLICKHOUSE_PASSWORD"
		$description: "ClickHouse password for the OTEL collector user"
	}
	clickhouseAppPassword: schemas.#Secret & {
		$secretName:  "clickstack-secret"
		$dataKey:     "CLICKHOUSE_APP_PASSWORD"
		$description: "ClickHouse password for the HyperDX app user"
	}
	hyperdxApiKey: schemas.#Secret & {
		$secretName:  "clickstack-secret"
		$dataKey:     "HYPERDX_API_KEY"
		$description: "HyperDX API key shared across collector and app"
	}
}

debugValues: {
	releaseName: "clickstack"
	image: {
		repository: "docker.hyperdx.io/hyperdx/hyperdx"
		tag:        "2.23.0"
		digest:     ""
	}
	initImage: {
		repository: "busybox"
		tag:        "1.37"
		digest:     ""
	}
	ports: {
		app:   3000
		api:   8000
		opamp: 4320
	}
	frontendUrl: "http://localhost:3000"
	mongodb: {
		members:     3
		version:     "6.0.5"
		storageSize: "10Gi"
	}
	clickhouse: {
		shards:      1
		replicas:    1
		storageSize: "100Gi"
		nativePort:  9000
		httpPort:    8123
	}
	keeper: {
		replicas:    3
		storageSize: "5Gi"
	}
	otel: {
		image: {
			repository: "otel/opentelemetry-collector-contrib"
			tag:        "0.112.0"
			digest:     ""
		}
		replicas: 1
	}
	hyperdxResources: {
		requests: {cpu: "200m", memory: "512Mi"}
		limits: {cpu: "1000m", memory: "2Gi"}
	}
	mongodbPassword: {value: "debug-mongo-password-please-change-32"}
	clickhousePassword: {value: "debug-clickhouse-password-please-change"}
	clickhouseAppPassword: {value: "debug-clickhouse-app-password-change-me"}
	hyperdxApiKey: {value: "debug-hyperdx-api-key-please-change-32chars"}
}
