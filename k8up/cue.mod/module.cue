module: "opmodel.dev/modules/k8up@v2"
language: {
	version: "v0.17.0"
}
source: {
	kind: "self"
}
deps: {
	"opmodel.dev/catalogs/opm@v1": {
		v: "v1.0.0"
	}
	"opmodel.dev/core@v1": {
		v: "v1.1.0"
	}
}
