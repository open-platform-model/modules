// istio-ambient — the Istio ambient-mesh control plane.
//
// Deploys istiod, istio-cni and ztunnel, the Istio CRDs, both validating
// webhook configurations and the sidecar injector, full RBAC, and the mesh /
// CNI / injector ConfigMaps.
//
// - module.cue:                  metadata and config schema
// - components_crds.cue:         CRD emitters (Istio, and optionally Gateway API)
// - components_config.cue:       namespace and the three ConfigMaps
// - components_control_plane.cue: istiod (Deployment, Service, SA, HPA, PDB, NetworkPolicy)
// - components_dataplane.cue:    istio-cni and ztunnel DaemonSets
// - components_rbac.cue:         ClusterRoles, Roles and the reader ServiceAccount
// - components_admission.cue:    webhook configurations and the CEL admission policy
// - crds_*_data.cue:             vendored upstream CRDs (generated — do not hand-edit)
// - injector_*_data.cue:         vendored sidecar-injector templates and values
//
// Transcribed from the official `ambient` umbrella chart at 1.30.3
// (https://artifacthub.io/packages/helm/istio-official/ambient). That chart is
// `istio/istio` → manifests/sample-charts/ambient/, two files with no
// templates; its output is provably identical to rendering base + cni + istiod +
// ztunnel individually with `profile=ambient, global.variant=distroless`, so
// those four subcharts are the real source. Re-vendor crds/ and the injector
// blobs when bumping image.tag.
//
// ⚠ Instance-name coupling: the istiod Service, the CNI DaemonSet and every
// RBAC object render under exact upstream names, so this module is NOT
// instance-safe — deploy exactly one instance per cluster, in the namespace
// named by #config.namespace.name.
//
// ⚠ No in-place migration from a Helm-installed mesh. `spec.selector.matchLabels`
// is immutable in Kubernetes and OPM's differs from the chart's, so adopting an
// existing mesh means deleting and recreating istiod, istio-cni-node and
// ztunnel. Deleting istio-cni-node is the one genuinely dangerous step: the CNI
// plugin only lets its replacement pod through because that pod's name starts
// with `istio-cni-node-`. Recreate on a drained node, or accept a window with no
// CNI agent.
package istio_ambient

import (
	id "opmodel.dev/modules/istio_ambient/identity"
	m "opmodel.dev/core@v2"
	res "opmodel.dev/catalogs/opm/resources/v1beta1"
)

m.#Module

// Module metadata — modulePath is the COMPLETE CUE module path including the
// major, byte-identical to cue.mod's module field and identity/identity.cue;
// fqn/registryPath/uuid derive from it (enhancement 0010).
metadata: {
	name:        "istio_ambient"
	modulePath:  id.ModulePath
	version:     id.Version
	description: "Istio ambient mesh control plane — istiod, istio-cni and ztunnel, with CRDs, admission configuration and RBAC"
}

#config: {
	image: {
		// Registry and namespace holding the Istio images. The per-component
		// name (pilot, install-cni, ztunnel) is appended by the components.
		// Upstream moved this from docker.io/istio to registry.istio.io/release
		// in the 1.30 line.
		hub: string | *"registry.istio.io/release"

		// Istio release. crds/, the injector templates and the injector values
		// dump are all vendored from this release's charts — re-vendor when
		// bumping it, or istiod will serve injection templates from a different
		// version than it runs.
		tag: string | *"1.30.3"

		// Locked. The ambient profile sets global.variant=distroless and the
		// chart applies it to all three images; exposed only for visibility.
		// (Live nas2 runs a plain ztunnel tag, but that is an artifact of its
		// Timoni values, not upstream intent.)
		variant: "distroless"

		pullPolicy: "IfNotPresent" | "Always" | "Never" | *"IfNotPresent"
	}

	// The mesh's own namespace. istiod's ClusterRole names, the webhook
	// clientConfigs and CA_TRUSTED_NODE_ACCOUNTS all embed it.
	namespace: {
		name: string | *"istio-system"
		// The chart never creates the namespace. This module does, because the
		// dataplane needs PSS-privileged labels that must exist before the
		// DaemonSets are admitted. Set false when the namespace is managed
		// out-of-band (the module still adopts it via server-side apply).
		create: bool | *true
	}

	// Mesh identity. Empty network/meshID are the single-cluster defaults.
	mesh: {
		clusterName: string | *"Kubernetes"
		network:     string | *""
		meshID:      string | *""
		trustDomain: string | *"cluster.local"
	}

	pilot: {
		replicas: int & >=1 | *1

		// Upstream renders an HPA at ambient defaults (min 1, max 5). Leaving
		// this enabled means the Deployment omits `replicas` entirely — the
		// autoscaler owns it, and emitting both causes a permanent
		// server-side-apply tug-of-war.
		autoscale: {
			enabled:              bool | *true
			min:                  int & >=1 | *1
			max:                  int & >=1 | *5
			targetCPUUtilization: int & >=1 & <=100 | *80
		}

		// Off at ambient defaults: the chart gates its PDB on autoscaleMin > 1,
		// and a minAvailable:1 budget over a single replica blocks node drains
		// outright.
		pdb: {
			enabled:      bool | *false
			minAvailable: int | *1
		}

		resources?: res.#ResourceRequirementsSchema

		traceSampling: number | *1

		// Extra env for the discovery container. The ambient hard-locks
		// (PILOT_ENABLE_AMBIENT, CA_TRUSTED_NODE_ACCOUNTS) live in the
		// components and are not overridable here.
		env: [string]: string
	}

	cni: {
		logLevel: string | *"info"

		// CNI plugin filesystem paths. These are the upstream defaults and are
		// correct for Talos and most distributions; k3s and GKE need overrides.
		binDir:  string | *"/opt/cni/bin"
		confDir: string | *"/etc/cni/net.d"

		// Chained mode installs istio-cni alongside the cluster's existing CNI
		// rather than replacing it.
		chained: bool | *true

		// The repair controller relabels or restarts pods whose iptables setup
		// raced the agent.
		repair: enabled: bool | *true

		resources?: res.#ResourceRequirementsSchema
	}

	ztunnel: {
		logLevel:   string | *"info"
		resources?: res.#ResourceRequirementsSchema
	}

	// Emits a NetworkPolicy for EACH of the three workloads — istiod,
	// istio-cni and ztunnel — mirroring the chart's single
	// global.networkPolicy.enabled switch rather than exposing three flags the
	// chart does not have. Off at ambient defaults.
	//
	// Each policy's podSelector is DERIVED from the workload's own rendered pod
	// labels by the transformer, so it cannot drift from the pods it protects.
	// Egress is allow-all in every case (one empty rule): all three reach
	// endpoints that cannot be enumerated — the API server, DNS, and for istiod
	// user-defined JWKS URLs. Note "Egress" in policyTypes with no rules would
	// be a deny-all, not a no-op.
	networkPolicy: enabled: bool | *false

	// Installs the standard-channel Gateway API CRDs (v1.5.1 as vendored). The
	// ambient chart ships NONE of these — this is a deliberate addition,
	// because istiod's Gateway controller and any Gateway resource need them
	// and nothing else in the stack installs them. Leave false when the CRDs
	// are managed elsewhere; two owners of the same CRD fight.
	gatewayAPI: enabled: bool | *false

	// Per-GatewayClass default overlays, emitted as
	// istio-<revision>-gatewayclass-<class> ConfigMaps.
	gatewayClasses: [string]: [string]: _

	experimental: {
		// Emits a CEL ValidatingAdmissionPolicy enforcing the stable API
		// channel — rejects EnvoyFilter, WasmPlugin and ProxyConfig. Off
		// upstream by default.
		stableValidationPolicy: bool | *false
	}
}

// debugValues exercises the full #config surface for `opm module vet` and for a
// bare `opm module build`, which is diffed against `helm template` of the
// ambient chart. Every flag is left at its upstream-default value so that diff
// is meaningful; the everything-on case lives in testdata/values-full.cue.
debugValues: {
	image: {
		hub:        "registry.istio.io/release"
		tag:        "1.30.3"
		variant:    "distroless"
		pullPolicy: "IfNotPresent"
	}
	namespace: {
		name:   "istio-system"
		create: true
	}
	mesh: {
		clusterName: "Kubernetes"
		network:     ""
		meshID:      ""
		trustDomain: "cluster.local"
	}
	pilot: {
		replicas: 1
		autoscale: {
			enabled:              true
			min:                  1
			max:                  5
			targetCPUUtilization: 80
		}
		pdb: {
			enabled:      false
			minAvailable: 1
		}
		resources: requests: {
			cpu:    "500m"
			memory: "2048Mi"
		}
		traceSampling: 1
		env: {}
	}
	cni: {
		logLevel: "info"
		binDir:   "/opt/cni/bin"
		confDir:  "/etc/cni/net.d"
		chained:  true
		repair: enabled: true
		resources: requests: {
			cpu:    "100m"
			memory: "100Mi"
		}
	}
	ztunnel: {
		logLevel: "info"
		resources: requests: {
			cpu:    "200m"
			memory: "512Mi"
		}
	}
	networkPolicy: enabled: false
	gatewayAPI: enabled:    false
	gatewayClasses: {}
	experimental: stableValidationPolicy: false
}
