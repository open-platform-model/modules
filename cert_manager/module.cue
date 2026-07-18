// cert-manager — automated X.509 certificate management for Kubernetes.
// Deploys the cert-manager controller, webhook, and cainjector, all 6 CRDs,
// and the full RBAC stack (10 ClusterRoles + 3 namespace Roles) required by each component.
//
// https://cert-manager.io  |  https://github.com/cert-manager/cert-manager
package cert_manager

import (
	m "opmodel.dev/core/v1alpha1/module@v1"
	schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)

m.#Module

metadata: {
	modulePath:       "opmodel.dev/modules"
	name:             "cert-manager"
	version:          "0.1.0"
	description:      "cert-manager X.509 certificate manager for Kubernetes — deploys controller, webhook, cainjector, CRDs, and full RBAC"
	defaultNamespace: "cert-manager"
	labels: {
		"app.kubernetes.io/component": "certificate-management"
	}
}

#config: {
	// Image configuration — tag is shared across all cert-manager components.
	image: schemas.#Image & {
		// Registry + namespace holding the cert-manager images. The per-component image
		// name (cert-manager-controller, -webhook, -cainjector, -acmesolver) is appended
		// by components.cue. Override to pull from a mirror or private registry.
		repository: string | *"quay.io/jetstack"
		// cert-manager release tag (e.g., "v1.21.0"). See https://github.com/cert-manager/cert-manager/releases.
		// NOTE: crds_data.cue is generated from this release's cert-manager.crds.yaml —
		// regenerate it when bumping this tag, otherwise the CRDs and images drift apart.
		tag: string | *"v1.21.0"
		// Image digest for the container.
		digest: string | *""
	}

	// Controller configuration — handles certificate issuance, renewal, and CRD reconciliation.
	controller: {
		// Log verbosity level (1=minimal … 10=max). Passed as --v=N flag.
		logLevel: int & >=1 & <=10 | *2
		// Number of controller replicas.
		replicas: int & >=1 | *1
		// Resource requests and limits (optional — omit to use cluster defaults).
		resources?: schemas.#ResourceRequirementsSchema
	}

	// Webhook configuration — validates and mutates cert-manager resources via Kubernetes admission control.
	webhook: {
		// Log verbosity level (1=minimal … 10=max). Passed as --v=N flag.
		logLevel: int & >=1 & <=10 | *2
		// Number of webhook replicas.
		replicas: int & >=1 | *1
		// Secure port the webhook HTTPS server listens on (matches Helm chart default).
		securePort: int & >=1 & <=65535 | *10250
		// Resource requests and limits (optional — omit to use cluster defaults).
		resources?: schemas.#ResourceRequirementsSchema
	}

	// CAInjector configuration — patches caBundle into ValidatingWebhookConfiguration,
	// MutatingWebhookConfiguration, and CRD conversion webhook specs.
	cainjector: {
		// Log verbosity level (1=minimal … 10=max). Passed as --v=N flag.
		logLevel: int & >=1 & <=10 | *2
		// Number of cainjector replicas.
		replicas: int & >=1 | *1
		// Resource requests and limits (optional — omit to use cluster defaults).
		resources?: schemas.#ResourceRequirementsSchema
	}

	// Leader election configuration — namespace where controller and cainjector store leader election Leases.
	// IMPORTANT: OPM creates the leaderElection Role in the cert-manager namespace only.
	// Set this to "cert-manager" (same as defaultNamespace) to match the OPM-provisioned Role.
	// If set to "kube-system" (Helm chart default), manually create Role/RoleBinding in kube-system.
	leaderElection: {
		namespace: string | *"cert-manager"
	}
}

// debugValues exercises the full #config surface for local `cue vet` / `cue eval`.
debugValues: {
	image: {
		repository: "quay.io/jetstack"
		tag:        "v1.21.0"
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
