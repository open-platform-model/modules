module: "opmodel.dev/modules/istio_ambient@v0"
language: {
	version: "v0.15.0"
}
source: {
	kind: "self"
}
deps: {
	"opmodel.dev/core/v1alpha1@v1": {
		v: "v1.3.10"
	}
	"opmodel.dev/kubernetes/v1@v1": {
		v: "v1.0.2"
	}
	"opmodel.dev/opm/v1alpha1@v1": {
		v: "v1.5.9"
	}
}
