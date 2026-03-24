// Kubernetes Metrics Server — cluster-wide resource usage metrics API.
// Deploys the metrics-server Deployment, Service Account, and RBAC.
// The Kubernetes APIService (v1beta1.metrics.k8s.io) must be applied separately
// until OPM catalog gains #APIService support.
//
// https://github.com/kubernetes-sigs/metrics-server
package metric_server

import (
	m       "opmodel.dev/core/v1alpha1/module@v1"
	schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)

m.#Module

metadata: {
	modulePath:       "opmodel.dev/modules"
	name:             "metrics-server"
	version:          "0.8.1"
	description:      "Kubernetes Metrics Server — provides cluster-wide resource usage API for kubectl top and Horizontal Pod Autoscaler"
	defaultNamespace: "kube-system"
	labels: {
		"app.kubernetes.io/component": "metrics"
	}
}

#config: {
	// Image configuration for the metrics-server container.
	image: {
		// Full image repository path including registry.
		// Override to use a private mirror, e.g. "my-mirror.io/metrics-server/metrics-server".
		repository: string | *"registry.k8s.io/metrics-server/metrics-server"
		// metrics-server release tag. See https://github.com/kubernetes-sigs/metrics-server/releases.
		tag: string | *"v0.8.1"
		// Image pull policy.
		pullPolicy: "Always" | *"IfNotPresent" | "Never"
	}

	// Number of metrics-server replicas.
	// Set to 2 with ha: true for high availability deployments.
	replicas: int & >=1 | *1

	// Enable high-availability mode.
	// When true: uses 2 replicas (override replicas) and pod anti-affinity to spread
	// across nodes. Set replicas >= 2 to take effect.
	ha: bool | *false

	// Skip TLS verification when scraping kubelet metrics endpoints.
	// Required for clusters with self-signed kubelet certificates (home labs, bare-metal).
	// Set false on clusters with properly CA-signed kubelet certificates.
	kubeletInsecureTLS: bool | *true

	// How frequently metrics-server scrapes each kubelet for resource usage data.
	// Increase to reduce CPU overhead on large clusters.
	metricResolution: string | *"15s"

	// Resource requests and limits for the metrics-server container.
	// Upstream defaults: requests cpu=100m, memory=200Mi.
	resources?: schemas.#ResourceRequirementsSchema
}

// debugValues exercises the full #config surface for local `cue vet`.
debugValues: {
	image: {
		repository: "registry.k8s.io/metrics-server/metrics-server"
		tag:        "v0.8.1"
		pullPolicy: "IfNotPresent"
	}
	replicas:           2
	ha:                 true
	kubeletInsecureTLS: true
	metricResolution:   "15s"
	resources: {
		requests: {
			cpu:    "100m"
			memory: "200Mi"
		}
		limits: {
			cpu:    "200m"
			memory: "256Mi"
		}
	}
}
