// Components for the generic OpenEBS module (engine-pluggable).
//
// v0.1.0 implements the "hostpath" engine:
//
//   provisioner         — Deployment running openebs/provisioner-localpv.
//                         Watches PVCs, creates host directories under basePath,
//                         and emits matching PVs. Uses a BusyBox helper pod to
//                         handle per-PV chown/chmod without mutating the host.
//   provisioner-rbac    — ClusterRole + ClusterRoleBinding granting the
//                         provisioner the permissions to watch PVCs/PVs/nodes
//                         and run helper pods.
//   hostpath            — The user-facing StorageClass that routes PVC
//                         requests at the provisioner. Component name is
//                         engine-scoped because the emitted StorageClass
//                         name is derived from release+component
//                         (e.g. "openebs-hostpath" instead of the generic
//                         "openebs-storageclass").
//
// HostPath has no CRDs and no DaemonSet — all provisioning happens in a
// single centralised Deployment. That is what makes it the lightest option
// and avoids the multi-container CSI sidecar modelling gap that blocks the
// zfs/lvm/replicated engines in this repo.
package openebs

import (
	resources_security "opmodel.dev/opm/v1alpha1/resources/security@v1"
	resources_workload "opmodel.dev/opm/v1alpha1/resources/workload@v1"
	resources_storage_k8s "opmodel.dev/kubernetes/v1/resources/storage@v1"
	traits_workload "opmodel.dev/opm/v1alpha1/traits/workload@v1"
	traits_security "opmodel.dev/opm/v1alpha1/traits/security@v1"
)

#components: {

	/////////////////////////////////////////////////////////////////
	//// Provisioner — LocalPV HostPath Deployment
	////
	//// Single Deployment (not a DaemonSet) — the provisioner is a
	//// cluster-wide controller that reacts to PVCs and dispatches
	//// short-lived helper pods to nodes for directory creation.
	/////////////////////////////////////////////////////////////////

	provisioner: {
		resources_workload.#Container
		traits_workload.#Scaling
		traits_workload.#RestartPolicy
		traits_workload.#UpdateStrategy
		traits_security.#SecurityContext
		traits_security.#WorkloadIdentity

		metadata: {
			name: "localpv-provisioner"
			labels: {
				"core.opmodel.dev/workload-type": "stateless"
				"openebs.io/component-name":      "openebs-localpv-provisioner"
				"openebs.opmodel.dev/engine":     #config.engine
			}
		}

		spec: {
			scaling: count: #config.hostpath.replicas
			restartPolicy: "Always"
			updateStrategy: type: "RollingUpdate"

			workloadIdentity: {
				name:           "openebs-localpv-provisioner-sa"
				automountToken: true
			}

			container: {
				name: "openebs-provisioner-hostpath"
				image: {
					repository: #config.hostpath.image.repository
					tag:        #config.hostpath.image.tag
					digest:     #config.hostpath.image.digest
					pullPolicy: #config.hostpath.image.pullPolicy
				}

				// The provisioner resolves its identity and helper image via
				// environment variables injected by Kubernetes.
				env: {
					OPENEBS_NAMESPACE: {
						name: "OPENEBS_NAMESPACE"
						fieldRef: fieldPath: "metadata.namespace"
					}
					OPENEBS_SERVICE_ACCOUNT: {
						name: "OPENEBS_SERVICE_ACCOUNT"
						fieldRef: fieldPath: "spec.serviceAccountName"
					}
					OPENEBS_IO_HELPER_IMAGE: {
						name:  "OPENEBS_IO_HELPER_IMAGE"
						value: "\(#config.hostpath.helperImage.repository):\(#config.hostpath.helperImage.tag)"
					}
					OPENEBS_IO_ENABLE_ANALYTICS: {
						name:  "OPENEBS_IO_ENABLE_ANALYTICS"
						value: "false"
					}
					OPENEBS_IO_INSTALLER_TYPE: {
						name:  "OPENEBS_IO_INSTALLER_TYPE"
						value: "openebs-operator"
					}
					OPENEBS_IO_BASE_PATH: {
						name:  "OPENEBS_IO_BASE_PATH"
						value: #config.hostpath.basePath
					}
				}

				if #config.hostpath.resources != _|_ {
					resources: #config.hostpath.resources
				}

				// Provisioner itself does not require elevated privileges —
				// helper pods do the host-level work inside their own mount
				// namespace, launched via the provisioner's RBAC.
				securityContext: {
					allowPrivilegeEscalation: false
					runAsNonRoot:             false
					readOnlyRootFilesystem:   false
				}
			}

			securityContext: {
				runAsNonRoot:             false
				runAsUser:                0
				allowPrivilegeEscalation: false
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Provisioner RBAC — ClusterRole + ClusterRoleBinding
	////
	//// The provisioner needs cluster-scoped access to watch PVCs,
	//// create PVs, list nodes for scheduling helper pods, and
	//// create/delete those helper pods in its own namespace.
	/////////////////////////////////////////////////////////////////

	"provisioner-rbac": {
		resources_security.#Role

		spec: role: {
			name:  "openebs-localpv-provisioner-role"
			scope: "cluster"

			rules: [
				{
					apiGroups: [""]
					resources: ["nodes"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: [""]
					resources: ["namespaces", "pods", "events", "endpoints", "configmaps", "secrets"]
					verbs: ["*"]
				},
				{
					apiGroups: [""]
					resources: ["persistentvolumes", "persistentvolumeclaims"]
					verbs: ["*"]
				},
				{
					apiGroups: ["storage.k8s.io"]
					resources: ["storageclasses"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: ["openebs.io"]
					resources: ["*"]
					verbs: ["*"]
				},
				{
					apiGroups: ["local.openebs.io"]
					resources: ["*"]
					verbs: ["*"]
				},
				{
					apiGroups: ["coordination.k8s.io"]
					resources: ["leases"]
					verbs: ["get", "watch", "list", "delete", "update", "create"]
				},
			]

			subjects: [{name: "openebs-localpv-provisioner-sa"}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// StorageClass — user-facing PVC entrypoint
	////
	//// provisioner: openebs.io/local
	//// parameters: StorageType=hostpath + BasePath=<configured>
	////
	//// Component name is "hostpath" (not "storageclass") so the OPM
	//// k8s transformer renders the StorageClass as
	//// "<release-name>-hostpath" — meaningful to users — rather than
	//// "<release-name>-storageclass".
	/////////////////////////////////////////////////////////////////

	hostpath: {
		resources_storage_k8s.#StorageClass

		spec: storageclass: {
			metadata: {
				name: #config.hostpath.storageClass.name
				if #config.hostpath.storageClass.isDefault {
					annotations: {
						"storageclass.kubernetes.io/is-default-class": "true"
					}
				}
			}
			provisioner:       "openebs.io/local"
			reclaimPolicy:     #config.hostpath.storageClass.reclaimPolicy
			volumeBindingMode: #config.hostpath.storageClass.volumeBindingMode
			parameters: {
				// StorageType discriminates within the openebs.io/local
				// provisioner — hostpath vs device vs zfs. Hostpath is the
				// only value supported by this engine.
				"cas-type":    "local"
				"storageType": "hostpath"
				"basePath":    #config.hostpath.basePath
				if #config.hostpath.storageClass.extraParameters != _|_ {
					for k, v in #config.hostpath.storageClass.extraParameters {
						(k): v
					}
				}
			}
		}
	}
}
