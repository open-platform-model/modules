package k8up

import (
	"encoding/json"

	resources_config "opmodel.dev/opm/v1alpha1/resources/config@v1"
)

_grafanaDashboard: {
	title:         "K8up"
	uid:           "k8up"
	schemaVersion: 30
	panels: [
		{
			id:    1
			title: "Active Schedules"
			type:  "stat"
			gridPos: {h: 4, w: 6, x: 0, y: 0}
			targets: [{expr: "k8up_schedules_gauge", legendFormat: "Schedules"}]
		},
		{
			id:    2
			title: "Total Jobs"
			type:  "stat"
			gridPos: {h: 4, w: 6, x: 6, y: 0}
			targets: [{expr: "sum(k8up_jobs_total)", legendFormat: "Total"}]
		},
		{
			id:    3
			title: "Successful Jobs"
			type:  "stat"
			gridPos: {h: 4, w: 6, x: 12, y: 0}
			targets: [{expr: "sum(k8up_jobs_successful_total)", legendFormat: "Successful"}]
		},
		{
			id:    4
			title: "Failed Jobs"
			type:  "stat"
			gridPos: {h: 4, w: 6, x: 18, y: 0}
			targets: [{expr: "sum(k8up_jobs_failed_total)", legendFormat: "Failed"}]
		},
		{
			id:    5
			title: "Restic Last Errors"
			type:  "timeseries"
			gridPos: {h: 8, w: 12, x: 0, y: 4}
			targets: [{expr: "k8up_backup_restic_last_errors", legendFormat: "{{namespace}}/{{schedule}}"}]
		},
		{
			id:    6
			title: "Available Snapshots"
			type:  "timeseries"
			gridPos: {h: 8, w: 12, x: 12, y: 4}
			targets: [{expr: "k8up_backup_snapshots_available", legendFormat: "{{namespace}}/{{schedule}}"}]
		},
	]
}

// _serviceMonitorManifest constructs the full ServiceMonitor object for K8up metrics.
// Stored in a ConfigMap for deployment tooling to apply when Prometheus Operator is
// installed. The OPM catalog (v1alpha1) does not natively support monitoring.coreos.com
// CRD instances, so the manifest is serialised to JSON and carried as ConfigMap data.
_serviceMonitorManifest: {
	apiVersion: "monitoring.coreos.com/v1"
	kind:       "ServiceMonitor"
	metadata: {
		name: "k8up"
		if #config.metrics.serviceMonitor.namespace != "" {
			namespace: #config.metrics.serviceMonitor.namespace
		}
		labels: #config.metrics.serviceMonitor.additionalLabels
	}
	spec: {
		endpoints: [{
			port:     "metrics"
			interval: #config.metrics.serviceMonitor.scrapeInterval
		}]
		selector: matchLabels: "app.kubernetes.io/name": "k8up"
		namespaceSelector: matchNames: [#config.namespace]
	}
}

// _jobFailedRules generates one Prometheus alerting rule per job type listed in
// prometheusRule.jobFailedRulesFor. Each rule fires when the failure counter is
// non-zero and uses a job_type label to identify the offending job kind.
_jobFailedRules: [for jobType in #config.metrics.prometheusRule.jobFailedRulesFor {
	{
		alert: "K8upJobFailed"
		expr:  "k8up_jobs_failed_total{jobType=\"\(jobType)\"} > 0"
		"for": "1m"
		labels: {severity: "warning", job_type: jobType}
		annotations: {
			summary:     "K8up \(jobType) job has failed"
			description: "The K8up \(jobType) job has failed in namespace {{ $labels.namespace }}."
		}
	}
}]

// _prometheusRuleManifest constructs the full PrometheusRule object for K8up alerting.
// Stored in a ConfigMap for deployment tooling to apply when Prometheus Operator is
// installed. The OPM catalog (v1alpha1) does not natively support monitoring.coreos.com
// CRD instances, so the manifest is serialised to JSON and carried as ConfigMap data.
_prometheusRuleManifest: {
	apiVersion: "monitoring.coreos.com/v1"
	kind:       "PrometheusRule"
	metadata: {
		name: "k8up"
		if #config.metrics.prometheusRule.namespace != "" {
			namespace: #config.metrics.prometheusRule.namespace
		}
		labels: #config.metrics.prometheusRule.additionalLabels
	}
	spec: groups: [if #config.metrics.prometheusRule.createDefaultRules {
		{
			name:  "k8up"
			rules: _jobFailedRules
		}
	}]
}

#components: {
	if #config.metrics.grafanaDashboard.enabled {
		grafanaDashboard: {
			resources_config.#ConfigMaps
			spec: configMaps: {
				"k8up-dashboard": {
					immutable: false
					data: {
						"k8up-dashboard.json": "\(json.Marshal(_grafanaDashboard))"
					}
				}
			}
		}
	}

	// ServiceMonitor manifest ConfigMap — applied by deployment tooling when
	// Prometheus Operator is present. Carries the full monitoring.coreos.com/v1
	// ServiceMonitor object as JSON so it can be extracted and kubectl-applied.
	if #config.metrics.serviceMonitor.enabled {
		serviceMonitor: {
			resources_config.#ConfigMaps
			spec: configMaps: {
				"k8up-service-monitor": {
					immutable: false
					data: {
						"servicemonitor.json": "\(json.Marshal(_serviceMonitorManifest))"
					}
				}
			}
		}
	}

	// PrometheusRule manifest ConfigMap — applied by deployment tooling when
	// Prometheus Operator is present. Carries the full monitoring.coreos.com/v1
	// PrometheusRule object as JSON so it can be extracted and kubectl-applied.
	if #config.metrics.prometheusRule.enabled {
		prometheusRule: {
			resources_config.#ConfigMaps
			spec: configMaps: {
				"k8up-prometheus-rule": {
					immutable: false
					data: {
						"prometheusrule.json": "\(json.Marshal(_prometheusRuleManifest))"
					}
				}
			}
		}
	}
}
