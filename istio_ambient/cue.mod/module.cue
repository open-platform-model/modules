module: "opmodel.dev/modules/istio_ambient@v1"
language: {
	version: "v0.17.0"
}
source: {
	kind: "self"
}
deps: {
	"opmodel.dev/catalogs/opm@v1": {
		v: "v1.0.0-alpha.4"
	}
	"opmodel.dev/catalogs/opm_experimental@v1": {
		v: "v1.2.0-alpha.3"
	}
	"opmodel.dev/core@v1": {
		v: "v1.0.0-alpha.3"
	}
}
