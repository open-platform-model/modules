module: "opmodel.dev/modules/sonarr@v1"
language: {
	version: "v0.17.0"
}
source: {
	kind: "self"
}
deps: {
	"cue.dev/x/k8s.io@v0": {
		v: "v0.7.0"
	}
	"opmodel.dev/catalogs/opm@v1": {
		v: "v1.0.0"
	}
	"opmodel.dev/core@v1": {
		v: "v1.1.0"
	}
}
