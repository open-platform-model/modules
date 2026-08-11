package istio_ambient

import (
	"encoding/json"
	"encoding/yaml"

	res "opmodel.dev/catalogs/opm/resources/v1beta1"
	exp "opmodel.dev/catalogs/opm/resources/v1alpha1"
)

/////////////////////////////////////////////////////////////////
//// Mesh configuration
////
//// The ambient hard-locks live here, not in #config — they are what makes
//// this an ambient mesh rather than a sidecar one, and a deployment with any
//// of them flipped is simply broken. They are exactly the four settings the
//// umbrella chart's profile contributes, plus serviceScopeConfigs which 1.28
//// added.
/////////////////////////////////////////////////////////////////

_meshConfig: {
	defaultConfig: {
		discoveryAddress: "istiod.\(#config.namespace.name).svc:15012"
		image: imageType:                       #config.image.variant
		proxyMetadata: ISTIO_META_ENABLE_HBONE: "true"
	}
	defaultProviders: metrics: ["prometheus"]
	enablePrometheusMerge: true
	rootNamespace:         #config.namespace.name
	// Services labelled istio.io/global are visible mesh-wide rather than only
	// in their own namespace.
	serviceScopeConfigs: [{
		scope: "GLOBAL"
		servicesSelector: matchExpressions: [{
			key:      "istio.io/global"
			operator: "In"
			values: ["true"]
		}]
	}]
	trustDomain: #config.mesh.trustDomain
}

/////////////////////////////////////////////////////////////////
//// CNI agent configuration
////
//// At 1.30 this is a FLAT env-var map consumed by the agent via
//// `envFrom: configMapRef`, not the chained-CNI JSON blob older charts used.
/////////////////////////////////////////////////////////////////

_cniConfig: {
	CURRENT_AGENT_VERSION: #config.image.tag
	AMBIENT_ENABLED:       "true"
	// Pods opt in by namespace or pod label, and opt out with
	// istio.io/dataplane-mode=none — which is exactly how the control plane's
	// own pods avoid being captured by the dataplane they run.
	AMBIENT_ENABLEMENT_SELECTOR: yaml.Marshal([
		{podSelector: matchLabels: "istio.io/dataplane-mode": "ambient"},
		{
			namespaceSelector: matchLabels: "istio.io/dataplane-mode": "ambient"
			podSelector: matchExpressions: [{
				key:      "istio.io/dataplane-mode"
				operator: "NotIn"
				values: ["none"]
			}]
		},
	])
	AMBIENT_DNS_CAPTURE: "true"
	AMBIENT_IPV6:        "true"
	// Flipped false -> true between 1.28.10 and 1.30.3. Caught by diffing the
	// rendered ConfigMap against `helm template`, not by any schema check.
	AMBIENT_RECONCILE_POD_RULES_ON_STARTUP: "true"
	ENABLE_AMBIENT_DETECTION_RETRY:         "false"
	ISTIO_OWNED_CNI_CONFIG:                 "false"
	CHAINED_CNI_PLUGIN:                     "\(#config.cni.chained)"
	EXCLUDE_NAMESPACES:                     "kube-system"
	REPAIR_ENABLED:                         "\(#config.cni.repair.enabled)"
	REPAIR_LABEL_PODS:                      "false"
	REPAIR_DELETE_PODS:                     "false"
	REPAIR_REPAIR_PODS:                     "true"
	REPAIR_INIT_CONTAINER_NAME:             "istio-validation"
	REPAIR_BROKEN_POD_LABEL_KEY:            "cni.istio.io/uninitialized"
	REPAIR_BROKEN_POD_LABEL_VALUE:          "true"
	NATIVE_NFTABLES:                        "false"
}

/////////////////////////////////////////////////////////////////
//// Sidecar injector configuration
////
//// `config` is the vendored template set (sidecar, gateway, grpc-simple,
//// grpc-agent, waypoint, kube-gateway) — istiod runtime templates with no
//// chart values baked in, so it is carried verbatim. kube-gateway is what
//// istiod's Gateway controller uses to provision gateway pods, so this
//// ConfigMap is required, not optional polish.
////
//// `values` is a JSON dump istiod reads at injection time to resolve
//// {{ .Values.* }} inside those templates. It is vendored as a base and the
//// fields #config owns are projected over it — generating the whole thing
//// from scratch would risk a template referencing a key we forgot to emit,
//// which fails at injection time rather than at render time.
/////////////////////////////////////////////////////////////////

_injectorValues: {
	for k, v in _injectorValuesBase if k != "global" {(k): v}

	global: {
		for k, v in _injectorValuesBase.global
		if k != "hub" && k != "tag" && k != "variant" && k != "istioNamespace" && k != "network" && k != "meshID" {(k): v}

		hub:            #config.image.hub
		tag:            #config.image.tag
		variant:        #config.image.variant
		istioNamespace: #config.namespace.name
		network:        #config.mesh.network
		meshID:         #config.mesh.meshID
	}
}

#components: {
	// The chart never creates the namespace; this module does, because
	// istio-cni and ztunnel violate baseline Pod Security and the labels must
	// be in place before the DaemonSets are admitted.
	if #config.namespace.create {
		namespace: {
			exp.#Namespaces

			spec: namespaces: (#config.namespace.name): labels: {
				"pod-security.kubernetes.io/enforce": "privileged"
				"pod-security.kubernetes.io/audit":   "privileged"
				"pod-security.kubernetes.io/warn":    "privileged"
			}
		}
	}

	// All three render under their exact upstream names: istiod reads mesh
	// config from the ConfigMap literally named `istio`, the CNI agent's
	// envFrom names `istio-cni-config`, and istiod looks up its injection
	// templates in `istio-sidecar-injector`.
	config: {
		res.#ConfigMaps

		spec: configMaps: {
			istio: {
				exactName: true
				data: {
					mesh: yaml.Marshal(_meshConfig)
					meshNetworks: yaml.Marshal({networks: {}})
				}
			}

			"istio-cni-config": {
				exactName: true
				data:      _cniConfig
			}

			"istio-sidecar-injector": {
				exactName: true
				data: {
					config: _injectorConfig
					values: json.Marshal(_injectorValues)
				}
			}
		}
	}

	// Per-GatewayClass default overlays. Empty at upstream defaults.
	if len(#config.gatewayClasses) > 0 {
		"gatewayclass-config": {
			res.#ConfigMaps

			spec: configMaps: {
				for class, overlay in #config.gatewayClasses {
					"istio-default-gatewayclass-\(class)": {
						exactName: true
						data: {
							for kind, spec in overlay {(kind): yaml.Marshal(spec)}
						}
					}
				}
			}
		}
	}
}

/////////////////////////////////////////////////////////////////
//// Guards
/////////////////////////////////////////////////////////////////

// The injector values projection must actually override the vendored base.
// Interpolation forces resolution, so a projection that silently dropped the
// override and fell back to the vendored value cannot repair itself.
_injectorHubOverridden: "\(_injectorValues.global.hub)" & #config.image.hub

// ...and must keep every key it did not override. The base has 57 top-level
// keys; losing any of them means a template can reference a missing value at
// injection time, which fails in the cluster rather than here.
_injectorValuesComplete: (len(_injectorValues) + 0) & (len(_injectorValuesBase) + 0)

// The mesh ConfigMap's discoveryAddress is the istiod Service DNS name, which
// is why that Service must render unprefixed.
_meshDiscoveryAddress: "\(_meshConfig.defaultConfig.discoveryAddress)" &
	"istiod.\(#config.namespace.name).svc:15012"

// The injection templates must survive vendoring intact — kube-gateway in
// particular, since istiod's Gateway controller provisions gateway pods from it.
_injectorHasKubeGateway: [
	if _injectorConfig != _|_ {len(_injectorConfig) > 1000},
] & [true]
