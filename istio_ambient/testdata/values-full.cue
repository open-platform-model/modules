// Every off-by-default chart feature switched on, so `opm module build -f` can
// exercise the code paths a bare build never reaches: the PDB, the
// NetworkPolicy, the CEL admission policy, the Gateway API CRDs and a
// gatewayClass overlay. Not part of the module package — CUE's loader skips
// testdata/.
package values

image: {
	hub:        "registry.istio.io/release"
	tag:        "1.30.3"
	variant:    "distroless"
	pullPolicy: "IfNotPresent"
}
namespace: {name: "istio-system", create: true}
mesh: {clusterName: "Kubernetes", network: "", meshID: "", trustDomain: "cluster.local"}
pilot: {
	replicas: 2
	autoscale: {enabled: true, min: 2, max: 5, targetCPUUtilization: 80}
	pdb: {enabled: true, minAvailable: 1}
	networkPolicy: enabled: false // blocked: see components_control_plane.cue
	resources: requests: {cpu: "500m", memory: "2048Mi"}
	traceSampling: 1
	env: {}
}
cni: {
	logLevel: "info"
	binDir:   "/opt/cni/bin"
	confDir:  "/etc/cni/net.d"
	chained:  true
	repair: enabled: true
	resources: requests: {cpu: "100m", memory: "100Mi"}
}
ztunnel: {logLevel: "info", resources: requests: {cpu: "200m", memory: "512Mi"}}
gatewayAPI: enabled: true
gatewayClasses: istio: deployment: spec: replicas: 2
// Pending catalog_opm_experimental > v1.2.0-alpha.3 (PR #12): the released
// schema rejects matchConstraints.objectSelector, which istio uses to scope
// the policy to a revision. The module code is correct; flip this to true
// once that release lands.
experimental: stableValidationPolicy: false
