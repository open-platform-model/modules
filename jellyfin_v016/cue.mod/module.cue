module: "opmodel.dev/modules/jellyfin@v1"
language: {
	version: "v0.16.0"
}
source: {
	kind: "self"
}
deps: {
	"opmodel.dev/core/v1alpha1@v1": {
		v: "v1.3.10"
	}
	"opmodel.dev/k8up/v1alpha1@v1": {
		v: "v1.0.3"
	}
	"opmodel.dev/opm/v1alpha1@v1": {
		v: "v1.5.9"
	}
}
