// istio-ambient — Istio service mesh control plane, ambient mode.
// Deploys istiod, istio-cni, ztunnel, all Istio CRDs, admission webhooks,
// and full RBAC. Optionally bundles Gateway API standard CRDs (opt-in).
//
// Ambient-mode settings (PILOT_ENABLE_AMBIENT, ISTIO_META_ENABLE_HBONE,
// cni.ambient.enabled, global.variant=distroless) are hard-locked in
// components.cue and intentionally not exposed via #config.
//
// https://istio.io/latest/docs/ambient/
package istio_ambient

import (
	m "opmodel.dev/core/v1alpha1/module@v1"
	schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)

m.#Module

metadata: {
	modulePath:       "opmodel.dev/modules"
	name:             "istio-ambient"
	version:          "0.1.0"
	description:      "Istio Ambient mesh control plane — CRDs, istiod, istio-cni, ztunnel, RBAC, webhooks"
	defaultNamespace: "istio-system"
	labels: {
		"app.kubernetes.io/component": "service-mesh"
	}
}

// ---------------------------------------------------------------------------
// Private shared schemas
// ---------------------------------------------------------------------------

// Envoy/istiod log level keywords (proxy/cni/ztunnel).
_#logLevel: "trace" | "debug" | "info" | "warning" | "warn" | "error" | "critical" | "off"

// Scoped logging string used by istiod (e.g., "default:info,ads:debug").
_#scopedLogLevel: string

// Kubernetes Toleration list.
_#tolerationsSchema: [...{
	key?:               string
	operator?:          "Exists" | "Equal"
	value?:             string
	effect?:            "NoSchedule" | "PreferNoSchedule" | "NoExecute"
	tolerationSeconds?: int
}]

// ---------------------------------------------------------------------------
// #config — derived from research/charts/{base,istiod,cni,ztunnel}/values.yaml
// Scope rule: expose commonly-tuned fields; lock ambient-mode specifics in
// components.cue. Omit v1: ext_authz, multi-cluster, remote istiod, telemetry
// v2 stackdriver, injection templates — add later via an `extraMeshConfig`
// escape hatch if needed.
// ---------------------------------------------------------------------------

#config: {
	// Istio release tag (maps to each chart's global.tag). Shared across
	// pilot, install-cni, and ztunnel images unless per-component image is overridden.
	version: string | *"1.28.3"

	// Global image registry (maps to every chart's global.hub).
	hub: string | *"docker.io/istio"

	// Ambient mode requires distroless. Locked value — exposed only for visibility.
	variant: "distroless"

	// Cluster/mesh identity (istiod global.multiCluster.clusterName, network, meshID).
	clusterName: string | *"Kubernetes"
	network:     string | *""
	meshID:      string | *""
	trustDomain: string | *"cluster.local"

	// Opt-in Gateway API CRDs. When true, the crds-gateway-api component is
	// emitted alongside crds-istio. Default off — most users install Gateway
	// API via its own catalog module or an upstream bundle.
	gatewayAPI: {
		enabled: bool | *false
	}

	// Cross-chart image/pull settings.
	imagePullSecrets?: [...string]
	imagePullPolicy: "" | "Always" | "IfNotPresent" | "Never" | *""

	// -----------------------------------------------------------------------
	// base chart
	// -----------------------------------------------------------------------
	base: {
		// List of CRD names to exclude (e.g., ambient-only clusters may skip sidecar-specific CRDs).
		excludedCRDs?: [...string]

		// Validation webhook backing. validationURL != "" → remote validation.
		validationURL:      string | *""
		validationCABundle: string | *""

		// Istio config CRDs (VirtualService, DestinationRule, etc.). Ambient
		// still uses these for L7 waypoints.
		enableIstioConfigCRDs: bool | *true
		defaultRevision:       string | *"default"
	}

	// -----------------------------------------------------------------------
	// istiod chart
	// -----------------------------------------------------------------------
	istiod: {
		image: schemas.#Image & {
			repository: string | *"\(#config.hub)/pilot"
			tag:        string | *#config.version
			digest:     string | *""
		}

		// Replica count (ignored when autoscale.enabled=true).
		replicas: int & >=1 | *1

		autoscale: {
			enabled:              bool | *true
			min:                  int & >=1 | *1
			max:                  int & >=1 | *5
			cpuTargetUtilization: int & >=1 & <=100 | *80
		}

		pdb: {
			enabled:         bool | *true
			minAvailable?:   int & >=0
			maxUnavailable?: int & >=0
		}

		resources?: schemas.#ResourceRequirementsSchema
		nodeSelector?: [string]: string
		tolerations?:       _#tolerationsSchema
		priorityClassName?: string

		// istiod uses the scoped logging form "default:info,ads:debug".
		logging: {
			level:  _#scopedLogLevel | *"default:info"
			asJson: bool | *false
		}

		// Distributed trace sampling fraction (0.0–1.0).
		traceSampling: >=0.0 & <=1.0 | *1.0

		// Untaint controller — removes cni.istio.io/not-ready from nodes when
		// istio-cni becomes ready on them. Only useful with a node-taint setup.
		untaintController: {
			enabled:   bool | *false
			namespace: string | *""
		}

		// Cross-chart wiring for ztunnel discovery. Leave empty for the default
		// (same namespace as istiod, default name "ztunnel").
		trustedZtunnelNamespace: string | *""
		trustedZtunnelName:      string | *""

		// Sidecar injector webhook — the MutatingWebhookConfiguration is still
		// installed in ambient mode because sidecar-mode workloads may coexist.
		sidecarInjection: {
			enableNamespacesByDefault: bool | *false
			reinvocationPolicy:        "Never" | "IfNeeded" | *"Never"
			rewriteAppHTTPProbe:       bool | *true
		}

		// Render default NetworkPolicy resources for the control plane.
		networkPolicy: {
			enabled: bool | *false
		}

		// meshConfig — narrow surface. Ambient-required fields
		// (ISTIO_META_ENABLE_HBONE, serviceScopeConfigs) are hard-locked in components.cue.
		meshConfig: {
			accessLogFile?:        string
			enablePrometheusMerge: bool | *true
			enableTracing:         bool | *false
		}

		// Sidecar/waypoint proxy defaults (global.proxy.*).
		proxy: {
			logLevel:          _#logLevel | *"warning"
			componentLogLevel: string | *"misc:error"
			privileged:        bool | *false
			clusterDomain:     string | *"cluster.local"
			resources: {
				requests: {
					cpu:    string | *"100m"
					memory: string | *"128Mi"
				}
				limits?: {
					cpu?:    string
					memory?: string
				}
			}
			tracer: "none" | "zipkin" | "lightstep" | "datadog" | "stackdriver" | *"none"
		}

		// Waypoint proxy (ambient L7).
		waypoint: {
			resources: {
				requests: {
					cpu:    string | *"100m"
					memory: string | *"128Mi"
				}
				limits: {
					cpu:    string | *"2"
					memory: string | *"1Gi"
				}
			}
			nodeSelector?: [string]: string
			tolerations?: _#tolerationsSchema
		}
	}

	// -----------------------------------------------------------------------
	// cni chart
	// -----------------------------------------------------------------------
	cni: {
		image: schemas.#Image & {
			repository: string | *"\(#config.hub)/install-cni"
			tag:        string | *#config.version
			digest:     string | *""
		}

		logging: {
			level:  _#logLevel | *"info"
			asJson: bool | *false
		}

		// CNI plugin filesystem paths. Platform-specific overrides:
		//   Talos  → {cniBinDir: "/opt/cni/bin",           cniConfDir: "/etc/cni/net.d"}
		//   k3s    → {cniBinDir: "/var/lib/rancher/k3s/data/cni", cniConfDir: "/var/lib/rancher/k3s/agent/etc/cni/net.d"}
		//   GKE    → {cniBinDir: "/home/kubernetes/bin",  cniConfDir: "/etc/cni/net.d"}
		cniBinDir:        string | *"/opt/cni/bin"
		cniConfDir:       string | *"/etc/cni/net.d"
		cniConfFileName?: string
		cniNetnsDir:      string | *"/var/run/netns"

		// Plugin chaining vs standalone conf. OpenShift requires chained=false.
		chained:  bool | *true
		provider: "default" | "multus" | *"default"

		// Namespaces whose pods are never enrolled in ambient.
		excludeNamespaces: [...string] | *["kube-system"]

		// Ambient redirection tunables. `enabled` is always true in this module —
		// the field is here for visibility.
		ambient: {
			enabled:                    bool | *true
			dnsCapture:                 bool | *true
			ipv6:                       bool | *true
			reconcileIptablesOnStartup: bool | *false
			shareHostNetworkNamespace:  bool | *false
		}

		// Repair controller. Pick at most one action mode.
		repair: {
			enabled:    bool | *true
			labelPods:  bool | *false
			deletePods: bool | *false
			repairPods: bool | *true
		}

		resources?: schemas.#ResourceRequirementsSchema
		nodeSelector?: [string]: string
		tolerations?: _#tolerationsSchema
	}

	// -----------------------------------------------------------------------
	// ztunnel chart
	// -----------------------------------------------------------------------
	ztunnel: {
		image: schemas.#Image & {
			repository: string | *"\(#config.hub)/ztunnel"
			tag:        string | *#config.version
			digest:     string | *""
		}

		// Change only when running multiple ztunnels (must match
		// istiod.trustedZtunnelName).
		resourceName: string | *"ztunnel"

		logging: {
			level:  _#logLevel | *"info"
			asJson: bool | *false
		}

		resources?: schemas.#ResourceRequirementsSchema
		nodeSelector?: [string]: string
		tolerations?: _#tolerationsSchema

		terminationGracePeriodSeconds: int & >=1 | *30

		// XDS / CA overrides — leave empty for in-cluster istiod defaults.
		caAddress:  string | *""
		xdsAddress: string | *""

		env?: [string]: string
	}
}

// ---------------------------------------------------------------------------
// debugValues — concrete values for `cue vet -c`. Covers every #config field
// likely to be exercised during CI validation.
// ---------------------------------------------------------------------------

debugValues: {
	version:     "1.28.3"
	hub:         "docker.io/istio"
	variant:     "distroless"
	clusterName: "kind-opm-dev"
	network:     ""
	meshID:      "opm-dev"
	trustDomain: "cluster.local"
	gatewayAPI: enabled: true

	base: {
		excludedCRDs: []
		validationURL:         ""
		validationCABundle:    ""
		enableIstioConfigCRDs: true
		defaultRevision:       "default"
	}

	istiod: {
		replicas: 1
		autoscale: {enabled: true, min: 1, max: 5, cpuTargetUtilization: 80}
		pdb: {enabled: true, minAvailable: 1}
		resources: {
			requests: {cpu: "100m", memory: "256Mi"}
			limits: {cpu: "500m", memory: "512Mi"}
		}
		logging: {level: "default:info", asJson: false}
		traceSampling: 1.0
		untaintController: {enabled: false, namespace: ""}
		trustedZtunnelNamespace: ""
		trustedZtunnelName:      ""
		sidecarInjection: {enableNamespacesByDefault: false, reinvocationPolicy: "Never", rewriteAppHTTPProbe: true}
		networkPolicy: enabled: false
		meshConfig: {enablePrometheusMerge: true, enableTracing: false}
		proxy: {
			logLevel:          "warning"
			componentLogLevel: "misc:error"
			privileged:        false
			clusterDomain:     "cluster.local"
			resources: requests: {cpu: "100m", memory: "128Mi"}
			tracer: "none"
		}
		waypoint: {
			resources: {
				requests: {cpu: "100m", memory: "128Mi"}
				limits: {cpu: "2", memory: "1Gi"}
			}
		}
	}

	cni: {
		logging: {level: "info", asJson: false}
		cniBinDir:   "/opt/cni/bin"
		cniConfDir:  "/etc/cni/net.d"
		cniNetnsDir: "/var/run/netns"
		chained:     true
		provider:    "default"
		excludeNamespaces: ["kube-system"]
		ambient: {
			enabled:                    true
			dnsCapture:                 true
			ipv6:                       true
			reconcileIptablesOnStartup: false
			shareHostNetworkNamespace:  false
		}
		repair: {
			enabled:    true
			labelPods:  false
			deletePods: false
			repairPods: true
		}
		resources: requests: {cpu: "100m", memory: "100Mi"}
	}

	ztunnel: {
		resourceName: "ztunnel"
		logging: {level: "info", asJson: false}
		resources: {
			requests: {cpu: "100m", memory: "128Mi"}
			limits: {memory: "256Mi"}
		}
		terminationGracePeriodSeconds: 30
		caAddress:                     ""
		xdsAddress:                    ""
	}
}
