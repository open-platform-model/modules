// LINSTOR (Piraeus) — distributed/replicated block storage for Kubernetes.
//
// HYBRID packaging: this OPM module owns the parts that benefit from being
// native and stable — the four piraeus.io CRDs and the user-facing
// StorageClass. The Piraeus *operator runtime* (controller-manager + gencert
// Deployments, validating webhook + Service, image-config ConfigMap, RBAC) is
// installed from the pinned upstream manifest in the release's bootstrap/
// directory, because it carries a runtime cert-gen + fail-closed webhook + a
// version-pinned image-config ConfigMap that are tightly coupled to each
// operator release and gain nothing from being re-typed in CUE. The two config
// CRs (LinstorCluster, LinstorSatelliteConfiguration) also live in bootstrap/
// until OPM gains a native custom-resource primitive (RFC-0002).
//
// https://piraeus.io  |  https://github.com/piraeusdatastore/piraeus-operator
// Pinned to piraeus-operator v2.10.7 (LINSTOR v1.33.3, linstor-csi v1.11.2).
package linstor

import (
	m "opmodel.dev/core/v1alpha1/module@v1"
)

m.#Module

metadata: {
	modulePath:       "opmodel.dev/modules"
	name:             "linstor"
	version:          "0.1.2"
	description:      "LINSTOR (Piraeus) replicated block storage — vendors the piraeus.io CRDs and a linstor.csi.linbit.com StorageClass; operator runtime installed via bootstrap manifest"
	defaultNamespace: "piraeus-datastore"
	labels: {
		"app.kubernetes.io/component": "storage"
	}
}

#config: {
	// StorageClasses — one linstor.csi.linbit.com StorageClass per map entry.
	//
	// The emitted StorageClass name is NOT set here — the OPM kubernetes
	// transformer names every rendered resource "<release-name>-<component-name>",
	// and each map key below becomes a component. So on the "linstor" release:
	// key "storage" → StorageClass "linstor-storage"; key "nvme" → "linstor-nvme".
	// PVCs reference those names. At most one entry should set isDefault: true.
	//
	// This is the multi-pool successor to the former single `storageClass` field
	// (a release on one node can front several LINSTOR pools — e.g. a spinning
	// RAIDZ pool and an NVMe pool — each with its own SC). To keep the previous
	// "linstor-storage" name, use the key "storage".
	storageClasses: [Name=string]: #storageClassConfig
}

// Per-StorageClass configuration. One of these is supplied per entry in
// #config.storageClasses.
#storageClassConfig: {
	// LINSTOR storage pool name. Must match a pool defined on the satellites
	// (see the LinstorSatelliteConfiguration in the release's bootstrap/).
	storagePool: string | *"zfspv-pool"
	// Number of volume replicas LINSTOR places across nodes. On a single node
	// this is necessarily 1 (no replication until a 2nd node exists).
	placementCount: int & >=1 | *1
	// DRBD layer stack. "drbd storage" puts DRBD on top of the backend
	// (replication-capable); "storage" is plain backend with no DRBD.
	layerList: string | *"drbd storage"
	// Allow a volume to be accessed from a node that does not hold a replica
	// (diskless attach over the network). Single-node: "false".
	allowRemoteVolumeAccess: string | *"false"
	// Filesystem laid down on the volume.
	fsType: "ext4" | "xfs" | *"ext4"
	// Set as the default StorageClass for the cluster. At most one entry across
	// the map may set this to true.
	isDefault: bool | *false
	// Reclaim policy for PersistentVolumes.
	reclaimPolicy: "Delete" | "Retain" | *"Retain"
	// Volume binding mode — WaitForFirstConsumer ensures local affinity.
	volumeBindingMode: "WaitForFirstConsumer" | "Immediate" | *"WaitForFirstConsumer"
	// Allow PVCs backed by this SC to be expanded after creation.
	allowVolumeExpansion: bool | *true
}

// debugValues exercises the full #config surface for local `cue vet -c` —
// a two-pool layout (default spinning pool + non-default NVMe pool) so the
// dynamic-component loop and the is-default annotation branch are both covered.
debugValues: {
	storageClasses: {
		storage: {
			storagePool:             "zfspv-pool"
			placementCount:          1
			layerList:               "drbd storage"
			allowRemoteVolumeAccess: "false"
			fsType:                  "ext4"
			isDefault:               true
			reclaimPolicy:           "Retain"
			volumeBindingMode:       "WaitForFirstConsumer"
			allowVolumeExpansion:    true
		}
		nvme: {
			storagePool:             "nvme-pool"
			placementCount:          1
			layerList:               "storage"
			allowRemoteVolumeAccess: "false"
			fsType:                  "ext4"
			isDefault:               false
			reclaimPolicy:           "Retain"
			volumeBindingMode:       "WaitForFirstConsumer"
			allowVolumeExpansion:    true
		}
	}
}
