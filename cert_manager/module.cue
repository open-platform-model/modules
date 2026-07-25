// cert-manager — automated X.509 certificate management for Kubernetes.
// Deploys the cert-manager controller, webhook, and cainjector, all 6 CRDs,
// the admission webhook configurations, the webhook Service, the full RBAC
// stack (10 bound ClusterRoles + 3 namespace Roles), and the cert-manager
// namespace:
// - module.cue:     metadata and config schema
// - components.cue: component definitions (catalog_opm blueprints/traits +
//                   catalog_opm_experimental #Namespaces / webhook resources)
// - crds_data.cue:  vendored upstream CRDs (generated from crds/*.yaml)
//
// https://cert-manager.io | https://github.com/cert-manager/cert-manager
// Pinned upstream release: v1.21.0. All object bodies (deployments, RBAC,
// webhook configurations) are transcribed from that release's static
// manifest (cert-manager.yaml), NOT from the legacy v0 module — the legacy
// webhook bodies had drifted from the chart.
//
// ⚠ Instance-name coupling: the webhook configurations' clientConfig points
// at Service `cert-manager-webhook` in namespace `cert-manager`, and the
// Service/Deployment names render as {instance}-{component}. Deploy this
// module as an instance named exactly `cert-manager` in namespace
// `cert-manager` so the rendered Service name matches.
package cert_manager

import (
	m "opmodel.dev/core@v1"
	res "opmodel.dev/catalogs/opm/resources"
)

m.#Module

metadata: {
	modulePath:  "opmodel.dev/modules"
	name:        "cert-manager"
	version:     "1.0.0"
	description: "cert-manager X.509 certificate manager for Kubernetes — deploys controller, webhook, cainjector, CRDs, webhook configurations, and full RBAC"
}

#config: {
	// Image configuration — tag is shared across all cert-manager components.
	image: res.#Image & {
		// Registry + namespace holding the cert-manager images. The per-component
		// image name (cert-manager-controller, -webhook, -cainjector, -acmesolver)
		// is appended by components.cue. Override to pull from a mirror.
		repository: string | *"quay.io/jetstack"
		// cert-manager release tag. See https://github.com/cert-manager/cert-manager/releases.
		// NOTE: crds_data.cue and the webhook configuration bodies are generated
		// from this release's manifest — re-vendor when bumping this tag.
		tag:    string | *"v1.21.0"
		digest: string | *""
	}

	// Controller configuration — certificate issuance, renewal, and CRD reconciliation.
	controller: {
		// Log verbosity level (1=minimal … 10=max). Passed as --v=N flag.
		logLevel: int & >=1 & <=10 | *2
		// Number of controller replicas.
		replicas: int & >=1 | *1
		// Resource requests and limits (optional — omit to use cluster defaults).
		resources?: res.#ResourceRequirementsSchema
	}

	// Webhook configuration — validates and mutates cert-manager resources via
	// Kubernetes admission control. Manages its own serving cert (dynamic
	// serving) in the cert-manager-webhook-ca Secret.
	webhook: {
		// Log verbosity level (1=minimal … 10=max). Passed as --v=N flag.
		logLevel: int & >=1 & <=10 | *2
		// Number of webhook replicas.
		replicas: int & >=1 | *1
		// Secure port the webhook HTTPS server listens on (Helm chart default).
		securePort: int & >=1 & <=65535 | *10250
		// Resource requests and limits (optional — omit to use cluster defaults).
		resources?: res.#ResourceRequirementsSchema
	}

	// CAInjector configuration — patches caBundle into webhook configurations
	// and CRD conversion webhook specs.
	cainjector: {
		// Log verbosity level (1=minimal … 10=max). Passed as --v=N flag.
		logLevel: int & >=1 & <=10 | *2
		// Number of cainjector replicas.
		replicas: int & >=1 | *1
		// Resource requests and limits (optional — omit to use cluster defaults).
		resources?: res.#ResourceRequirementsSchema
	}

	// Leader election configuration — namespace where controller and cainjector
	// store leader election Leases.
	// IMPORTANT: OPM creates the leaderelection Roles in the module instance's
	// namespace only. Keep this at "cert-manager" to match the OPM-provisioned
	// Roles (the Helm chart's "kube-system" default is intentionally not used).
	leaderElection: {
		namespace: string | *"cert-manager"
	}
}

// debugValues exercises the full #config surface for local `cue vet` / `cue eval`.
debugValues: {
	image: {
		repository: "quay.io/jetstack"
		tag:        "v1.21.0"
		digest:     ""
		pullPolicy: "IfNotPresent"
	}
	controller: {
		logLevel: 2
		replicas: 1
		resources: {
			requests: {cpu: "10m", memory: "32Mi"}
			limits: {cpu: "100m", memory: "128Mi"}
		}
	}
	webhook: {
		logLevel:   2
		replicas:   1
		securePort: 10250
		resources: {
			requests: {cpu: "10m", memory: "32Mi"}
			limits: {cpu: "100m", memory: "128Mi"}
		}
	}
	cainjector: {
		logLevel: 2
		replicas: 1
		resources: {
			requests: {cpu: "10m", memory: "32Mi"}
			limits: {cpu: "100m", memory: "128Mi"}
		}
	}
	leaderElection: {
		namespace: "cert-manager"
	}
}
