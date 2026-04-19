// Package ch_vmm defines the ch-vmm module — a lightweight Kubernetes add-on
// for running Cloud Hypervisor virtual machines.
//
// Upstream: https://github.com/nalajala4naresh/ch-vmm (v1.4.0)
//
// Layout:
//   module.cue     — metadata and #config schema
//   components.cue — Deployment, DaemonSet, RBAC, webhooks, cert-manager Issuer/Certificate
//   crds_data.cue  — 9 CRDs (virtualdisks, virtualdisksnapshots, virtualmachinemigrations,
//                    virtualmachines, vmpools, vmrestorespecs, vmrollbacks, vmsets, vmsnapshots)
//
// Prerequisites (must be installed separately):
//   - cert-manager        (used to issue webhook and daemon TLS certs)
//   - snapshot-controller (for VolumeSnapshot integration — optional but RBAC grants access)
//   - CDI operator        (for DataVolume integration — optional but RBAC grants access)
//   - Nodes with /dev/kvm, IOMMU enabled, Cloud Hypervisor capable kernel (>= 4.11)
//
// See DEPLOYMENT_NOTES.md for known gaps (mountPropagation, headless service, metrics NetworkPolicies).
package ch_vmm

import (
	m "opmodel.dev/core/v1alpha1/module@v1"
	schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)

m.#Module

metadata: {
	modulePath:       "opmodel.dev/modules"
	name:             "ch-vmm"
	version:          "0.1.0"
	description:      "ch-vmm — Cloud Hypervisor virtualization add-on for Kubernetes (controller + per-node daemon + CRDs)"
	defaultNamespace: "ch-vmm-system"
	labels: {
		"app.kubernetes.io/name": "ch-vmm"
	}
}

_#portSchema: uint & >0 & <=65535

#config: {
	// Controller Deployment image — virtmanager-controller-manager.
	controllerImage: schemas.#Image & {
		repository: string | *"nalajalanaresh/ch-vmm-controller"
		tag:        string | *"v1.4.0"
		digest:     string | *"sha256:69fbbed29e7a1bc3d6bdae0d87e8ce520c01e7f19b94e024143e7b6e009480dc"
	}

	// Per-node DaemonSet image — ch-vmm-daemon.
	daemonImage: schemas.#Image & {
		repository: string | *"nalajalanaresh/ch-vmm-daemon"
		tag:        string | *"v1.4.0"
		digest:     string | *"sha256:46000a92081e3ebaf9733923998fafb167a3d53169a06ec0be9e682ac00f8b9b"
	}

	// Target namespace. Must match `metadata.defaultNamespace` when the module is
	// deployed via OPM — referenced by cert DNS names and webhook clientConfig.
	namespace: string | *"ch-vmm-system"

	// Controller configuration.
	controller: {
		// Replica count. Leader election gates active replica when > 1.
		replicas: int & >=1 | *1

		// Secret name containing registry pull credentials for VM base images.
		// Passed to the controller via REGISTRY_CREDS_SECRET env var.
		registryCredsSecret: string | *"registry-credentials"

		// Ports.
		metricsPort:     _#portSchema | *8443
		healthProbePort: _#portSchema | *8081
		webhookPort:     _#portSchema | *9443

		// Resource requests and limits for the controller.
		resources?: schemas.#ResourceRequirementsSchema & _ | *{
			requests: {cpu: "10m", memory: "64Mi"}
			limits: {cpu: "500m", memory: "128Mi"}
		}
	}

	// Per-node daemon configuration.
	daemon: {
		// gRPC port the daemon listens on. Must match cert DNS names.
		grpcPort: _#portSchema | *8443

		// Resource requests and limits for the daemon (optional — daemon runs
		// privileged and workload profile is hardware-dependent).
		resources?: schemas.#ResourceRequirementsSchema
	}

	// Certificate durations (cert-manager format: "2160h" = 90d, "720h" = 30d).
	certificates: {
		duration:    string | *"2160h"
		renewBefore: string | *"360h"
	}
}

debugValues: {
	controllerImage: {
		repository: "nalajalanaresh/ch-vmm-controller"
		tag:        "v1.4.0"
		digest:     "sha256:69fbbed29e7a1bc3d6bdae0d87e8ce520c01e7f19b94e024143e7b6e009480dc"
	}
	daemonImage: {
		repository: "nalajalanaresh/ch-vmm-daemon"
		tag:        "v1.4.0"
		digest:     "sha256:46000a92081e3ebaf9733923998fafb167a3d53169a06ec0be9e682ac00f8b9b"
	}
	namespace: "ch-vmm-system"
	controller: {
		replicas:            1
		registryCredsSecret: "registry-credentials"
		metricsPort:         8443
		healthProbePort:     8081
		webhookPort:         9443
		resources: {
			requests: {cpu: "10m", memory: "64Mi"}
			limits: {cpu: "500m", memory: "128Mi"}
		}
	}
	daemon: {
		grpcPort: 8443
		resources: {
			requests: {cpu: "50m", memory: "128Mi"}
			limits: {cpu: "1000m", memory: "512Mi"}
		}
	}
	certificates: {
		duration:    "2160h"
		renewBefore: "360h"
	}
}
