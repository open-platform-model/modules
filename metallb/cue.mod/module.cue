module: "opmodel.dev/modules/metallb@v1"
language: {
	version: "v0.17.0"
}
source: {
	kind: "self"
}
deps: {
	"opmodel.dev/catalogs/opm-experimental@v1": {
		v: "v1.3.0-alpha"
	}
	"opmodel.dev/catalogs/opm@v1": {
		v: "v1.0.0-alpha.2"
	}
	"opmodel.dev/core@v1": {
		v: "v1.0.0-alpha.1"
	}
}
