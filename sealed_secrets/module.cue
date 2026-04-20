// Package sealed_secrets defines the Bitnami sealed-secrets controller module.
//
// sealed-secrets asymmetrically encrypts Kubernetes Secrets at rest in git and
// decrypts them in-cluster via a controller holding the private key. The
// controller auto-generates its key pair on first start and rotates it on
// --key-renew-period. Keys are stored as K8s Secrets labelled
// sealedsecrets.bitnami.com/sealed-secrets-key=active in the controller namespace.
//
// Upstream: https://github.com/bitnami-labs/sealed-secrets
// Tracks: v0.36.6 (latest stable as of April 2026)
package sealed_secrets

import (
	m "opmodel.dev/core/v1alpha1/module@v1"
	schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)

m.#Module

META=metadata: {
	modulePath:       "opmodel.dev/modules"
	name:             "sealed-secrets"
	version:          "0.1.0"
	description:      "Bitnami sealed-secrets controller — encrypts Kubernetes Secrets for git-ops safe storage, decrypts in-cluster"
	defaultNamespace: "sealed-secrets"
	labels: {
		"app.kubernetes.io/component": "secret-management"
	}
}

// _#portSchema constrains any port field to a valid TCP/UDP port number.
_#portSchema: uint & >0 & <=65535

// _#durationSchema loosely validates Go duration strings (e.g. "720h", "30m").
// The controller parses these with time.ParseDuration — invalid values crash-loop.
_#durationSchema: string & =~"^[0-9]+(ns|us|µs|ms|s|m|h)([0-9]+(ns|us|µs|ms|s|m|h))*$"

// _serviceMonitorManifest — full monitoring.coreos.com/v1 ServiceMonitor.
// Targets the metrics port on the controller Service. The selector relies
// on the standard OPM label `app.kubernetes.io/name: sealed-secrets` applied
// by the KubernetesProvider to every resource emitted by this module.
_serviceMonitorManifest: {
	apiVersion: "monitoring.coreos.com/v1"
	kind:       "ServiceMonitor"
	metadata: {
		name: "sealed-secrets-controller"
		if #config.monitoring.namespace != "" {
			namespace: #config.monitoring.namespace
		}
		labels: #config.monitoring.additionalLabels
	}
	spec: {
		endpoints: [{
			port:     "metrics"
			interval: #config.monitoring.scrapeInterval
			path:     "/metrics"
		}]
		selector: matchLabels: "app.kubernetes.io/name": "sealed-secrets"
		namespaceSelector: matchNames: [META.defaultNamespace]
	}
}

#config: {
	// Image configuration for the controller binary.
	// Upstream publishes docker.io/bitnami/sealed-secrets-controller.
	image: schemas.#Image & {
		repository: string | *"docker.io/bitnami/sealed-secrets-controller"
		// Note: upstream image tags drop the leading "v" (tag "0.36.6", release "v0.36.6").
		tag:    string | *"0.36.6"
		digest: string | *""
	}

	// Controller runtime configuration.
	controller: {
		// Number of controller replicas.
		// WARNING: upstream does not currently support HA (no leader election
		// by default). Keep replicas=1 unless highAvailability.enabled is true
		// and you've verified your upstream version ships leader-election.
		replicas: int & >=1 | *1

		// Log verbosity — maps to --log-level.
		logLevel: *"info" | "debug" | "warn" | "error"

		// Log output format — maps to --log-format.
		logFormat: *"json" | "text"

		// Key rotation period — maps to --key-renew-period.
		// "720h" = 30 days. Set to "0" to disable automatic rotation.
		keyRenewPeriod: _#durationSchema | *"720h"

		// Certificate TTL for new signing keys — maps to --key-ttl.
		// "87600h" = 10 years. Longer than keyRenewPeriod so decryption keeps
		// working for secrets sealed against prior keys.
		keyTTL: _#durationSchema | *"87600h"

		// Prefix for key Secret objects — maps to --key-prefix.
		// Keys are stored as <keyPrefix>-<timestamp> in the controller namespace.
		keyPrefix: string | *"sealed-secrets-key"

		// Emergency key cutoff — RFC3339 timestamp passed as --key-cutoff-time.
		// Forces rotation of any key older than this timestamp on next reconcile.
		keyCutoffTime?: string & =~"^[0-9]{4}-[0-9]{2}-[0-9]{2}T"

		// Extra namespaces to watch — maps to --additional-namespaces.
		// Only needed when the controller runs outside kube-system AND must
		// decrypt SealedSecrets in namespaces it does not otherwise see.
		additionalNamespaces?: [...string]

		// Write SealedSecret.status conditions — maps to --update-status.
		// Required for kubectl/dashboards to surface unseal errors.
		updateStatus: bool | *true

		// Reconcile when managed Secrets are externally modified —
		// maps to --watch-for-secrets.
		watchForSecrets: bool | *false

		// Unseal retry count on transient errors — maps to --max-unseal-retries.
		maxUnsealRetries: int & >=0 | *3

		// Kubernetes client QPS / burst limits — passed as --kubeclient-qps /
		// --kubeclient-burst. Increase on large clusters where the controller
		// throttles against apiserver.
		kubeclientQPS:   int & >0 | *20
		kubeclientBurst: int & >0 | *30

		// Container resource requests and limits.
		resources?: schemas.#ResourceRequirementsSchema
	}

	// Service ports.
	// Port 8080 (http) carries the kubeseal CLI API and /healthz.
	// Port 8081 (metrics) exposes Prometheus metrics at /metrics.
	service: {
		httpPort:    _#portSchema | *8080
		metricsPort: _#portSchema | *8081
	}

	// Prometheus Operator integration (optional).
	// Manifests are emitted as ConfigMap-wrapped JSON because the OPM catalog
	// does not model monitoring.coreos.com CRDs directly — deployment tooling
	// extracts and kubectl-applies them when the operator is installed.
	monitoring: {
		enabled:        bool | *false
		scrapeInterval: _#durationSchema | *"30s"
		// Namespace where the ServiceMonitor object is created. Empty defaults
		// to the controller namespace.
		namespace: string | *""
		// Extra labels applied to the ServiceMonitor — used by Prometheus
		// Operator installations that select via matchLabels.
		additionalLabels: {[string]: string} | *{}
	}

	// Experimental HA mode. Off by default — upstream single-replica is the
	// supported path as of v0.36.6. Flipping this on emits leader-election
	// flags, lease RBAC, and a PDB; does NOT patch the upstream binary.
	highAvailability: {
		enabled:         bool | *false
		leaseName:       string | *"sealed-secrets-controller"
		pdbMinAvailable: int & >=1 | *1
	}
}

// debugValues exercises every #config branch so `cue vet -c` catches
// constraint errors across the full schema surface.
debugValues: {
	image: {
		repository: "docker.io/bitnami/sealed-secrets-controller"
		tag:        "0.36.6"
		digest:     ""
		pullPolicy: "IfNotPresent"
	}
	controller: {
		replicas:       1
		logLevel:       "info"
		logFormat:      "json"
		keyRenewPeriod: "720h"
		keyTTL:         "87600h"
		keyPrefix:      "sealed-secrets-key"
		keyCutoffTime:  "2026-01-01T00:00:00Z"
		additionalNamespaces: ["apps", "platform"]
		updateStatus:     true
		watchForSecrets:  false
		maxUnsealRetries: 3
		kubeclientQPS:    20
		kubeclientBurst:  30
		resources: {
			requests: {cpu: "50m", memory: "64Mi"}
			limits: {cpu: "200m", memory: "256Mi"}
		}
	}
	service: {
		httpPort:    8080
		metricsPort: 8081
	}
	monitoring: {
		enabled:        true
		scrapeInterval: "30s"
		namespace:      ""
		additionalLabels: {
			"prometheus": "kube-prometheus"
		}
	}
	highAvailability: {
		enabled:         false
		leaseName:       "sealed-secrets-controller"
		pdbMinAvailable: 1
	}
}
