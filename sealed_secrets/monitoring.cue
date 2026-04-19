// Monitoring — optional Prometheus Operator integration for sealed-secrets.
//
// The OPM catalog (v1alpha1) does not model monitoring.coreos.com CRD
// instances directly, so the ServiceMonitor object is serialised to JSON and
// carried inside a ConfigMap. Deployment tooling (FluxCD Kustomization,
// ArgoCD, custom bootstrap) extracts the manifest and kubectl-applies it
// when the Prometheus Operator is installed.
//
// Metrics exposed by the controller (sealed_secrets_controller_*):
//   build_info             — controller version/revision (labels)
//   unseal_requests_total  — counter of all unseal attempts
//   unseal_errors_total    — counter with `reason` label: unseal, unmanaged,
//                            update, status, fetch
package sealed_secrets

import (
	"encoding/json"

	resources_config "opmodel.dev/opm/v1alpha1/resources/config@v1"
)

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
		namespaceSelector: matchNames: [metadata.defaultNamespace]
	}
}

#components: {
	// ServiceMonitor manifest carried as a ConfigMap — applied by deployment
	// tooling when Prometheus Operator is present. Only emitted when
	// monitoring.enabled is true so clusters without the CRD don't see a
	// spurious ConfigMap.
	if #config.monitoring.enabled {
		"service-monitor": {
			resources_config.#ConfigMaps
			spec: configMaps: {
				"sealed-secrets-service-monitor": {
					immutable: false
					data: {
						"servicemonitor.json": "\(json.Marshal(_serviceMonitorManifest))"
					}
				}
			}
		}
	}
}
