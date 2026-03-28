module: "opmodel.dev/modules/gateway@v0"
language: {
	version: "v0.15.0"
}
source: {
	kind: "self"
}
deps: {
	"opmodel.dev/cert_manager/v1alpha1@v1": {
		v: "v1.3.2"
	}
	"opmodel.dev/core/v1alpha1@v1": {
		v: "v1.3.2"
	}
	"opmodel.dev/gateway_api/v1alpha1@v1": {
		v: "v1.3.5"
	}
	"opmodel.dev/opm/v1alpha1@v1": {
		v: "v1.5.6"
	}
}
