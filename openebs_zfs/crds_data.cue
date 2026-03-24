package openebs_zfs

#zfs_openebs_io_zfsvolumes: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: {
		annotations: "controller-gen.kubebuilder.io/version": "v0.14.0"
		name: "zfsvolumes.zfs.openebs.io"
	}
	spec: {
		group: "zfs.openebs.io"
		names: {
			kind:     "ZFSVolume"
			listKind: "ZFSVolumeList"
			plural:   "zfsvolumes"
			shortNames: ["zv"]
			singular: "zfsvolume"
		}
		scope: "Namespaced"
		versions: [{
			additionalPrinterColumns: [{
				jsonPath: ".spec.poolName"
				name:     "ZFSPool"
				type:     "string"
			}, {
				jsonPath: ".spec.nodeID"
				name:     "Node"
				type:     "string"
			}, {
				jsonPath: ".spec.capacity"
				name:     "Size"
				type:     "string"
			}, {
				jsonPath: ".spec.fsType"
				name:     "FsType"
				type:     "string"
			}, {
				jsonPath: ".status.state"
				name:     "Status"
				type:     "string"
			}, {
				jsonPath: ".metadata.creationTimestamp"
				name:     "Age"
				type:     "date"
			}]
			name: "v1"
			schema: openAPIV3Schema: {
				description: "ZFSVolume represents a ZFS dataset or zvol provisioned on a node."
				properties: {
					apiVersion: {
						description: "APIVersion defines the versioned schema of this representation of an object."
						type:        "string"
					}
					kind: {
						description: "Kind is a string value representing the REST resource this object represents."
						type:        "string"
					}
					metadata: type: "object"
					spec: {
						description: "ZFSVolumeSpec defines the desired state of ZFSVolume."
						properties: {
							capacity: {
								description: "Capacity of the volume."
								type:        "string"
							}
							compression: {
								description: "Compression specifies the compression algorithm."
								type:        "string"
							}
							dedup: {
								description: "Dedup specifies deduplication for the volume."
								type:        "string"
							}
							fsType: {
								description: "FsType specifies the filesystem type."
								type:        "string"
							}
							nodeID: {
								description: "NodeID is the node on which this volume is provisioned."
								type:        "string"
							}
							ownerNodeID: {
								description: "OwnerNodeID is the node which owns the volume."
								type:        "string"
							}
							poolName: {
								description: "PoolName specifies the name of the ZFS pool."
								type:        "string"
							}
							recordsize: {
								description: "RecordSize specifies the block size for ZFS datasets."
								type:        "string"
							}
							thinProvision: {
								description: "ThinProvision specifies whether the volume is thin provisioned."
								type:        "string"
							}
							volblocksize: {
								description: "VolBlockSize specifies the block size for zvols."
								type:        "string"
							}
							volumeType: {
								description: "VolumeType specifies DATASET or ZVOL."
								type:        "string"
							}
						}
						required: ["capacity", "nodeID", "ownerNodeID", "poolName"]
						type: "object"
					}
					status: {
						description: "ZFSVolumeStatus defines the observed state of ZFSVolume."
						properties: state: {
							description: "State of the ZFSVolume."
							type:        "string"
						}
						type: "object"
					}
				}
				required: ["spec"]
				type: "object"
			}
			served:  true
			storage: true
			subresources: status: {}
		}]
	}
}

#zfs_openebs_io_zfssnapshots: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: {
		annotations: "controller-gen.kubebuilder.io/version": "v0.14.0"
		name: "zfssnapshots.zfs.openebs.io"
	}
	spec: {
		group: "zfs.openebs.io"
		names: {
			kind:     "ZFSSnapshot"
			listKind: "ZFSSnapshotList"
			plural:   "zfssnapshots"
			shortNames: ["zfssnap"]
			singular: "zfssnapshot"
		}
		scope: "Namespaced"
		versions: [{
			additionalPrinterColumns: [{
				jsonPath: ".spec.poolName"
				name:     "ZFSPool"
				type:     "string"
			}, {
				jsonPath: ".spec.nodeID"
				name:     "Node"
				type:     "string"
			}, {
				jsonPath: ".spec.capacity"
				name:     "Size"
				type:     "string"
			}, {
				jsonPath: ".status.state"
				name:     "Status"
				type:     "string"
			}, {
				jsonPath: ".metadata.creationTimestamp"
				name:     "Age"
				type:     "date"
			}]
			name: "v1"
			schema: openAPIV3Schema: {
				description: "ZFSSnapshot represents a ZFS snapshot of a volume."
				properties: {
					apiVersion: {
						description: "APIVersion defines the versioned schema of this representation of an object."
						type:        "string"
					}
					kind: {
						description: "Kind is a string value representing the REST resource this object represents."
						type:        "string"
					}
					metadata: type: "object"
					spec: {
						description: "ZFSSnapshotSpec defines the desired state of ZFSSnapshot."
						properties: {
							capacity: {
								description: "Capacity of the snapshot."
								type:        "string"
							}
							fsType: {
								description: "FsType specifies the filesystem type."
								type:        "string"
							}
							nodeID: {
								description: "NodeID is the node on which this snapshot is provisioned."
								type:        "string"
							}
							ownerNodeID: {
								description: "OwnerNodeID is the node which owns the snapshot."
								type:        "string"
							}
							poolName: {
								description: "PoolName specifies the name of the ZFS pool."
								type:        "string"
							}
							volumeType: {
								description: "VolumeType specifies DATASET or ZVOL."
								type:        "string"
							}
						}
						required: ["capacity", "nodeID", "ownerNodeID", "poolName"]
						type: "object"
					}
					status: {
						description: "ZFSSnapshotStatus defines the observed state of ZFSSnapshot."
						properties: state: {
							description: "State of the ZFSSnapshot."
							type:        "string"
						}
						type: "object"
					}
				}
				required: ["spec"]
				type: "object"
			}
			served:  true
			storage: true
			subresources: status: {}
		}]
	}
}

#zfs_openebs_io_zfsbackups: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: {
		annotations: "controller-gen.kubebuilder.io/version": "v0.14.0"
		name: "zfsbackups.zfs.openebs.io"
	}
	spec: {
		group: "zfs.openebs.io"
		names: {
			kind:     "ZFSBackup"
			listKind: "ZFSBackupList"
			plural:   "zfsbackups"
			shortNames: ["zb"]
			singular: "zfsbackup"
		}
		scope: "Namespaced"
		versions: [{
			name: "v1"
			schema: openAPIV3Schema: {
				description: "ZFSBackup represents a backup of a ZFS volume."
				properties: {
					apiVersion: {
						description: "APIVersion defines the versioned schema of this representation of an object."
						type:        "string"
					}
					kind: {
						description: "Kind is a string value representing the REST resource this object represents."
						type:        "string"
					}
					metadata: type: "object"
					spec: {
						description: "ZFSBackupSpec defines the desired state of ZFSBackup."
						properties: {
							backupDest: {
								description: "BackupDest is the destination path for the backup."
								type:        "string"
							}
							backupName: {
								description: "BackupName is the name of the backup."
								type:        "string"
							}
							prevSnapName: {
								description: "PrevSnapName is the last completed backup snapshot name."
								type:        "string"
							}
							snapName: {
								description: "SnapName is the snapshot for this backup."
								type:        "string"
							}
							volumeName: {
								description: "VolumeName is the name of the volume to back up."
								type:        "string"
							}
						}
						required: ["backupName", "snapName", "volumeName"]
						type: "object"
					}
					status: {
						description: "ZFSBackupStatus defines the observed state of ZFSBackup."
						properties: state: {
							description: "State of the ZFSBackup."
							type:        "string"
						}
						type: "object"
					}
				}
				required: ["spec"]
				type: "object"
			}
			served:  true
			storage: true
			subresources: status: {}
		}]
	}
}

#zfs_openebs_io_zfsrestores: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: {
		annotations: "controller-gen.kubebuilder.io/version": "v0.14.0"
		name: "zfsrestores.zfs.openebs.io"
	}
	spec: {
		group: "zfs.openebs.io"
		names: {
			kind:     "ZFSRestore"
			listKind: "ZFSRestoreList"
			plural:   "zfsrestores"
			shortNames: ["zr"]
			singular: "zfsrestore"
		}
		scope: "Namespaced"
		versions: [{
			name: "v1"
			schema: openAPIV3Schema: {
				description: "ZFSRestore represents a restore operation for a ZFS volume."
				properties: {
					apiVersion: {
						description: "APIVersion defines the versioned schema of this representation of an object."
						type:        "string"
					}
					kind: {
						description: "Kind is a string value representing the REST resource this object represents."
						type:        "string"
					}
					metadata: type: "object"
					spec: {
						description: "ZFSRestoreSpec defines the desired state of ZFSRestore."
						properties: {
							restoreName: {
								description: "RestoreName is the name of the restore operation."
								type:        "string"
							}
							restoreSrc: {
								description: "RestoreSrc is the source backup path."
								type:        "string"
							}
							volumeName: {
								description: "VolumeName is the name of the volume to restore."
								type:        "string"
							}
						}
						required: ["restoreName", "volumeName"]
						type: "object"
					}
					status: {
						description: "ZFSRestoreStatus defines the observed state of ZFSRestore."
						properties: state: {
							description: "State of the ZFSRestore."
							type:        "string"
						}
						type: "object"
					}
				}
				required: ["spec"]
				type: "object"
			}
			served:  true
			storage: true
			subresources: status: {}
		}]
	}
}

#zfs_openebs_io_zfsnodes: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: {
		annotations: "controller-gen.kubebuilder.io/version": "v0.14.0"
		name: "zfsnodes.zfs.openebs.io"
	}
	spec: {
		group: "zfs.openebs.io"
		names: {
			kind:     "ZFSNode"
			listKind: "ZFSNodeList"
			plural:   "zfsnodes"
			singular: "zfsnode"
		}
		scope: "Cluster"
		versions: [{
			name: "v1"
			schema: openAPIV3Schema: {
				description: "ZFSNode represents the available ZFS pools on a Kubernetes node."
				properties: {
					apiVersion: {
						description: "APIVersion defines the versioned schema of this representation of an object."
						type:        "string"
					}
					kind: {
						description: "Kind is a string value representing the REST resource this object represents."
						type:        "string"
					}
					metadata: type: "object"
					pools: {
						description: "Pools is the list of ZFS pools available on this node."
						items: {
							description: "Pool represents a single ZFS pool on the node."
							properties: {
								free: {
									description: "Free is the free space in the pool."
									type:        "string"
								}
								name: {
									description: "Name is the name of the ZFS pool."
									type:        "string"
								}
								uuid: {
									description: "UUID is the unique identifier of the ZFS pool."
									type:        "string"
								}
							}
							required: ["name", "uuid"]
							type: "object"
						}
						type: "array"
					}
				}
				type: "object"
			}
			served:  true
			storage: true
		}]
	}
}
