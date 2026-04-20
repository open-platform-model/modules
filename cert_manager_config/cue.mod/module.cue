module: "opmodel.dev/modules/cert_manager_config@v0"
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
		v: "v1.3.8"
	}
	"opmodel.dev/opm/v1alpha1@v1": {
		v: "v1.5.6"
	}
}
