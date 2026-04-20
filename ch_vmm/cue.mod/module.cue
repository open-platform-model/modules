module: "opmodel.dev/modules/ch_vmm@v0"
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
		v: "v1.3.6"
	}
	"opmodel.dev/kubernetes/v1@v1": {
		v: "v1.0.1"
	}
	"opmodel.dev/opm/v1alpha1@v1": {
		v: "v1.5.6"
	}
}
