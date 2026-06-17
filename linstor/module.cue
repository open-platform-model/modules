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
	version:          "0.1.0"
	description:      "LINSTOR (Piraeus) replicated block storage — vendors the piraeus.io CRDs and a linstor.csi.linbit.com StorageClass; operator runtime installed via bootstrap manifest"
	defaultNamespace: "piraeus-datastore"
	labels: {
		"app.kubernetes.io/component": "storage"
	}
}

#config: {
	// StorageClass configuration — creates a linstor.csi.linbit.com StorageClass.
	//
	// NOTE: the emitted StorageClass name is NOT configurable here — the OPM
	// kubernetes transformer always names it "<release-name>-<component-name>",
	// i.e. "<release>-storage" (e.g. "linstor-storage" for the gon1_nas2/linstor
	// release). PVCs reference that name.
	storageClass: {
		// LINSTOR storage pool name. Must match the pool defined on the
		// satellites (see the LinstorSatelliteConfiguration in bootstrap/).
		storagePool: string | *"zfspv-pool"
		// Number of volume replicas LINSTOR places across nodes. On a single
		// node this is necessarily 1 (no replication until a 2nd node exists).
		placementCount: int & >=1 | *1
		// DRBD layer stack. "drbd storage" puts DRBD on top of the backend
		// (replication-capable); "storage" is plain backend with no DRBD.
		layerList: string | *"drbd storage"
		// Allow a volume to be accessed from a node that does not hold a
		// replica (diskless attach over the network). Single-node: "false".
		allowRemoteVolumeAccess: string | *"false"
		// Filesystem laid down on the volume.
		fsType: "ext4" | "xfs" | *"ext4"
		// Set as the default StorageClass for the cluster.
		isDefault: bool | *false
		// Reclaim policy for PersistentVolumes.
		reclaimPolicy: "Delete" | "Retain" | *"Retain"
		// Volume binding mode — WaitForFirstConsumer ensures local affinity.
		volumeBindingMode: "WaitForFirstConsumer" | "Immediate" | *"WaitForFirstConsumer"
		// Allow PVCs backed by this SC to be expanded after creation.
		allowVolumeExpansion: bool | *true
	}
}

// debugValues exercises the full #config surface for local `cue vet -c`.
debugValues: {
	storageClass: {
		storagePool:             "zfspv-pool"
		placementCount:          1
		layerList:               "drbd storage"
		allowRemoteVolumeAccess: "false"
		fsType:                  "ext4"
		isDefault:               false
		reclaimPolicy:           "Retain"
		volumeBindingMode:       "WaitForFirstConsumer"
		allowVolumeExpansion:    true
	}
}
