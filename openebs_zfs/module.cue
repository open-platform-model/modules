// OpenEBS ZFS LocalPV — CSI driver for ZFS-backed persistent volumes on Kubernetes.
// Deploys the ZFS CSI controller (Deployment), node plugin (DaemonSet), CRD definitions,
// RBAC, and an optional StorageClass.
//
// https://openebs.io  |  https://github.com/openebs/zfs-localpv
package openebs_zfs

import (
	m "opmodel.dev/core/v1alpha1/module@v1"
	schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)

m.#Module

metadata: {
	modulePath:       "opmodel.dev/modules"
	name:             "openebs-zfs"
	version:          "0.1.0"
	description:      "OpenEBS ZFS LocalPV CSI driver — deploys controller, node plugin, CRDs, and RBAC for ZFS-backed persistent volumes"
	defaultNamespace: "openebs"
	labels: {
		"app.kubernetes.io/component": "storage"
	}
}

#config: {
	// Image configuration for the ZFS CSI driver.
	image: {
		// ZFS driver image repository.
		repository: string | *"openebs/zfs-driver"
		// ZFS driver release tag. See https://github.com/openebs/zfs-localpv/releases.
		tag: string | *"2.6.2"
		// Image pull policy.
		pullPolicy: "Always" | *"IfNotPresent" | "Never"
	}

	// CSI sidecar image tags — pinned to stable upstream versions.
	sidecars: {
		provisionerTag:   string | *"v3.6.3"
		attacherTag:      string | *"v4.4.3"
		resizerTag:       string | *"v1.9.3"
		snapshotterTag:   string | *"v6.3.3"
		nodeRegistrarTag: string | *"v2.9.3"
	}

	// Controller configuration — manages volume provisioning requests.
	controller: {
		// Number of controller replicas (set to 2+ for HA).
		replicas: int & >=1 | *1
		// Resource requests and limits (optional).
		resources?: schemas.#ResourceRequirementsSchema
	}

	// Node plugin configuration — runs on every node, handles volume mounting.
	nodePlugin: {
		// Kubelet directory — override if your distribution uses a non-standard path.
		// Talos Linux uses the standard /var/lib/kubelet.
		kubeletDir: string | *"/var/lib/kubelet"
		// Resource requests and limits (optional).
		resources?: schemas.#ResourceRequirementsSchema
	}

	// StorageClass configuration — creates an openebs-zfspv StorageClass.
	storageClass: {
		// Name of the ZFS pool that must exist on all nodes.
		poolName: string | *"zfspv-pool"
		// Filesystem type: "zfs" for native datasets, "ext4" for zvol-backed ext4.
		fsType: "zfs" | "ext4" | *"zfs"
		// ZFS dataset recordsize (for fsType=zfs).
		recordSize: string | *"128k"
		// Compression algorithm.
		compression: "off" | "lz4" | "gzip" | "zstd" | *"lz4"
		// Deduplication (expensive — keep off unless you know what you're doing).
		dedup: "off" | "on" | *"off"
		// Set as the default StorageClass for the cluster.
		isDefault: bool | *false
		// Reclaim policy for PersistentVolumes.
		reclaimPolicy: "Delete" | *"Retain"
		// Volume binding mode — WaitForFirstConsumer ensures local affinity.
		volumeBindingMode: "WaitForFirstConsumer" | "Immediate" | *"WaitForFirstConsumer"
	}
}

// debugValues exercises the full #config surface for local `cue vet`.
debugValues: {
	image: {
		repository: "openebs/zfs-driver"
		tag:        "2.6.2"
		pullPolicy: "IfNotPresent"
	}
	sidecars: {
		provisionerTag:   "v3.6.3"
		attacherTag:      "v4.4.3"
		resizerTag:       "v1.9.3"
		snapshotterTag:   "v6.3.3"
		nodeRegistrarTag: "v2.9.3"
	}
	controller: {
		replicas: 1
		resources: {
			requests: {
				cpu:    "100m"
				memory: "128Mi"
			}
			limits: {
				cpu:    "500m"
				memory: "512Mi"
			}
		}
	}
	nodePlugin: {
		kubeletDir: "/var/lib/kubelet"
		resources: {
			requests: {
				cpu:    "100m"
				memory: "128Mi"
			}
			limits: {
				cpu:    "500m"
				memory: "512Mi"
			}
		}
	}
	storageClass: {
		poolName:          "zfspv-pool"
		fsType:            "zfs"
		recordSize:        "128k"
		compression:       "lz4"
		dedup:             "off"
		isDefault:         false
		reclaimPolicy:     "Retain"
		volumeBindingMode: "WaitForFirstConsumer"
	}
}
