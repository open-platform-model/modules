// Components for the LINSTOR (Piraeus) module — HYBRID packaging.
//
// Components:
//   crds    — the 4 piraeus.io CustomResourceDefinitions (LinstorCluster,
//             LinstorNodeConnection, LinstorSatelliteConfiguration,
//             LinstorSatellite). Sourced from crds_data.cue.
//   storage — the user-facing linstor.csi.linbit.com StorageClass.
//
// The Piraeus operator runtime and the LinstorCluster/LinstorSatelliteConfiguration
// custom resources are NOT components here — they are applied from the pinned
// upstream manifest + config CRs under the release's bootstrap/ directory. See
// module.cue for the rationale.
package linstor

import (
	resources_extension "opmodel.dev/opm/v1alpha1/resources/extension@v1"
	resources_storage_k8s "opmodel.dev/kubernetes/v1/resources/storage@v1"
)

#components: {

	/////////////////////////////////////////////////////////////////
	//// CRDs — piraeus.io CustomResourceDefinitions
	////
	//// Installs the 4 Piraeus CRDs so the cluster accepts LinstorCluster,
	//// LinstorNodeConnection, LinstorSatelliteConfiguration, and
	//// LinstorSatellite resources. The operator runtime (bootstrap/)
	//// reconciles these into the actual LINSTOR controller/satellite/CSI
	//// workloads. Schema is permissive (preserve-unknown-fields); real
	//// validation happens at the operator's admission webhook.
	/////////////////////////////////////////////////////////////////

	crds: {
		resources_extension.#CRDs

		let _rawCrds = {
			"linstorclusters.piraeus.io":                #piraeus_io_linstorclusters
			"linstornodeconnections.piraeus.io":         #piraeus_io_linstornodeconnections
			"linstorsatelliteconfigurations.piraeus.io": #piraeus_io_linstorsatelliteconfigurations
			"linstorsatellites.piraeus.io":              #piraeus_io_linstorsatellites
		}

		spec: crds: {
			for crdName, raw in _rawCrds {
				(crdName): {
					group: raw.spec.group
					names: {
						kind:   raw.spec.names.kind
						plural: raw.spec.names.plural
						if raw.spec.names.singular != _|_ {
							singular: raw.spec.names.singular
						}
					}
					scope: raw.spec.scope
					versions: [for v in raw.spec.versions {
						name:    v.name
						served:  v.served
						storage: v.storage
						if v.schema != _|_ {
							schema: v.schema
						}
						if v.subresources != _|_ {
							subresources: v.subresources
						}
					}]
				}
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// StorageClass — user-facing PVC entrypoint
	////
	//// provisioner: linstor.csi.linbit.com
	//// parameters select the storage pool, replica placement count, DRBD
	//// layer stack, and filesystem. The operator's vstorageclass.kb.io
	//// webhook validates this object, so the operator runtime must be up
	//// before the StorageClass is applied.
	////
	//// Component name "storage" so the OPM k8s transformer renders the
	//// StorageClass; the metadata.name override (#config.storageClass.name)
	//// sets the final resource name.
	/////////////////////////////////////////////////////////////////

	storage: {
		resources_storage_k8s.#StorageClass

		spec: storageclass: {
			// The transformer derives the StorageClass name from
			// <release>-<component> ("storage"), so metadata.name here is not
			// emitted — only the default-class annotation is honored.
			if #config.storageClass.isDefault {
				metadata: annotations: {
					"storageclass.kubernetes.io/is-default-class": "true"
				}
			}
			provisioner:          "linstor.csi.linbit.com"
			reclaimPolicy:        #config.storageClass.reclaimPolicy
			volumeBindingMode:    #config.storageClass.volumeBindingMode
			allowVolumeExpansion: #config.storageClass.allowVolumeExpansion
			parameters: {
				"linstor.csi.linbit.com/storagePool":             #config.storageClass.storagePool
				"linstor.csi.linbit.com/placementCount":          "\(#config.storageClass.placementCount)"
				"linstor.csi.linbit.com/layerList":               #config.storageClass.layerList
				"linstor.csi.linbit.com/allowRemoteVolumeAccess": #config.storageClass.allowRemoteVolumeAccess
				"csi.storage.k8s.io/fstype":                      #config.storageClass.fsType
			}
		}
	}
}
