// Components for the OpenEBS ZFS LocalPV module.
//
// Components:
//   crds            — ZFS CustomResourceDefinitions (5 CRDs)
//   controller      — CSI controller Deployment (manages provisioning)
//   node            — CSI node DaemonSet (handles mounting on each node)
//   controller-rbac — ClusterRole + ClusterRoleBinding for the controller
//   node-rbac       — ClusterRole + ClusterRoleBinding for the node plugin
//
// The CSI controller runs with privileged access to manage ZFS datasets.
// The CSI node plugin runs with hostNetwork, hostPID, and privileged access
// for direct ZFS pool and device operations on the node.
package openebs_zfs

import (
	resources_extension "opmodel.dev/opm/v1alpha1/resources/extension@v1"
	resources_security "opmodel.dev/opm/v1alpha1/resources/security@v1"
	resources_storage "opmodel.dev/opm/v1alpha1/resources/storage@v1"
	resources_workload "opmodel.dev/opm/v1alpha1/resources/workload@v1"
	traits_network "opmodel.dev/opm/v1alpha1/traits/network@v1"
	traits_security "opmodel.dev/opm/v1alpha1/traits/security@v1"
	traits_workload "opmodel.dev/opm/v1alpha1/traits/workload@v1"
)

#components: {

	/////////////////////////////////////////////////////////////////
	//// CRDs — OpenEBS ZFS CustomResourceDefinitions
	////
	//// Deploys all 5 ZFS CRD definitions so the cluster accepts
	//// ZFSVolume, ZFSSnapshot, ZFSBackup, ZFSRestore, and ZFSNode
	//// as first-class resources. Schema sourced from crds_data.cue.
	/////////////////////////////////////////////////////////////////

	crds: {
		resources_extension.#CRDs

		let _rawCrds = {
			"zfsvolumes.zfs.openebs.io":   #zfs_openebs_io_zfsvolumes
			"zfssnapshots.zfs.openebs.io": #zfs_openebs_io_zfssnapshots
			"zfsbackups.zfs.openebs.io":   #zfs_openebs_io_zfsbackups
			"zfsrestores.zfs.openebs.io":  #zfs_openebs_io_zfsrestores
			"zfsnodes.zfs.openebs.io":     #zfs_openebs_io_zfsnodes
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
						if raw.spec.names.shortNames != _|_ {
							shortNames: raw.spec.names.shortNames
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
						if v.additionalPrinterColumns != _|_ {
							additionalPrinterColumns: v.additionalPrinterColumns
						}
					}]
				}
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Controller — CSI controller Deployment
	////
	//// Handles PVC provisioning, attachment, snapshotting, and resizing.
	//// Runs the zfs-driver in controller mode.
	//// Requires privileged access to manage ZFS datasets via API.
	/////////////////////////////////////////////////////////////////

	controller: {
		resources_workload.#Container
		resources_storage.#Volumes
		traits_workload.#Scaling
		traits_workload.#RestartPolicy
		traits_workload.#UpdateStrategy
		traits_workload.#GracefulShutdown
		traits_security.#SecurityContext
		traits_security.#WorkloadIdentity

		metadata: {
			name: "controller"
			labels: {
				"core.opmodel.dev/workload-type": "stateless"
			}
		}

		spec: {
			scaling: count: #config.controller.replicas

			restartPolicy: "Always"

			updateStrategy: type: "RollingUpdate"

			gracefulShutdown: terminationGracePeriodSeconds: 30

			workloadIdentity: {
				name:           "openebs-zfs-controller-sa"
				automountToken: true
			}

			container: {
				name: "openebs-zfs-plugin"
				image: {
					repository: #config.image.repository
					tag:        #config.image.tag
					digest:     ""
					pullPolicy: #config.image.pullPolicy
				}

				args: [
					"--nodeid=$(OPENEBS_NODE_ID)",
					"--endpoint=$(OPENEBS_CSI_ENDPOINT)",
					"--plugin=controller",
				]

				env: {
					OPENEBS_NODE_ID: {
						name: "OPENEBS_NODE_ID"
						fieldRef: fieldPath: "spec.nodeName"
					}
					OPENEBS_CSI_ENDPOINT: {
						name:  "OPENEBS_CSI_ENDPOINT"
						value: "unix:///plugin/csi.sock"
					}
					OPENEBS_NAMESPACE: {
						name:  "OPENEBS_NAMESPACE"
						value: "openebs"
					}
					OPENEBS_NODE_DRIVER: {
						name:  "OPENEBS_NODE_DRIVER"
						value: "controller"
					}
				}

				if #config.controller.resources != _|_ {
					resources: #config.controller.resources
				}

				volumeMounts: {
					"plugin-dir": {
						name:      "plugin-dir"
						mountPath: "/plugin"
						emptyDir: {}
					}
					"device-dir": {
						name:             "device-dir"
						mountPath:        "/dev"
						mountPropagation: "Bidirectional"
						emptyDir: {}
					}
				}

				securityContext: {
					privileged:               true
					allowPrivilegeEscalation: true
				}
			}

			volumes: {
				"plugin-dir": {
					name: "plugin-dir"
					emptyDir: {}
				}
				"device-dir": {
					name: "device-dir"
					hostPath: {
						path: "/dev"
						type: "Directory"
					}
				}
			}

			// Controller security context — runs as root with full privilege
			// required for ZFS dataset management operations.
			securityContext: {
				runAsNonRoot:             false
				runAsUser:                0
				allowPrivilegeEscalation: true
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Node Plugin — CSI node DaemonSet
	////
	//// Runs on every node to handle volume mount/unmount.
	//// Requires hostNetwork and privileged access for ZFS operations.
	//// Mounts host /dev, /sys, /, and kubelet directories.
	/////////////////////////////////////////////////////////////////

	node: {
		resources_workload.#Container
		resources_storage.#Volumes
		traits_workload.#RestartPolicy
		traits_workload.#UpdateStrategy
		traits_workload.#GracefulShutdown
		traits_network.#HostNetwork
		traits_security.#HostPID
		traits_security.#SecurityContext
		traits_security.#WorkloadIdentity

		metadata: {
			name: "node"
			labels: {
				"core.opmodel.dev/workload-type": "daemon"
			}
		}

		spec: {
			restartPolicy: "Always"

			updateStrategy: {
				type: "RollingUpdate"
				rollingUpdate: maxUnavailable: 1
			}

			gracefulShutdown: terminationGracePeriodSeconds: 30

			// hostNetwork required for ZFS pool discovery on the node network.
			hostNetwork: true

			// hostPID required for ZFS pool and device operations on the host.
			hostPid: true

			// hostPID required for ZFS pool and device operations on the host.
			hostPid: true

			workloadIdentity: {
				name:           "openebs-zfs-node-sa"
				automountToken: true
			}

			container: {
				name: "openebs-zfs-plugin"
				image: {
					repository: #config.image.repository
					tag:        #config.image.tag
					digest:     ""
					pullPolicy: #config.image.pullPolicy
				}

				args: [
					"--nodeid=$(OPENEBS_NODE_ID)",
					"--endpoint=$(OPENEBS_CSI_ENDPOINT)",
					"--plugin=node",
				]

				env: {
					OPENEBS_NODE_ID: {
						name: "OPENEBS_NODE_ID"
						fieldRef: fieldPath: "spec.nodeName"
					}
					OPENEBS_CSI_ENDPOINT: {
						name:  "OPENEBS_CSI_ENDPOINT"
						value: "unix:///plugin/csi.sock"
					}
					OPENEBS_NAMESPACE: {
						name:  "OPENEBS_NAMESPACE"
						value: "openebs"
					}
					OPENEBS_NODE_DRIVER: {
						name:  "OPENEBS_NODE_DRIVER"
						value: "agent"
					}
				}

				if #config.nodePlugin.resources != _|_ {
					resources: #config.nodePlugin.resources
				}

				volumeMounts: {
					"plugin-dir": {
						name:      "plugin-dir"
						mountPath: "/plugin"
						emptyDir: {}
					}
					"pod-dir": {
						name:             "pod-dir"
						mountPath:        "\(#config.nodePlugin.kubeletDir)/pods"
						mountPropagation: "Bidirectional"
						emptyDir: {}
					}
					"device-dir": {
						name:             "device-dir"
						mountPath:        "/dev"
						mountPropagation: "Bidirectional"
						emptyDir: {}
					}
					"sys-dir": {
						name:      "sys-dir"
						mountPath: "/sys"
						emptyDir: {}
					}
					"host-root": {
						name:             "host-root"
						mountPath:        "/host"
						mountPropagation: "Bidirectional"
						emptyDir: {}
					}
				}

				securityContext: {
					privileged:               true
					allowPrivilegeEscalation: true
					capabilities: {
						add: ["SYS_ADMIN"]
						drop: ["ALL"]
					}
				}
			}

			volumes: {
				"plugin-dir": {
					name: "plugin-dir"
					hostPath: {
						path: "\(#config.nodePlugin.kubeletDir)/plugins/zfs.csi.openebs.io"
						type: "DirectoryOrCreate"
					}
				}
				"pod-dir": {
					name: "pod-dir"
					hostPath: {
						path: "\(#config.nodePlugin.kubeletDir)/pods"
						type: "Directory"
					}
				}
				"device-dir": {
					name: "device-dir"
					hostPath: {
						path: "/dev"
						type: "Directory"
					}
				}
				"sys-dir": {
					name: "sys-dir"
					hostPath: {
						path: "/sys"
						type: "Directory"
					}
				}
				"host-root": {
					name: "host-root"
					hostPath: {
						path: "/"
						type: "Directory"
					}
				}
				"registration-dir": {
					name: "registration-dir"
					hostPath: {
						path: "\(#config.nodePlugin.kubeletDir)/plugins_registry"
						type: "Directory"
					}
				}
			}

			// Node security context — runs as root with full privilege
			// required for ZFS pool and device operations on the host.
			securityContext: {
				runAsNonRoot:             false
				runAsUser:                0
				allowPrivilegeEscalation: true
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Controller RBAC — ClusterRole + ClusterRoleBinding
	/////////////////////////////////////////////////////////////////

	"controller-rbac": {
		resources_security.#Role

		spec: role: {
			name:  "openebs-zfs-controller-role"
			scope: "cluster"

			rules: [
				{
					apiGroups: [""]
					resources: ["persistentvolumes"]
					verbs: ["create", "delete", "get", "list", "watch", "patch", "update"]
				},
				{
					apiGroups: [""]
					resources: ["persistentvolumeclaims"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: [""]
					resources: ["persistentvolumeclaims/status"]
					verbs: ["update", "patch"]
				},
				{
					apiGroups: ["storage.k8s.io"]
					resources: ["storageclasses"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: [""]
					resources: ["events"]
					verbs: ["create", "patch", "update", "list", "watch"]
				},
				{
					apiGroups: ["zfs.openebs.io"]
					resources: ["zfsvolumes", "zfssnapshots", "zfsbackups", "zfsrestores"]
					verbs: ["*"]
				},
				{
					apiGroups: ["zfs.openebs.io"]
					resources: ["zfsvolumes/status", "zfssnapshots/status", "zfsbackups/status", "zfsrestores/status"]
					verbs: ["update", "patch"]
				},
				{
					apiGroups: ["snapshot.storage.k8s.io"]
					resources: ["volumesnapshots", "volumesnapshotclasses", "volumesnapshotcontents"]
					verbs: ["get", "list", "watch", "create", "delete", "update", "patch"]
				},
				{
					apiGroups: ["snapshot.storage.k8s.io"]
					resources: ["volumesnapshotcontents/status"]
					verbs: ["update", "patch"]
				},
				{
					apiGroups: [""]
					resources: ["configmaps"]
					verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
				},
				{
					apiGroups: ["coordination.k8s.io"]
					resources: ["leases"]
					verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
				},
				{
					apiGroups: [""]
					resources: ["nodes"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: ["storage.k8s.io"]
					resources: ["volumeattachments"]
					verbs: ["get", "list", "watch", "patch"]
				},
				{
					apiGroups: ["storage.k8s.io"]
					resources: ["volumeattachments/status"]
					verbs: ["patch"]
				},
			]

			subjects: [{name: "openebs-zfs-controller-sa"}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Node RBAC — ClusterRole + ClusterRoleBinding
	/////////////////////////////////////////////////////////////////

	"node-rbac": {
		resources_security.#Role

		spec: role: {
			name:  "openebs-zfs-node-role"
			scope: "cluster"

			rules: [
				{
					apiGroups: ["zfs.openebs.io"]
					resources: ["zfsvolumes", "zfssnapshots", "zfsbackups", "zfsrestores", "zfsnodes"]
					verbs: ["*"]
				},
				{
					apiGroups: ["zfs.openebs.io"]
					resources: ["zfsvolumes/status", "zfssnapshots/status", "zfsbackups/status", "zfsrestores/status", "zfsnodes/status"]
					verbs: ["update", "patch"]
				},
				{
					apiGroups: [""]
					resources: ["nodes"]
					verbs: ["get", "list", "watch", "update", "patch"]
				},
				{
					apiGroups: ["storage.k8s.io"]
					resources: ["csinodes"]
					verbs: ["get", "list", "watch", "create", "update", "patch"]
				},
				{
					apiGroups: [""]
					resources: ["pods"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: [""]
					resources: ["events"]
					verbs: ["create", "patch"]
				},
			]

			subjects: [{name: "openebs-zfs-node-sa"}]
		}
	}
}
