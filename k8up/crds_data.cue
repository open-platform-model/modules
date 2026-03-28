// K8up CRD definitions — v2.14.0
// Simplified schema using x-kubernetes-preserve-unknown-fields rather than
// embedding the full OpenAPI spec. Metadata, names, scope, and
// additionalPrinterColumns are taken verbatim from the upstream release YAML.
package k8up

#crd_archives_k8up_io: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: name: "archives.k8up.io"
	spec: {
		group: "k8up.io"
		names: {
			kind:     "Archive"
			listKind: "ArchiveList"
			plural:   "archives"
			singular: "archive"
		}
		scope: "Namespaced"
		versions: [{
			name: "v1"
			additionalPrinterColumns: [{
				description: "Reference to Schedule"
				jsonPath:    ".metadata.ownerReferences[?(@.kind == \"Schedule\")].name"
				name:        "Schedule Ref"
				type:        "string"
			}, {
				description: "Status of Completion"
				jsonPath:    ".status.conditions[?(@.type == \"Completed\")].reason"
				name:        "Completion"
				type:        "string"
			}, {
				jsonPath: ".metadata.creationTimestamp"
				name:     "Age"
				type:     "date"
			}]
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

#crd_backups_k8up_io: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: name: "backups.k8up.io"
	spec: {
		group: "k8up.io"
		names: {
			kind:     "Backup"
			listKind: "BackupList"
			plural:   "backups"
			singular: "backup"
		}
		scope: "Namespaced"
		versions: [{
			name: "v1"
			additionalPrinterColumns: [{
				description: "Reference to Schedule"
				jsonPath:    ".metadata.ownerReferences[?(@.kind == \"Schedule\")].name"
				name:        "Schedule Ref"
				type:        "string"
			}, {
				description: "Status of Completion"
				jsonPath:    ".status.conditions[?(@.type == \"Completed\")].reason"
				name:        "Completion"
				type:        "string"
			}, {
				description: "Status of PreBackupPods"
				jsonPath:    ".status.conditions[?(@.type == \"PreBackupPodReady\")].reason"
				name:        "PreBackup"
				type:        "string"
			}, {
				jsonPath: ".metadata.creationTimestamp"
				name:     "Age"
				type:     "date"
			}]
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

#crd_checks_k8up_io: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: name: "checks.k8up.io"
	spec: {
		group: "k8up.io"
		names: {
			kind:     "Check"
			listKind: "CheckList"
			plural:   "checks"
			singular: "check"
		}
		scope: "Namespaced"
		versions: [{
			name: "v1"
			additionalPrinterColumns: [{
				description: "Reference to Schedule"
				jsonPath:    ".metadata.ownerReferences[?(@.kind == \"Schedule\")].name"
				name:        "Schedule Ref"
				type:        "string"
			}, {
				description: "Status of Completion"
				jsonPath:    ".status.conditions[?(@.type == \"Completed\")].reason"
				name:        "Completion"
				type:        "string"
			}, {
				jsonPath: ".metadata.creationTimestamp"
				name:     "Age"
				type:     "date"
			}]
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

#crd_prebackuppods_k8up_io: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: name: "prebackuppods.k8up.io"
	spec: {
		group: "k8up.io"
		names: {
			kind:     "PreBackupPod"
			listKind: "PreBackupPodList"
			plural:   "prebackuppods"
			singular: "prebackuppod"
		}
		scope: "Namespaced"
		versions: [{
			name: "v1"
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

#crd_prunes_k8up_io: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: name: "prunes.k8up.io"
	spec: {
		group: "k8up.io"
		names: {
			kind:     "Prune"
			listKind: "PruneList"
			plural:   "prunes"
			singular: "prune"
		}
		scope: "Namespaced"
		versions: [{
			name: "v1"
			additionalPrinterColumns: [{
				description: "Reference to Schedule"
				jsonPath:    ".metadata.ownerReferences[?(@.kind == \"Schedule\")].name"
				name:        "Schedule Ref"
				type:        "string"
			}, {
				description: "Status of Completion"
				jsonPath:    ".status.conditions[?(@.type == \"Completed\")].reason"
				name:        "Completion"
				type:        "string"
			}, {
				jsonPath: ".metadata.creationTimestamp"
				name:     "Age"
				type:     "date"
			}]
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

#crd_restores_k8up_io: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: name: "restores.k8up.io"
	spec: {
		group: "k8up.io"
		names: {
			kind:     "Restore"
			listKind: "RestoreList"
			plural:   "restores"
			singular: "restore"
		}
		scope: "Namespaced"
		versions: [{
			name: "v1"
			additionalPrinterColumns: [{
				description: "Reference to Schedule"
				jsonPath:    ".metadata.ownerReferences[?(@.kind == \"Schedule\")].name"
				name:        "Schedule Ref"
				type:        "string"
			}, {
				description: "Status of Completion"
				jsonPath:    ".status.conditions[?(@.type == \"Completed\")].reason"
				name:        "Completion"
				type:        "string"
			}, {
				jsonPath: ".metadata.creationTimestamp"
				name:     "Age"
				type:     "date"
			}]
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

#crd_schedules_k8up_io: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: name: "schedules.k8up.io"
	spec: {
		group: "k8up.io"
		names: {
			kind:     "Schedule"
			listKind: "ScheduleList"
			plural:   "schedules"
			singular: "schedule"
		}
		scope: "Namespaced"
		versions: [{
			name: "v1"
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

#crd_snapshots_k8up_io: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: name: "snapshots.k8up.io"
	spec: {
		group: "k8up.io"
		names: {
			kind:     "Snapshot"
			listKind: "SnapshotList"
			plural:   "snapshots"
			singular: "snapshot"
		}
		scope: "Namespaced"
		versions: [{
			name: "v1"
			additionalPrinterColumns: [{
				description: "Date when snapshot was taken"
				jsonPath:    ".spec.date"
				name:        "Date taken"
				type:        "string"
			}, {
				description: "Snapshot's paths"
				jsonPath:    ".spec.paths[*]"
				name:        "Paths"
				type:        "string"
			}, {
				description: "Repository Url"
				jsonPath:    ".spec.repository"
				name:        "Repository"
				type:        "string"
			}]
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

#crd_podconfigs_k8up_io: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: name: "podconfigs.k8up.io"
	spec: {
		group: "k8up.io"
		names: {
			kind:     "PodConfig"
			listKind: "PodConfigList"
			plural:   "podconfigs"
			singular: "podconfig"
		}
		scope: "Namespaced"
		versions: [{
			name: "v1"
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

// #crds is a convenience map from CRD name to its definition,
// suitable for use in a components.cue CRD installation loop.
#crds: {
	"archives.k8up.io":      #crd_archives_k8up_io
	"backups.k8up.io":       #crd_backups_k8up_io
	"checks.k8up.io":        #crd_checks_k8up_io
	"prebackuppods.k8up.io": #crd_prebackuppods_k8up_io
	"prunes.k8up.io":        #crd_prunes_k8up_io
	"restores.k8up.io":      #crd_restores_k8up_io
	"schedules.k8up.io":     #crd_schedules_k8up_io
	"snapshots.k8up.io":     #crd_snapshots_k8up_io
	"podconfigs.k8up.io":    #crd_podconfigs_k8up_io
}
