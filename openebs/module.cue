// OpenEBS — pluggable persistent-volume engines for Kubernetes.
//
// This module is the successor to modules/openebs_zfs. It is engine-pluggable:
// a single #config.engine discriminator selects which OpenEBS data-plane to
// deploy. Each engine materialises its own set of workloads, RBAC, CRDs, and
// StorageClass.
//
// v0.1.0 — only the "hostpath" engine is implemented. Other engine values are
// reserved and will be added in later minor versions without breaking callers
// who already use "hostpath":
//
//   hostpath    — LocalPV HostPath provisioner (node-local PVs, no CSI).
//                 Simplest, lightest, good default for single-node and
//                 application-replicated workloads.
//   zfs         — [planned] LocalPV ZFS CSI driver. Ported from openebs_zfs.
//   lvm         — [planned] LocalPV LVM CSI driver.
//   replicated  — [planned] Mayastor NVMe-oF replicated engine.
//
// https://openebs.io
package openebs

import (
	m "opmodel.dev/core/v1alpha1/module@v1"
	schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)

m.#Module

metadata: {
	modulePath:       "opmodel.dev/modules"
	name:             "openebs"
	version:          "0.1.0"
	description:      "OpenEBS — engine-pluggable persistent volumes for Kubernetes (hostpath in v0.1.0; zfs/lvm/replicated planned)"
	defaultNamespace: "openebs"
	labels: {
		"app.kubernetes.io/component": "storage"
	}
}

#config: {
	// Engine discriminator — selects which OpenEBS data-plane is deployed.
	// v0.1.0 only implements "hostpath"; the enum is intentionally narrow to
	// reject misconfiguration. Future versions widen this disjunction without
	// breaking existing "hostpath" users.
	engine: "hostpath" | *"hostpath"

	// HostPath engine — LocalPV HostPath provisioner.
	// Node-local PVs backed by a directory on the host.
	// No CSI driver, no DaemonSet — a single Deployment watches PVCs bound
	// to the StorageClass and creates PV directories directly under basePath.
	hostpath: {
		// Provisioner image.
		image: schemas.#Image & {
			repository: string | *"openebs/provisioner-localpv"
			// Upstream tag (see https://github.com/openebs/dynamic-localpv-provisioner/releases).
			tag:    string | *"4.2.0"
			digest: string | *""
		}

		// Helper image used by the provisioner to run short-lived BusyBox
		// pods that create and clean up PV directories on the node.
		helperImage: schemas.#Image & {
			repository: string | *"openebs/linux-utils"
			tag:        string | *"4.2.0"
			digest:     string | *""
		}

		// Number of provisioner replicas. 1 is sufficient — the provisioner
		// is stateless and PVC provisioning is not latency-sensitive.
		replicas: int & >=1 | *1

		// Resource requests/limits for the provisioner container (optional).
		resources?: schemas.#ResourceRequirementsSchema

		// Host directory backing all PVs created via this StorageClass.
		// On Talos this path must be writable — typically /var/openebs/local
		// surfaced through machineconfig `machine.kubelet.extraMounts` with
		// `rshared` propagation. See TALOS.md.
		basePath: string | *"/var/openebs/local"

		// StorageClass emitted by this module.
		storageClass: {
			// StorageClass name (referenced by PVCs via storageClassName).
			name: string | *"openebs-hostpath"
			// Mark this StorageClass as the cluster default. Leave false when
			// coexisting with another default (e.g. local-path-provisioner).
			isDefault: bool | *false
			// Reclaim policy for PVs. Delete removes the host directory on
			// PVC deletion; Retain leaves it for manual cleanup.
			reclaimPolicy: "Delete" | "Retain" | *"Delete"
			// WaitForFirstConsumer binds the PV only after a pod is scheduled,
			// which is mandatory for correct node-local placement.
			volumeBindingMode: "WaitForFirstConsumer" | "Immediate" | *"WaitForFirstConsumer"
			// Extra StorageClass parameters, if any (merged into .parameters).
			extraParameters?: [string]: string
		}
	}
}

// debugValues exercises the full #config surface for `cue vet -c`.
debugValues: {
	engine: "hostpath"
	hostpath: {
		image: {
			repository: "openebs/provisioner-localpv"
			tag:        "4.2.0"
			pullPolicy: "IfNotPresent"
		}
		helperImage: {
			repository: "openebs/linux-utils"
			tag:        "4.2.0"
			pullPolicy: "IfNotPresent"
		}
		replicas: 1
		resources: {
			requests: {
				cpu:    "50m"
				memory: "64Mi"
			}
			limits: {
				cpu:    "200m"
				memory: "128Mi"
			}
		}
		basePath: "/var/openebs/local"
		storageClass: {
			name:              "openebs-hostpath"
			isDefault:         false
			reclaimPolicy:     "Delete"
			volumeBindingMode: "WaitForFirstConsumer"
			extraParameters: {
				"cas-type": "local"
			}
		}
	}
}
