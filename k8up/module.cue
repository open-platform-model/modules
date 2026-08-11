// K8up — Kubernetes backup operator based on restic.
// Deploys the K8up operator (Deployment + ServiceAccount + metrics Service),
// all 9 CRDs, and the four upstream ClusterRoles:
// - module.cue:     metadata and config schema
// - components.cue: component definitions (catalog_opm blueprints/traits)
// - crds_data.cue:  vendored upstream CRDs (generated from crds/*.yaml)
//
// https://k8up.io | https://github.com/k8up-io/k8up
// Pinned upstream release: operator v2.16.0 / chart k8up-4.10.0. All object
// bodies (Deployment env, RBAC rules, Service) are transcribed from that
// chart's rendered output, NOT from the v0 legacy module — the legacy
// transcription had drifted (see the deviations listed below).
//
// This module emits NO Schedule/Backup/PreBackupPod instances. Those are
// per-application backup policy, they carry restic/S3 credentials, and the
// core catalog has no backup primitive — so they are applied separately,
// exactly as MetalLB's address pools are. Modelling them would mean a k8up
// provider catalog with typed #Schedules/#PreBackupPods primitives.
//
// ⚠ RBAC DEVIATION FROM UPSTREAM. `#RoleSchema.subjects` is required and
// non-empty, so this catalog cannot express an unbound ClusterRole. Upstream
// binds only `k8up-manager` (1 ClusterRoleBinding) and leaves `k8up-executor`
// (bound at runtime by the operator to each executor Job's ServiceAccount)
// and the aggregation-only `k8up-edit` / `k8up-view` unbound. Here all four
// get a binding to the operator ServiceAccount. The consequence worth naming:
// the operator SA gains `pods/exec` cluster-wide via k8up-executor, which
// upstream does not grant it. This matches what the v0 module has run in
// production since 2026-03-27; it is tracked for a catalog fix (optional
// `subjects` on #Role).
package k8up

import (
	m "opmodel.dev/core@v2"
	res "opmodel.dev/catalogs/opm/resources/v1beta1"
	tr "opmodel.dev/catalogs/opm/traits/v1beta1"
)

// Module definition
m.#Module

// Module metadata — modulePath is the COMPLETE CUE module path including the
// major, byte-identical to cue.mod's module field and identity/identity.cue;
// fqn/registryPath/uuid derive from it (enhancement 0010).
metadata: {
	name:        "k8up"
	modulePath:  "opmodel.dev/modules/k8up@v3"
	version:     "3.0.0"
	description: "K8up restic-based backup operator for Kubernetes — deploys the operator, all 9 CRDs, and the manager/executor/edit/view ClusterRoles"
}

// Schema only — constraints for users, defaults track the upstream chart.
#config: {
	// Operator image.
	image: res.#Image & {
		repository: string | *"ghcr.io/k8up-io/k8up"
		// K8up release tag. See https://github.com/k8up-io/k8up/releases.
		// NOTE: crds_data.cue is vendored from the matching chart release —
		// re-vendor when bumping this tag.
		tag:    string | *"v2.16.0"
		digest: string | *""
	}

	// Image for the executor Jobs (backup/check/prune/restore) the operator
	// spawns, passed as BACKUP_IMAGE. Defaults to the operator image, which is
	// what the chart does — leaving it unset would make the executors run
	// whatever `latest` resolves to, at a different version from the operator
	// scheduling them.
	backupImage: res.#Image & {
		repository: string | *image.repository
		tag:        string | *image.tag
		digest:     string | *image.digest
	}

	// Number of operator replicas. Leader election keeps exactly one active;
	// followers are hot standby, shortening the gap when the leader dies.
	replicas: int & >=1 | *1

	// Timezone used to interpret Schedule cron expressions. Empty leaves the
	// container on the node's timezone. `tz database` names, e.g. "Europe/Zurich".
	timezone: string | *""

	// Leader election. Required for replicas > 1; harmless at 1.
	enableLeaderElection: bool | *true

	// Ignore PVCs that carry no `k8up.io/backup` annotation.
	skipWithoutAnnotation: bool | *false

	// Skip syncing restic snapshots back into Snapshot CRs after backup/prune.
	// Webhook notifications are still sent. Added upstream in v2.16.0.
	skipSnapshotSync: bool | *false

	// Namespace holding K8up's EffectiveSchedule state. Empty (the default)
	// makes the operator use its own namespace, injected via the downward API.
	//
	// This is NOT a watch-scope switch — K8up always reconciles cluster-wide.
	// The v0 module's schema documented it as one ("empty means cluster-wide")
	// and emitted a literal empty string rather than the downward-API ref.
	operatorNamespace: string | *""

	// Default resource requests/limits stamped onto every Job K8up spawns.
	// Individual Backup/Schedule resources can still override them; this is
	// the cluster-admin floor. Empty strings emit no env var at all.
	globalResources: {
		requests: {
			cpu:    string | *""
			memory: string | *""
		}
		limits: {
			cpu:    string | *""
			memory: string | *""
		}
	}

	// Resource requests and limits for the operator container itself.
	resources?: res.#ResourceRequirementsSchema

	// ServiceAccount the operator runs as, and the subject every ClusterRole
	// in this module binds to.
	serviceAccountName: string | *"k8up"

	// Prometheus metrics. The container port is fixed at 8080 (K8up's own
	// default; the chart hardcodes it too) — this sets the Service port.
	metrics: {
		port:        int & >0 & <=65535 | *8080
		serviceType: "ClusterIP" | "NodePort" | "LoadBalancer" | *"ClusterIP"
	}

	// Additional environment variables for the operator container, merged over
	// the ones this module derives. The upstream `k8up.envVars` escape hatch —
	// its documented use is global S3 credentials
	// (BACKUP_GLOBALACCESSKEYID / BACKUP_GLOBALSECRETACCESSKEY), which is why
	// the value shape allows a Secret reference and not just a literal.
	//
	// For credentials that already exist in the cluster use the `#SecretK8sRef`
	// form (`secretName` + `remoteKey`): it wires a secretKeyRef to that exact
	// object and emits nothing. The `#SecretLiteral` form (`value`) instead
	// makes OPM CREATE the Secret, under the instance-prefixed name
	// `{instance}-{$secretName}` — so it cannot address a pre-existing one.
	extraEnv?: [Name=string]: res.#EnvVarSchema & {name: Name}

	// Optional scheduling constraints — nodeSelector / tolerations /
	// priorityClassName. The chart exposes all three; the schema is the
	// catalog's own, referenced rather than copied.
	podScheduling?: tr.#PodSchedulingSchema

	// Optional pod-template labels and annotations. Kept off component
	// metadata on purpose: component labels flow into `spec.selector.matchLabels`,
	// which Kubernetes makes immutable. The chart's `podAnnotations` maps here.
	podMetadata?: tr.#PodMetadataSchema
}

// debugValues exercises the full #config surface for local `cue vet -c`.
debugValues: {
	image: {
		repository: "ghcr.io/k8up-io/k8up"
		tag:        "v2.16.0"
		digest:     ""
		pullPolicy: "IfNotPresent"
	}
	backupImage: {
		repository: "ghcr.io/k8up-io/k8up"
		tag:        "v2.16.0"
		digest:     ""
		pullPolicy: "IfNotPresent"
	}
	replicas:              1
	timezone:              "Europe/Stockholm"
	enableLeaderElection:  true
	skipWithoutAnnotation: false
	skipSnapshotSync:      false
	operatorNamespace:     ""
	globalResources: {
		requests: {
			cpu:    "50m"
			memory: "64Mi"
		}
		limits: {
			cpu:    "1000m"
			memory: "1Gi"
		}
	}
	resources: {
		requests: {
			cpu:    "20m"
			memory: "128Mi"
		}
		limits: {
			cpu:    "500m"
			memory: "256Mi"
		}
	}
	serviceAccountName: "k8up"
	metrics: {
		port:        8080
		serviceType: "ClusterIP"
	}
	// The realistic shape: a Secret provisioned outside this module, addressed
	// by its exact name.
	extraEnv: BACKUP_GLOBALACCESSKEYID: {
		name: "BACKUP_GLOBALACCESSKEYID"
		from: {
			$secretName: "global-s3-credentials"
			$dataKey:    "access-key-id"
			secretName:  "global-s3-credentials"
			remoteKey:   "access-key-id"
		}
	}
	podScheduling: {
		nodeSelector: "kubernetes.io/os": "linux"
	}
	podMetadata: {
		annotations: "prometheus.io/scrape": "true"
	}
}
