// Package otel_collector deploys the OpenTelemetry operator.
//
// Installs the controller Deployment and the three OpenTelemetry CRDs
// (OpenTelemetryCollector, Instrumentation, OpAMPBridge). The controller
// reconciles Collector pods, manages sidecar injection for auto-instrumentation,
// and brokers OpAMP control plane connections.
//
// Prerequisite: cert-manager must be installed in the cluster. The operator's
// admission webhooks require TLS certs that cert-manager provisions. Install
// `modules/cert_manager` separately before applying this module.
package otel_collector

import (
	m "opmodel.dev/core/v1alpha1/module@v1"
	schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)

m.#Module

metadata: {
	modulePath:       "opmodel.dev/modules"
	name:             "otel-collector"
	version:          "0.1.0"
	description:      "OpenTelemetry operator — controller + OpenTelemetryCollector/Instrumentation/OpAMPBridge CRDs"
	defaultNamespace: "opentelemetry-operator-system"
	labels: {
		"app.kubernetes.io/component": "telemetry-operator"
	}
}

#config: {
	// Controller image.
	image: schemas.#Image & {
		repository: string | *"ghcr.io/open-telemetry/opentelemetry-operator/opentelemetry-operator"
		tag:        string | *"0.126.0"
		digest:     string | *""
	}

	// Controller replicas.
	replicas: int & >=1 | *1

	// Log level passed as --zap-log-level.
	logLevel: "debug" | "info" | "warn" | "error" | *"info"

	// Enable the nginx auto-instrumentation image path.
	enableNginxAutoInstrumentation: bool | *true

	// Enable admission webhooks (requires cert-manager-provisioned TLS cert at
	// /tmp/k8s-webhook-server/serving-certs/tls.crt). Set to false to run the
	// operator in "unsupported mode" — skips CR defaulting + validation, but
	// removes the cert-manager dependency. OPM-declared CRs are already
	// validated at CUE compile time, so this is safe for OPM-managed workflows.
	enableWebhooks: bool | *false

	// Metrics / HTTPS port exposed by the controller.
	metricsPort: int & >0 & <=65535 | *8443

	// Healthz / readyz probe port.
	probePort: int & >0 & <=65535 | *8081

	// Resource requests and limits.
	resources?: schemas.#ResourceRequirementsSchema
}

debugValues: {
	image: {
		repository: "ghcr.io/open-telemetry/opentelemetry-operator/opentelemetry-operator"
		tag:        "0.126.0"
		digest:     ""
	}
	replicas:                       1
	logLevel:                       "info"
	enableNginxAutoInstrumentation: true
	enableWebhooks:                 false
	metricsPort:                    8443
	probePort:                      8081
	resources: {
		requests: {cpu: "100m", memory: "64Mi"}
		limits: {cpu: "500m", memory: "256Mi"}
	}
}
