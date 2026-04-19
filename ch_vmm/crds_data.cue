// ch-vmm CRD definitions — v1.4.0 / apiGroup cloudhypervisor.quill.today.
//
// Uses the x-kubernetes-preserve-unknown-fields simplified schema instead of
// embedding the full OpenAPI spec. Names, scope, shortNames, and served/storage
// flags are taken verbatim from the upstream release YAML.
package ch_vmm

#crd_virtualdisks: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: name: "virtualdisks.cloudhypervisor.quill.today"
	spec: {
		group: "cloudhypervisor.quill.today"
		names: {
			kind:     "VirtualDisk"
			listKind: "VirtualDiskList"
			plural:   "virtualdisks"
			singular: "virtualdisk"
			shortNames: ["vdisk"]
		}
		scope: "Namespaced"
		versions: [{
			name: "v1beta1"
			schema: openAPIV3Schema: {
				type:                                   "object"
				"x-kubernetes-preserve-unknown-fields": true
			}
			served:  true
			storage: true
			subresources: status: {}
		}]
	}
}

#crd_virtualdisksnapshots: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: name: "virtualdisksnapshots.cloudhypervisor.quill.today"
	spec: {
		group: "cloudhypervisor.quill.today"
		names: {
			kind:     "VirtualDiskSnapshot"
			listKind: "VirtualDiskSnapshotList"
			plural:   "virtualdisksnapshots"
			singular: "virtualdisksnapshot"
			shortNames: ["vdss"]
		}
		scope: "Namespaced"
		versions: [{
			name: "v1beta1"
			schema: openAPIV3Schema: {
				type:                                   "object"
				"x-kubernetes-preserve-unknown-fields": true
			}
			served:  true
			storage: true
			subresources: status: {}
		}]
	}
}

#crd_virtualmachinemigrations: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: name: "virtualmachinemigrations.cloudhypervisor.quill.today"
	spec: {
		group: "cloudhypervisor.quill.today"
		names: {
			kind:     "VirtualMachineMigration"
			listKind: "VirtualMachineMigrationList"
			plural:   "virtualmachinemigrations"
			singular: "virtualmachinemigration"
			shortNames: ["vmm"]
		}
		scope: "Namespaced"
		versions: [{
			name: "v1beta1"
			schema: openAPIV3Schema: {
				type:                                   "object"
				"x-kubernetes-preserve-unknown-fields": true
			}
			served:  true
			storage: true
			subresources: status: {}
		}]
	}
}

#crd_virtualmachines: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: name: "virtualmachines.cloudhypervisor.quill.today"
	spec: {
		group: "cloudhypervisor.quill.today"
		names: {
			kind:     "VirtualMachine"
			listKind: "VirtualMachineList"
			plural:   "virtualmachines"
			singular: "virtualmachine"
			shortNames: ["vm"]
		}
		scope: "Namespaced"
		versions: [{
			name: "v1beta1"
			schema: openAPIV3Schema: {
				type:                                   "object"
				"x-kubernetes-preserve-unknown-fields": true
			}
			served:  true
			storage: true
			subresources: status: {}
		}]
	}
}

#crd_vmpools: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: name: "vmpools.cloudhypervisor.quill.today"
	spec: {
		group: "cloudhypervisor.quill.today"
		names: {
			kind:     "VMPool"
			listKind: "VMPoolList"
			plural:   "vmpools"
			singular: "vmpool"
		}
		scope: "Namespaced"
		versions: [{
			name: "v1beta1"
			schema: openAPIV3Schema: {
				type:                                   "object"
				"x-kubernetes-preserve-unknown-fields": true
			}
			served:  true
			storage: true
			subresources: status: {}
		}]
	}
}

#crd_vmrestorespecs: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: name: "vmrestorespecs.cloudhypervisor.quill.today"
	spec: {
		group: "cloudhypervisor.quill.today"
		names: {
			kind:     "VMRestoreSpec"
			listKind: "VMRestoreSpecList"
			plural:   "vmrestorespecs"
			singular: "vmrestorespec"
		}
		scope: "Namespaced"
		versions: [{
			name: "v1beta1"
			schema: openAPIV3Schema: {
				type:                                   "object"
				"x-kubernetes-preserve-unknown-fields": true
			}
			served:  true
			storage: true
			subresources: status: {}
		}]
	}
}

#crd_vmrollbacks: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: name: "vmrollbacks.cloudhypervisor.quill.today"
	spec: {
		group: "cloudhypervisor.quill.today"
		names: {
			kind:     "VMRollback"
			listKind: "VMRollbackList"
			plural:   "vmrollbacks"
			singular: "vmrollback"
		}
		scope: "Namespaced"
		versions: [{
			name: "v1beta1"
			schema: openAPIV3Schema: {
				type:                                   "object"
				"x-kubernetes-preserve-unknown-fields": true
			}
			served:  true
			storage: true
			subresources: status: {}
		}]
	}
}

#crd_vmsets: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: name: "vmsets.cloudhypervisor.quill.today"
	spec: {
		group: "cloudhypervisor.quill.today"
		names: {
			kind:     "VMSet"
			listKind: "VMSetList"
			plural:   "vmsets"
			singular: "vmset"
		}
		scope: "Namespaced"
		versions: [{
			name: "v1beta1"
			schema: openAPIV3Schema: {
				type:                                   "object"
				"x-kubernetes-preserve-unknown-fields": true
			}
			served:  true
			storage: true
			subresources: status: {}
		}]
	}
}

#crd_vmsnapshots: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: name: "vmsnapshots.cloudhypervisor.quill.today"
	spec: {
		group: "cloudhypervisor.quill.today"
		names: {
			kind:     "VMSnapShot"
			listKind: "VMSnapShotList"
			plural:   "vmsnapshots"
			singular: "vmsnapshot"
			shortNames: ["vmsnap"]
		}
		scope: "Namespaced"
		versions: [{
			name: "v1beta1"
			schema: openAPIV3Schema: {
				type:                                   "object"
				"x-kubernetes-preserve-unknown-fields": true
			}
			served:  true
			storage: true
			subresources: status: {}
		}]
	}
}

// #crds: map of CRD name -> raw CRD object, consumed by components.cue.
#crds: {
	"virtualdisks.cloudhypervisor.quill.today":             #crd_virtualdisks
	"virtualdisksnapshots.cloudhypervisor.quill.today":     #crd_virtualdisksnapshots
	"virtualmachinemigrations.cloudhypervisor.quill.today": #crd_virtualmachinemigrations
	"virtualmachines.cloudhypervisor.quill.today":          #crd_virtualmachines
	"vmpools.cloudhypervisor.quill.today":                  #crd_vmpools
	"vmrestorespecs.cloudhypervisor.quill.today":           #crd_vmrestorespecs
	"vmrollbacks.cloudhypervisor.quill.today":              #crd_vmrollbacks
	"vmsets.cloudhypervisor.quill.today":                   #crd_vmsets
	"vmsnapshots.cloudhypervisor.quill.today":              #crd_vmsnapshots
}
