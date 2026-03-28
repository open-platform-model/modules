// Package k8up defines the K8up backup operator module.
// A single-container stateless operator for Kubernetes-native backup management:
// - module.cue:    metadata and config schema
// - components.cue: component definitions (placeholder, Phase 3)
// - crds_data.cue: K8up CRD definitions (v2.14.0)
package k8up

import (
	m "opmodel.dev/core/v1alpha1/module@v1"
	schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)

// Module definition
m.#Module

// Module metadata
metadata: {
	modulePath:       "opmodel.dev/modules"
	name:             "k8up"
	version:          "0.1.0"
	description:      "K8up - Kubernetes backup operator based on Restic"
	defaultNamespace: "k8up-system"
}

// #config defines the configuration schema for the K8up operator module.
#config: {
	// Container image
	image: schemas.#Image & {
		repository: *"ghcr.io/k8up-io/k8up" | string
		tag:        *"v2.14.0" | string
		digest:     *"" | string
	}

	// Target namespace
	namespace: *"k8up-system" | string

	// Number of operator replicas
	replicas: *1 | int

	// Container timezone (empty = use node default)
	timezone: *"" | string

	// Enable leader election — required for replicas > 1
	enableLeaderElection: *true | bool

	// Skip backup resources that lack the k8up annotation
	skipWithoutAnnotation: *false | bool

	// Namespace the operator watches; empty means cluster-wide
	operatorNamespace: *"" | string

	// Global default resource requests/limits applied to all spawned backup jobs
	globalResources: {
		requests: {
			cpu:    *"" | string
			memory: *"" | string
		}
		limits: {
			cpu:    *"" | string
			memory: *"" | string
		}
	}

	// Resource requests and limits for the operator container itself
	resources: schemas.#ResourceRequirementsSchema & _ | *{
		requests: {
			cpu:    *"20m" | string
			memory: *"128Mi" | string
		}
		limits: {
			cpu:    *"500m" | string
			memory: *"256Mi" | string
		}
	}

	// Kubernetes ServiceAccount configuration
	serviceAccount: {
		create: *true | bool
		name:   *"" | string
		annotations: *{} | {[string]: string}
	}

	// Extra environment variables injected into the operator container
	envVars: *[] | [...]

	// Metrics and observability configuration
	metrics: {
		// Port the operator exposes metrics on
		port:        *8080 | int
		serviceType: *"ClusterIP" | string

		// Prometheus ServiceMonitor configuration
		serviceMonitor: {
			enabled:        *false | bool
			scrapeInterval: *"60s" | string
			namespace:      *"" | string
			additionalLabels: *{} | {[string]: string}
		}

		// Prometheus alerting rules configuration
		prometheusRule: {
			enabled:   *false | bool
			namespace: *"" | string
			additionalLabels: *{} | {[string]: string}
			createDefaultRules: *true | bool
			// Job types for which "job failed" alert rules are created
			jobFailedRulesFor: *["archive", "backup", "check", "prune", "restore"] | [...string]
		}

		// Grafana dashboard ConfigMap configuration
		grafanaDashboard: {
			enabled:   *false | bool
			namespace: *"" | string
			additionalLabels: *{} | {[string]: string}
		}
	}
}

debugValues: {
	image: {
		repository: "ghcr.io/k8up-io/k8up"
		tag:        "v2.14.0"
		digest:     ""
	}
	namespace:             "k8up-system"
	replicas:              1
	timezone:              ""
	enableLeaderElection:  true
	skipWithoutAnnotation: false
	operatorNamespace:     ""
	globalResources: {
		requests: {
			cpu:    ""
			memory: ""
		}
		limits: {
			cpu:    ""
			memory: ""
		}
	}
	resources: {
		requests: {
			cpu:    "20m"
			memory: "128Mi"
		}
		limits: {
			cpu:    "500m"
			memory: "256Mi"
		}
	}
	serviceAccount: {
		create: true
		name:   ""
		annotations: {}
	}
	envVars: []
	metrics: {
		port:        8080
		serviceType: "ClusterIP"
		serviceMonitor: {
			enabled:        false
			scrapeInterval: "60s"
			namespace:      ""
			additionalLabels: {}
		}
		prometheusRule: {
			enabled:   false
			namespace: ""
			additionalLabels: {}
			createDefaultRules: true
			jobFailedRulesFor: ["archive", "backup", "check", "prune", "restore"]
		}
		grafanaDashboard: {
			enabled:   false
			namespace: ""
			additionalLabels: {}
		}
	}
}
